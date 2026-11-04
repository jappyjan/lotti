import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { createApp, type App } from '../app.ts';
import { loadConfig } from '../config.ts';
import type { Integrations } from '../integrations/index.ts';
import type {
  ChatMessage,
  CompleteOptions,
  CompleteResult,
  Provider,
  ToolCall,
  ToolSpec,
} from '../providers/types.ts';
import { listen, type RunningServer } from '../server/http.ts';
import { FakeClock } from '../util/clock.ts';
import { silentLogger } from '../util/log.ts';

export type Step =
  | CompleteResult
  | ((
      messages: ChatMessage[],
      tools: ToolSpec[],
      opts: CompleteOptions,
    ) => CompleteResult | Promise<CompleteResult>);

/** Scripted chat provider. Each complete() consumes the next step; the default is a plain-text "ok". */
export class MockProvider implements Provider {
  readonly kind = 'chat' as const;
  readonly defaultModel = 'mock-1';
  readonly knownModels = ['mock-1'];
  calls: {
    messages: ChatMessage[];
    tools: ToolSpec[];
    opts: CompleteOptions;
  }[] = [];
  steps: Step[] = [];
  isConfigured = true;
  constructor(
    readonly id = 'mock',
    readonly label = 'Mock',
  ) {}
  configured(): boolean {
    return this.isConfigured;
  }
  script(...s: Step[]): this {
    this.steps.push(...s);
    return this;
  }
  async complete(
    messages: ChatMessage[],
    tools: ToolSpec[],
    opts: CompleteOptions,
  ): Promise<CompleteResult> {
    this.calls.push({ messages: [...messages], tools, opts });
    const s = this.steps.shift();
    if (!s) return { text: 'ok', toolCalls: [] };
    return typeof s === 'function' ? s(messages, tools, opts) : s;
  }
}

export const text = (t: string): CompleteResult => ({ text: t, toolCalls: [] });
let n = 0;
export const call = (
  name: string,
  args: Record<string, unknown> = {},
  text = '',
): CompleteResult => ({ text, toolCalls: [{ id: `c${++n}`, name, args }] });
export const calls = (...cs: ToolCall[]): CompleteResult => ({
  text: '',
  toolCalls: cs,
});
export const answer = (t: string, followUps?: string[]): CompleteResult =>
  call('answer', { text: t, ...(followUps ? { followUps } : {}) });
/** A step that never resolves until the signal aborts. */
export const hang: Step = (_m, _t, o) =>
  new Promise((_res, rej) =>
    o.signal?.addEventListener('abort', () =>
      rej(o.signal?.reason ?? new Error('aborted')),
    ),
  );

export interface TestApp {
  app: App;
  clock: FakeClock;
  mock: MockProvider;
  fetchCalls: string[];
  setFetch(f: typeof fetch): void;
  /** DNS answers for web_fetch (default: every name is a public address, localhost is 127.0.0.1). */
  setLookup(f: (host: string) => Promise<string[]>): void;
  cleanup(): void;
}

export function makeApp(
  opts: {
    integrations?: Partial<Integrations>;
    fetch?: typeof fetch;
    start?: Date | number;
    toolTimeoutMs?: number;
    wsPingMs?: number;
  } = {},
): TestApp {
  const dir = mkdtempSync(join(tmpdir(), 'lotti-brain-'));
  const config = {
    ...loadConfig({
      MASTER_KEY: 'test-master-key-0123456789',
      DATA_DIR: dir,
      PORT: '0',
    }),
    dbPath: ':memory:',
    phoneToolTimeoutMs: opts.toolTimeoutMs ?? 10_000,
    wsPingIntervalMs: opts.wsPingMs ?? 30_000,
  };
  const clock = new FakeClock(opts.start ?? new Date(2026, 10, 3, 8, 0, 0));
  const fetchCalls: string[] = [];
  let impl: typeof fetch =
    opts.fetch ?? (async () => new Response('{}', { status: 404 }));
  let lookup = async (host: string) =>
    host === 'localhost' ? ['127.0.0.1', '::1'] : ['93.184.215.14'];
  const app = createApp({
    config,
    clock,
    logger: silentLogger,
    lookup: (h) => lookup(h),
    fetch: ((input: any, init?: any) => {
      fetchCalls.push(
        String(input instanceof URL ? input.href : (input?.url ?? input)),
      );
      return impl(input, init);
    }) as typeof fetch,
    ...(opts.integrations ? { integrations: opts.integrations } : {}),
  });
  const mock = new MockProvider();
  app.providers.register(mock);
  app.settings.set('provider.active', 'mock');
  return {
    app,
    clock,
    mock,
    fetchCalls,
    setFetch: (f) => (impl = f),
    setLookup: (f) => (lookup = f),
    cleanup: () => app.db.close(),
  };
}

