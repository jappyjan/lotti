import { spawn, type ChildProcess } from 'node:child_process';
import { z } from 'zod';
import type { App } from '../../app.ts';
import {
  loadMcpServers,
  mcpToolNeedsConfirmation,
} from '../../ops/integration-ops.ts';
import { proposeAction } from '../../tools/proposals.ts';
import type { ToolDef } from '../../tools/registry.ts';
import { clip } from '../../util/text.ts';
import type { McpClient, McpServerConfig } from '../index.ts';

const PROTOCOL = '2025-03-26';
const TIMEOUT_MS = 30_000;

interface Session {
  request(method: string, params?: unknown): Promise<any>;
  notify(method: string, params?: unknown): Promise<void>;
  close(): Promise<void>;
}

// ---- stdio: newline-delimited JSON-RPC over the child's stdin/stdout ------------------------------------

class StdioSession implements Session {
  private child: ChildProcess;
  private nextId = 1;
  private pending = new Map<
    number,
    { res(v: any): void; rej(e: Error): void }
  >();
  private buf = '';
  private errTail = '';
  private dead?: Error;

  constructor(command: string, args: string[], env: Record<string, string>) {
    this.child = spawn(command, args, {
      // Do not leak the backend's environment (MASTER_KEY, ...) to third-party servers.
      env: {
        ...Object.fromEntries(
          ['PATH', 'HOME', 'LANG', 'TMPDIR', 'SHELL', 'USER'].flatMap((k) =>
            process.env[k] ? [[k, process.env[k]!]] : [],
          ),
        ),
        ...env,
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.stdout!.setEncoding('utf8').on('data', (d: string) => {
      this.buf += d;
      let i: number;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i).trim();
        this.buf = this.buf.slice(i + 1);
        if (!line) continue;
        try {
          const m = JSON.parse(line);
          if (m.id !== undefined && this.pending.has(m.id)) {
            const p = this.pending.get(m.id)!;
            this.pending.delete(m.id);
            if (m.error) p.rej(new Error(m.error.message ?? 'MCP error'));
            else p.res(m.result);
          }
        } catch {
          /* not JSON: ignore noise */
        }
      }
    });
    this.child.stderr!.setEncoding('utf8').on('data', (d: string) => {
      this.errTail = (this.errTail + d).slice(-500);
    });
    const fail = (e: Error) => {
      this.dead = e;
      for (const p of this.pending.values()) p.rej(e);
      this.pending.clear();
    };
    this.child.on('error', (e) =>
      fail(new Error(`Cannot start "${command}": ${e.message}`)),
    );
    this.child.on('exit', (c) =>
      fail(
        new Error(
          `MCP server exited (${c})${this.errTail ? ': ' + this.errTail.trim() : ''}`,
        ),
      ),
    );
    this.child.stdin!.on('error', () => {});
  }

  request(method: string, params?: unknown): Promise<any> {
    if (this.dead) return Promise.reject(this.dead);
    const id = this.nextId++;
    return new Promise((res, rej) => {
      const t = setTimeout(() => {
        this.pending.delete(id);
        rej(new Error(`MCP ${method} timed out`));
      }, TIMEOUT_MS);
      this.pending.set(id, {
        res: (v) => (clearTimeout(t), res(v)),
        rej: (e) => (clearTimeout(t), rej(e)),
      });
      this.child.stdin!.write(
        JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n',
      );
    });
  }
  async notify(method: string, params?: unknown): Promise<void> {
    this.child.stdin!.write(
      JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n',
    );
  }
  async close(): Promise<void> {
    this.child.stdin!.end();
    setTimeout(() => this.child.kill(), 500).unref();
  }
}

// ---- streamable HTTP ------------------------------------------------------------------------------------

class HttpSession implements Session {
  private nextId = 1;
  private sessionId?: string;
  constructor(
    private url: string,
    private bearer: string | undefined,
    private fetchFn: typeof fetch,
  ) {}

