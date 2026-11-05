import type { App } from '../app.ts';
import { AnthropicProvider } from './anthropic.ts';
import { stubRuntimes } from './agent-runtime.ts';
import { OpenAiCompatProvider } from './openai-compat.ts';
import type {
  AgentRuntimeProvider,
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
  /** Set on the active provider when something it cannot do has nowhere else to go. */
  warning?: string;
}

/** Background LLM work (summaries, titles, memory, triage) gives up after this. */
export const TEXT_TIMEOUT_MS = 45_000;
export const BACKGROUND_WARNING =
  'Background tasks (summaries, memory, mail triage) need an API-key provider (DeepSeek, OpenAI or Anthropic), or a signed-in subscription.';

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
        'deepseek-v4-flash',
        [
          'deepseek-v4-flash',
          'deepseek-v4-pro',
          'deepseek-chat',
          'deepseek-reasoner',
        ],
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
    const textOk = this.textChain().length > 0 || this.textRuntime();
    return this.all().map((p) => {
      const e = this.errors.get(p.id);
      const active = p.id === this.activeId();
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
        ...(active && !textOk ? { warning: BACKGROUND_WARNING } : {}),
      };
    });
  }

  /**
   * Chat providers for one-shot text (no tools): active, fallback, then any other configured chat provider.
   * Lets background work run while a subscription runtime (Codex / Claude Code) answers the questions.
   */
  private textChain(): Provider[] {
    const ids = [
      this.activeId(),
      this.fallbackId(),
      ...this.all().map((p) => p.id),
    ];
    const out: Provider[] = [];
    for (const id of new Set(ids.filter(Boolean))) {
      const p = this.providers.get(id);
      if (p?.kind === 'chat' && p.configured()) out.push(p);
    }
    return out;
  }
  /** The active runtime, when no chat provider can do the text work. */
  private textRuntime(): AgentRuntimeProvider | undefined {
    const a = this.active();
    return a?.kind === 'agent-runtime' && a.configured() ? a : undefined;
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
    chainOverride?: Provider[],
  ): Promise<CompleteResult & { providerId: string }> {
    const chain = chainOverride ?? this.chain();
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

  /**
   * One prompt -> text (summaries, titles, extraction, triage). Uses the first configured chat provider
   * (active, fallback, any other); with none, the active subscription runtime without tools. Times out
   * after TEXT_TIMEOUT_MS.
   */
  async text(
    system: string,
    user: string,
    signal?: AbortSignal,
    timeoutMs = TEXT_TIMEOUT_MS,
  ): Promise<string> {
    const chain = this.textChain();
    if (chain.length) {
      const r = await this.complete(
        [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
        [],
        { silenceMs: timeoutMs, ...(signal ? { signal } : {}) },
        chain,
      );
      return r.text.trim();
    }
    const rt = this.textRuntime();
    if (!rt) throw new Error(BACKGROUND_WARNING);
    const r = await rt.run({
      system,
      prompt: user,
      mcpServers: [],
      signal: AbortSignal.any([
        AbortSignal.timeout(timeoutMs),
        ...(signal ? [signal] : []),
      ]),
    });
    return r.text.trim();
  }
}
