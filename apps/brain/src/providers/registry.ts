import type { App } from '../app.ts';
import { AnthropicProvider } from './anthropic.ts';
import { stubRuntimes } from './agent-runtime.ts';
import { OpenAiCompatProvider } from './openai-compat.ts';
import type {
  AnyProvider,
  ChatMessage,
  CompleteOptions,
  CompleteResult,
  Provider,
  ToolSpec,
} from './types.ts';

export type CompleteOpts = Omit<CompleteOptions, 'model' | 'onActivity'> & {
  model?: string;
  silenceMs?: number;
};

export interface ProviderStatus {
  id: string;
  label: string;
  kind: 'chat' | 'agent-runtime';
  configured: boolean;
  active: boolean;
  fallback: boolean;
  model: string;
  lastError: string | null;
  lastErrorAt: number | null;
  lastOkAt: number | null;
}

/** Providers + active/fallback selection + per-provider status. */
export class ProviderRegistry {
  private providers = new Map<string, AnyProvider>();
  private errors = new Map<
    string,
    { error: string | null; at: number | null; ok: number | null }
  >();

  constructor(private app: App) {
    const secret = (id: string) => () =>
      this.app.secrets.get(`provider.${id}.api_key`);
    const f: typeof fetch = (...a) => this.app.fetch(...a);
    this.register(
      new OpenAiCompatProvider(
        'deepseek',
        'DeepSeek',
        'deepseek-chat',
        ['deepseek-chat', 'deepseek-reasoner'],
        {
          fetch: f,
          apiKey: secret('deepseek'),
          baseUrl: () =>
            this.app.settings.str('provider.deepseek.base_url') ||
            'https://api.deepseek.com',
        },
      ),
    );
    this.register(
      new OpenAiCompatProvider(
        'openai',
        'OpenAI',
        'gpt-4.1-mini',
        ['gpt-4.1-mini', 'gpt-4.1', 'gpt-4o'],
        {
          fetch: f,
          apiKey: secret('openai'),
          baseUrl: () => 'https://api.openai.com/v1',
        },
      ),
    );
    this.register(
      new AnthropicProvider({
        fetch: f,
        apiKey: secret('anthropic'),
        baseUrl: () => 'https://api.anthropic.com',
      }),
    );
    for (const r of stubRuntimes()) this.register(r);
  }

  register(p: AnyProvider): void {
    this.providers.set(p.id, p);
  }
  get(id: string): AnyProvider | undefined {
    return this.providers.get(id);
  }
  all(): AnyProvider[] {
    return [...this.providers.values()];
  }
  modelFor(id: string): string {
    const p = this.providers.get(id);
    return (
      this.app.settings.str(`provider.${id}.model`) || p?.defaultModel || ''
    );
  }
  activeId(): string {
    return this.app.settings.str('provider.active');
  }
  fallbackId(): string {
    return this.app.settings.str('provider.fallback');
  }
  active(): AnyProvider | undefined {
    return this.providers.get(this.activeId());
  }

  private note(id: string, err: unknown): void {
    const prev = this.errors.get(id);
    if (err === null)
      this.errors.set(id, {
        error: prev?.error ?? null,
        at: prev?.at ?? null,
        ok: this.app.clock.now(),
      });
    else
      this.errors.set(id, {
        error: err instanceof Error ? err.message : String(err),
        at: this.app.clock.now(),
        ok: prev?.ok ?? null,
      });
  }
  noteOk(id: string): void {
    this.note(id, null);
  }
  noteError(id: string, e: unknown): void {
    this.note(id, e);
  }

  status(): ProviderStatus[] {
    return this.all().map((p) => {
      const e = this.errors.get(p.id);
      return {
        id: p.id,
        label: p.label,
        kind: p.kind,
        configured: p.configured(),
        active: p.id === this.activeId(),
        fallback: p.id === this.fallbackId(),
        model: this.modelFor(p.id),
        lastError: e?.error ?? null,
        lastErrorAt: e?.at ?? null,
        lastOkAt: e?.ok ?? null,
      };
    });
  }

  /** Order to try: active, then fallback (if different). Only chat providers here. */
  private chain(): Provider[] {
    const ids = [this.activeId(), this.fallbackId()].filter(
      (x, i, a) => x && a.indexOf(x) === i,
    );
    const chain: Provider[] = [];
    for (const id of ids) {
      const p = this.providers.get(id);
      if (p && p.kind === 'chat') chain.push(p);
    }
    return chain;
  }

  private attempt(
    p: Provider,
    messages: ChatMessage[],
    tools: ToolSpec[],
    opts: CompleteOpts,
    model: string,
  ): Promise<CompleteResult> {
    const ac = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const arm = () => {
      clearTimeout(timer);
      if (opts.silenceMs)
        timer = setTimeout(
          () =>
            ac.abort(
              new Error(
                `${p.label} timed out (silent for ${opts.silenceMs} ms)`,
              ),
            ),
          opts.silenceMs,
        );
    };
    const onCancel = () =>
      ac.abort(opts.signal?.reason ?? new Error('cancelled'));
    if (opts.signal?.aborted) onCancel();
    opts.signal?.addEventListener('abort', onCancel, { once: true });
    arm();
    const aborted = new Promise<never>((_, rej) => {
      const f = () => rej(ac.signal.reason ?? new Error('aborted'));
      if (ac.signal.aborted) f();
      else ac.signal.addEventListener('abort', f, { once: true });
    });
    aborted.catch(() => {});
    return Promise.race([
      p.complete(messages, tools, {
        ...opts,
        model,
        signal: ac.signal,
        onActivity: arm,
      }),
      aborted,
    ]).finally(() => {
      clearTimeout(timer);
      opts.signal?.removeEventListener('abort', onCancel);
    });
  }

  /** Chat completion on the active provider; on error/timeout use the fallback. Cancel (opts.signal) never falls back. */
  async complete(
    messages: ChatMessage[],
    tools: ToolSpec[],
    opts: CompleteOpts = {},
  ): Promise<CompleteResult & { providerId: string }> {
    const chain = this.chain();
    if (!chain.length)
      throw new Error(
        `Active provider "${this.activeId()}" cannot be used for chat completion.`,
      );
    let lastErr: unknown;
    for (const p of chain) {
      try {
        const r = await this.attempt(
          p,
          messages,
          tools,
          opts,
          opts.model && p === chain[0] ? opts.model : this.modelFor(p.id),
        );
        this.noteOk(p.id);
        return { ...r, providerId: p.id };
      } catch (e) {
        if (opts.signal?.aborted) throw e;
        this.noteError(p.id, e);
        lastErr = e;
        this.app.log.warn(
          `provider ${p.id} failed`,
          e instanceof Error ? e.message : e,
        );
      }
    }
    throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
  }

  /** Simple helper: one prompt -> text (summaries, extraction). */
  async text(
    system: string,
    user: string,
    signal?: AbortSignal,
  ): Promise<string> {
    const r = await this.complete(
      [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      [],
      signal ? { signal } : {},
    );
    return r.text.trim();
  }
}