  private async post(body: unknown, expectId?: number): Promise<any> {
    const res = await this.fetchFn(this.url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        'mcp-protocol-version': PROTOCOL,
        ...(this.sessionId ? { 'mcp-session-id': this.sessionId } : {}),
        ...(this.bearer ? { authorization: `Bearer ${this.bearer}` } : {}),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    }).catch((e: unknown) => {
      const why =
        e instanceof Error
          ? ((e.cause as Error | undefined)?.message ?? e.message)
          : String(e);
      throw new Error(`Cannot reach the MCP server at ${this.url}: ${why}`);
    });
    this.sessionId = res.headers.get('mcp-session-id') ?? this.sessionId;
    if (res.status === 401 || res.status === 403)
      throw new Error(
        'MCP server refused the login: set the bearer token in the app.',
      );
    if (!res.ok) throw new Error(`MCP server answered HTTP ${res.status}`);
    if (expectId === undefined) return undefined;
    const text = await res.text();
    const msgs: any[] = /event-stream/i.test(
      res.headers.get('content-type') ?? '',
    )
      ? text.split(/\r?\n\r?\n/).flatMap((ev) => {
          const data = ev
            .split(/\r?\n/)
            .filter((l) => l.startsWith('data:'))
            .map((l) => l.slice(5).trimStart())
            .join('\n');
          try {
            return data ? [JSON.parse(data)] : [];
          } catch {
            return [];
          }
        })
      : [JSON.parse(text)].flat();
    const m = msgs.find((x) => x.id === expectId);
    if (!m) throw new Error('MCP server sent no response.');
    if (m.error) throw new Error(m.error.message ?? 'MCP error');
    return m.result;
  }

  request(method: string, params?: unknown): Promise<any> {
    const id = this.nextId++;
    return this.post({ jsonrpc: '2.0', id, method, params }, id);
  }
  async notify(method: string, params?: unknown): Promise<void> {
    await this.post({ jsonrpc: '2.0', method, params });
  }
  async close(): Promise<void> {
    if (!this.sessionId) return;
    await this.fetchFn(this.url, {
      method: 'DELETE',
      headers: { 'mcp-session-id': this.sessionId },
      signal: AbortSignal.timeout(3000),
    }).catch(() => {});
  }
}

// ---- client -----------------------------------------------------------------------------------------------

