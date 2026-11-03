import { spawn, type ChildProcess } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { App } from '../../app.ts';
import type {
  AgentRuntimeProvider,
  RuntimeRequest,
} from '../../providers/types.ts';
import { baseEnv, runProc, stripAnsi } from './proc.ts';

export interface CodexLoginState {
  state: 'idle' | 'pending' | 'done' | 'error';
  url?: string;
  code?: string;
  startedAt?: number;
  error?: string;
}

/** Parse the output of `codex login --device-auth`. */
export function parseDeviceAuth(raw: string): { url?: string; code?: string } {
  const t = stripAnsi(raw);
  const url = /https:\/\/\S+/.exec(t)?.[0];
  const after =
    /one-time code[\s\S]*?\n\s*([A-Z0-9]{3,6}-[A-Z0-9]{3,8})\b/i.exec(t)?.[1];
  const code = after ?? /\b([A-Z0-9]{4}-[A-Z0-9]{4,6})\b/.exec(t)?.[1];
  return { ...(url ? { url } : {}), ...(code ? { code } : {}) };
}

/**
 * Codex (ChatGPT subscription) via the `codex` CLI. Login state lives in DATA_DIR/codex (CODEX_HOME).
 * `run` = `codex exec` with Lotti's tools attached as an MCP server (/mcp/tools).
 */
export class CodexRuntime implements AgentRuntimeProvider {
  readonly kind = 'agent-runtime' as const;
  readonly id = 'codex';
  readonly label = 'Codex (subscription)';
  readonly defaultModel = '';
  readonly knownModels: string[] = [];
  readonly home: string;
  private login?: { child: ChildProcess; st: CodexLoginState };
  private lastLogin: CodexLoginState = { state: 'idle' };

  constructor(
    private app: App,
    private bin = 'codex',
  ) {
    this.home = join(app.config.dataDir, 'codex');
  }

  private env(extra: Record<string, string> = {}) {
    mkdirSync(this.home, { recursive: true });
    return baseEnv({ CODEX_HOME: this.home, ...extra });
  }
  private static STORE = ['-c', 'cli_auth_credentials_store="file"'];

  configured(): boolean {
    return existsSync(join(this.home, 'auth.json'));
  }

  /** Real check via the CLI (`codex login status`). */
  async loggedIn(): Promise<boolean> {
    try {
      const r = await runProc(
        this.bin,
        ['login', ...CodexRuntime.STORE, 'status'],
        {
          env: this.env(),
          timeoutMs: 15_000,
        },
      );
      return r.code === 0;
    } catch {
      return false;
    }
  }

  /** Spawn `codex login --device-auth`; resolves with the URL + code the user must enter. */
  async loginStart(timeoutMs = 20_000): Promise<CodexLoginState> {
    if (this.login?.st.state === 'pending') return this.login.st;
    const st: CodexLoginState = {
      state: 'pending',
      startedAt: this.app.clock.now(),
    };
    let out = '';
    const child = spawn(
      this.bin,
      ['login', ...CodexRuntime.STORE, '--device-auth'],
      {
        env: this.env(),
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    this.login = { child, st };
    const onData = (d: Buffer | string) => {
      out += String(d);
      Object.assign(st, parseDeviceAuth(out));
    };
    child.stdout!.on('data', onData);
    child.stderr!.on('data', onData);
    child.on('error', (e) => {
      st.state = 'error';
      st.error = `Cannot run ${this.bin}: ${e.message}`;
    });
    child.on('close', (code) => {
      if (st.state === 'pending') {
        st.state = code === 0 ? 'done' : 'error';
        if (code !== 0)
          st.error =
            stripAnsi(out).trim().split('\n').slice(-3).join(' ') ||
            `codex exited ${code}`;
      }
      this.lastLogin = { ...st };
      if (this.login?.st === st) this.login = undefined;
    });
    // Wait for the code (or the failure).
    const t0 = Date.now();
    while (
      Date.now() - t0 < timeoutMs &&
      st.state === 'pending' &&
      !(st.url && st.code)
    )
      await new Promise((r) => setTimeout(r, 50));
    if (st.state === 'pending' && !(st.url && st.code)) {
      child.kill();
      st.state = 'error';
      st.error = 'Codex did not show a login code in time.';
    }
    return { ...st };
  }

  async loginStatus(): Promise<CodexLoginState & { loggedIn: boolean }> {
    const cur = this.login?.st ?? this.lastLogin;
    const loggedIn = cur.state === 'pending' ? false : await this.loggedIn();
    return {
      ...cur,
      state: loggedIn && cur.state !== 'pending' ? 'done' : cur.state,
      loggedIn,
    };
  }

  async logout(): Promise<void> {
    this.login?.child.kill();
    await runProc(this.bin, ['logout', ...CodexRuntime.STORE], {
      env: this.env(),
      timeoutMs: 15_000,
    }).catch(() => {});
    this.lastLogin = { state: 'idle' };
  }

  async run(req: RuntimeRequest): Promise<{ text: string }> {
    if (!this.configured())
      throw new Error(
        'Codex is not signed in: log in from the app (providers.codex_login_start).',
      );
    const dir = mkdtempSync(join(tmpdir(), 'lotti-codex-'));
    const outFile = join(dir, 'last.txt');
    mkdirSync(this.app.config.workspaceDir, { recursive: true });
    const mcp = req.mcpServers[0];
    const model = req.model || this.app.providers.modelFor(this.id);
    const args = [
      'exec',
      '--skip-git-repo-check',
      '--ephemeral',
      '--color',
      'never',
      '--sandbox',
      'read-only',
      '-o',
      outFile,
      ...CodexRuntime.STORE,
      '-c',
      'approval_policy="never"',
      ...(mcp
        ? [
            '-c',
            `mcp_servers.${mcp.name}.url=${JSON.stringify(mcp.url)}`,
            '-c',
            `mcp_servers.${mcp.name}.bearer_token_env_var="LOTTI_TOOLS_TOKEN"`,
            ...(req.askId
              ? [
                  '-c',
                  `mcp_servers.${mcp.name}.http_headers={"X-Lotti-Ask"=${JSON.stringify(req.askId)}}`,
                ]
              : []),
          ]
        : []),
      ...(model ? ['-m', model] : []),
      '-',
    ];
    try {
      req.onStatus?.('Codex …');
      const r = await runProc(this.bin, args, {
        env: this.env(mcp ? { LOTTI_TOOLS_TOKEN: mcp.bearerToken } : {}),
        cwd: this.app.config.workspaceDir,
        input: `${req.system}\n\n${req.prompt}`,
        ...(req.signal ? { signal: req.signal } : {}),
      });
      const text = existsSync(outFile)
        ? readFileSync(outFile, 'utf8').trim()
        : '';
      if (r.code !== 0 && !text)
        throw new Error(
          `Codex failed (${r.code}): ${stripAnsi(r.stderr || r.stdout)
            .trim()
            .slice(-400)}`,
        );
      return { text: text || stripAnsi(r.stdout).trim() };
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
}