export const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

/** Poll `f` until it returns a truthy value (or throw after `ms`). Use instead of fixed sleeps. */
export async function until<T>(
  f: () => T | Promise<T>,
  ms = 5000,
  what = 'condition',
): Promise<Exclude<T, false | null | undefined | 0 | ''>> {
  const t0 = Date.now();
  for (;;) {
    const v = await f();
    if (v) return v as Exclude<T, false | null | undefined | 0 | ''>;
    if (Date.now() - t0 > ms) throw new Error(`timeout waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

/** Pair a device and return its token. */
export function pairDevice(app: App, name = 'Test iPhone'): string {
  const code = app.auth.ensureStartupCode() ?? app.auth.newPairingCode();
  return app.auth.pair(code, name)!.token;
}

/** In-process WebSocket client. */
export class WsClient {
  ws!: WebSocket;
  messages: any[] = [];
  private waiters: { pred: (m: any) => boolean; resolve: (m: any) => void }[] =
    [];

  static async connect(
    srv: RunningServer,
    token: string,
    opts: { hello?: boolean } = {},
  ): Promise<WsClient> {
    const c = new WsClient();
    c.ws = new WebSocket(`ws://127.0.0.1:${srv.port}/ws`, {
      headers: { authorization: `Bearer ${token}` },
    });
    c.ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      c.messages.push(m);
      for (const w of [...c.waiters]) {
        if (w.pred(m)) {
          c.waiters.splice(c.waiters.indexOf(w), 1);
          w.resolve(m);
        }
      }
    });
    await new Promise<void>((res, rej) => {
      c.ws.once('open', () => res());
      c.ws.once('error', rej);
      c.ws.once('unexpected-response', (_q, r) =>
        rej(new Error('HTTP ' + r.statusCode)),
      );
    });
    if (opts.hello !== false) {
      c.send({ type: 'hello', appVersion: '1.0', deviceName: 'Test iPhone' });
      await c.waitFor((m) => m.type === 'welcome');
    }
    return c;
  }
  send(m: Record<string, unknown>): void {
    this.ws.send(JSON.stringify(m));
  }
  waitFor(pred: (m: any) => boolean, ms = 3000): Promise<any> {
    const ex = this.messages.find(pred);
    if (ex) return Promise.resolve(ex);
    return new Promise((resolve, reject) => {
      const t = setTimeout(
        () =>
          reject(
            new Error(
              'timeout waiting for message; got: ' +
                JSON.stringify(this.messages.map((m) => m.type)),
            ),
          ),
        ms,
      );
      this.waiters.push({
        pred,
        resolve: (m) => (clearTimeout(t), resolve(m)),
      });
    });
  }
  /** Next message of this type (and matching `pred`) that arrives after now. */
  next(type: string, ms = 3000, pred: (m: any) => boolean = () => true): Promise<any> {
    const seen = this.messages.length;
    const ex = (m: any) => m.type === type && pred(m);
    return new Promise((resolve, reject) => {
      const t = setTimeout(
        () => reject(new Error(`timeout waiting for ${type}`)),
        ms,
      );
      this.waiters.push({
        pred: (m) => ex(m) && this.messages.indexOf(m) >= seen,
        resolve: (m) => (clearTimeout(t), resolve(m)),
      });
    });
  }
  of(type: string): any[] {
    return this.messages.filter((m) => m.type === type);
  }
  close(): Promise<void> {
    return new Promise((r) => {
      if (this.ws.readyState === this.ws.CLOSED) return r();
      this.ws.once('close', () => r());
      this.ws.close();
    });
  }
}

export async function startServer(t: TestApp): Promise<RunningServer> {
  return listen(t.app, 0);
}