const slug = (s: string) =>
  s.replace(/[^A-Za-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '');
export const remoteToolName = (server: string, tool: string) =>
  clip(`mcp__${slug(server)}__${slug(tool)}`, 64);

/** Talks to external MCP servers. A connection lives for one operation (initialize, do it, close). */
export class McpClientImpl implements McpClient {
  /** Names of remote tools currently registered in the tool registry. */
  private registered = new Set<string>();
  constructor(private app: App) {}

  private async open(server: McpServerConfig): Promise<Session> {
    const s: Session =
      server.transport === 'http'
        ? new HttpSession(
            server.url ?? '',
            this.app.secrets.get(`mcp.${server.id}.bearer`),
            (...a) => this.app.fetch(...a),
          )
        : new StdioSession(
            server.command ?? '',
            server.args,
            Object.fromEntries(
              this.app.secrets
                .list(`mcp.${server.id}.env.`)
                .map((x) => [
                  x.name.slice(`mcp.${server.id}.env.`.length),
                  this.app.secrets.get(x.name) ?? '',
                ]),
            ),
          );
    try {
      await s.request('initialize', {
        protocolVersion: PROTOCOL,
        capabilities: {},
        clientInfo: { name: 'lotti-brain', version: this.app.config.version },
      });
      await s.notify('notifications/initialized');
      return s;
    } catch (e) {
      await s.close();
      throw e;
    }
  }

  private async use<T>(
    server: McpServerConfig,
    f: (s: Session) => Promise<T>,
  ): Promise<T> {
    const s = await this.open(server);
    try {
      return await f(s);
    } finally {
      await s.close();
    }
  }

  async listTools(server: McpServerConfig) {
    return this.use(server, async (s) => {
      const tools: {
        name: string;
        description?: string;
        inputSchema?: unknown;
      }[] = [];
      let cursor: string | undefined;
      do {
        const r = await s.request('tools/list', cursor ? { cursor } : {});
        tools.push(...(r.tools ?? []));
        cursor = r.nextCursor;
      } while (cursor && tools.length < 500);
      return tools;
    });
  }

  async test(server: McpServerConfig) {
    try {
      return {
        ok: true,
        tools: (await this.listTools(server)).map((t) => t.name),
      };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }

  async callTool(
    server: McpServerConfig,
    tool: string,
    args: unknown,
  ): Promise<string> {
    return this.use(server, async (s) => {
      const r = await s.request('tools/call', {
        name: tool,
        arguments: args ?? {},
      });
      const text = (r.content ?? [])
        .map((c: any) => (c.type === 'text' ? c.text : `[${c.type}]`))
        .join('\n');
      if (r.isError) throw new Error(text || 'The MCP tool reported an error.');
      return text || JSON.stringify(r.structuredContent ?? 'ok');
    });
  }

  private refreshing: Promise<void> = Promise.resolve();

  /**
   * (Re)register the tools of all enabled servers as `mcp__<server>__<tool>`. The new set is
   * collected first and swapped in at once (tools never vanish while a slow server answers);
   * overlapping refreshes run one after the other.
   */
  refresh(): Promise<void> {
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
    const run = this.refreshing.then(() => this.doRefresh());
    this.refreshing = run.catch(() => undefined);
    return run;
  }

  private retryTimer?: ReturnType<typeof setTimeout>;
  private retries = 0;
  /**
   * A server that was down at boot (tailnet not up yet, a restart) would otherwise stay without tools until
   * someone edits its config, and the model would have nothing to call. Retry with growing pauses.
   */
  private scheduleRetry(failed: number): void {
    if (!failed) {
      this.retries = 0;
      return;
    }
    const delay = Math.min(30_000 * 2 ** this.retries, 300_000);
    this.retries++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      void this.refresh().catch(() => undefined);
    }, delay);
    this.retryTimer.unref();
  }

  private async doRefresh(): Promise<void> {
    let failed = 0;
    const staged: {
      server: McpServerConfig;
      tools: { name: string; description?: string; inputSchema?: unknown }[];
    }[] = [];
    for (const server of loadMcpServers(this.app).filter((s) => s.enabled)) {
      try {
        const tools = await this.listTools(server);
        this.app.db.run(
          "UPDATE mcp_servers SET status='ok', last_error=NULL WHERE id=?",
          server.id,
        );
        staged.push({ server, tools });
      } catch (e) {
        failed++;
        this.app.log.warn(`MCP server ${server.name} unavailable`, String(e));
        this.app.db.run(
          "UPDATE mcp_servers SET status='error', last_error=? WHERE id=?",
          e instanceof Error ? e.message : String(e),
          server.id,
        );
      }
    }
    // Swap at once: tools and their `perform` handlers go together (a removed server leaves neither behind).
    for (const n of this.registered) {
      this.app.tools.unregister(n);
      this.app.actions.unregister(n);
    }
    this.registered.clear();
    for (const { server, tools } of staged) {
      for (const t of tools) this.registerTool(server, t);
      this.app.log.info(`MCP server ${server.name}: ${tools.length} tools`);
    }
    this.scheduleRetry(failed);
  }

  private registerTool(
    server: McpServerConfig,
    t: { name: string; description?: string; inputSchema?: unknown },
  ): void {
    const name = remoteToolName(server.name, t.name);
    const needs = mcpToolNeedsConfirmation(server, t.name);
    const call = (args: unknown) => {
      // Fresh config: the server may have been edited since registration.
      const cur = loadMcpServers(this.app).find((s) => s.id === server.id);
      if (!cur?.enabled) throw new Error('This MCP server is turned off.');
      return this.callTool(cur, t.name, args);
    };
    const def: ToolDef = {
      name,
      description: `[${server.name}] ${t.description ?? t.name}${needs ? ' Only PROPOSES: the user must tap to confirm, then it runs.' : ''}`,
      inputSchema: z.looseObject({}),
      jsonSchema:
        t.inputSchema && typeof t.inputSchema === 'object'
          ? (t.inputSchema as Record<string, unknown>)
          : { type: 'object', properties: {} },
      kind: 'server',
      needsConfirmation: needs,
      async handler(args, ctx) {
        const cur =
          loadMcpServers(ctx.app).find((s) => s.id === server.id) ?? server;
        if (mcpToolNeedsConfirmation(cur, t.name))
          return proposeAction(ctx, {
            title: clip(`${server.name}: ${t.name}`, 60),
            target: 'server',
            tool: name,
            args,
          });
        return call(args);
      },
    };
    this.app.tools.register(def);
    this.registered.add(name);
    // Runs after `perform` of a proposed call.
    this.app.actions.register(name, async (args) => {
      try {
        return { ok: true, text: clip(await call(args), 4000) };
      } catch (e) {
        return { ok: false, text: e instanceof Error ? e.message : String(e) };
      }
    });
  }
}
