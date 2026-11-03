import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import type { App } from '../app.ts';
import type { ToolDef } from './registry.ts';

export interface ShellResult {
  text: string;
  exitCode: number | null;
  timedOut: boolean;
  truncated: boolean;
}

/**
 * Runs `/bin/sh -c command` in DATA_DIR/workspace with a minimal env (no secrets, no MASTER_KEY),
 * a timeout (process group is killed) and an output cap. Every command is logged to `shell_log`.
 * In Docker the process runs as a non-root user.
 */
export async function runShell(
  app: App,
  command: string,
  opts: { timeoutSec?: number; signal?: AbortSignal } = {},
): Promise<ShellResult> {
  const cwd = app.config.workspaceDir;
  mkdirSync(cwd, { recursive: true });
  const timeoutSec = Math.min(
    opts.timeoutSec ?? app.settings.num('shell.timeout_sec'),
    app.settings.num('shell.timeout_sec'),
  );
  const cap = app.settings.num('shell.max_output_chars');
  const started = app.clock.now();
  const t0 = Date.now();
  app.skills.markScriptsInCommand(command);
  return new Promise<ShellResult>((resolve) => {
    const child = spawn('/bin/sh', ['-c', command], {
      cwd,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        PATH: `${join(cwd, 'scripts')}:/usr/local/bin:/usr/bin:/bin`,
        HOME: cwd,
        LANG: 'C.UTF-8',
        TERM: 'dumb',
      },
    });
    let out = '';
    let truncated = false;
    let timedOut = false;
    const take = (b: Buffer) => {
      if (out.length >= cap) {
        truncated = true;
        return;
      }
      const s = b.toString('utf8');
      if (out.length + s.length > cap) {
        out += s.slice(0, cap - out.length);
        truncated = true;
      } else out += s;
    };
    child.stdout.on('data', take);
    child.stderr.on('data', take);
    const kill = () => {
      try {
        if (child.pid) process.kill(-child.pid, 'SIGKILL');
      } catch {
        /* already gone */
      }
    };
    const timer = setTimeout(() => {
      timedOut = true;
      kill();
    }, timeoutSec * 1000);
    const onAbort = () => kill();
    opts.signal?.addEventListener('abort', onAbort, { once: true });
    const finish = (code: number | null) => {
      clearTimeout(timer);
      opts.signal?.removeEventListener('abort', onAbort);
      app.db.run(
        'INSERT INTO shell_log(at,command,exit_code,duration_ms,timed_out,truncated,output) VALUES(?,?,?,?,?,?,?)',
        started,
        command,
        code,
        Date.now() - t0,
        timedOut ? 1 : 0,
        truncated ? 1 : 0,
        out.slice(0, 2000),
      );
      let text = out;
      if (truncated) text += `\n[output truncated at ${cap} characters]`;
      if (timedOut) text += `\n[timed out after ${timeoutSec} s and killed]`;
      else text += `\n[exit code ${code}]`;
      resolve({ text: text.trim(), exitCode: code, timedOut, truncated });
    };
    child.on('error', (e) => {
      out += String(e);
      finish(127);
    });
    child.on('close', (code) => finish(code));
  });
}

const schema = z.object({
  command: z
    .string()
    .min(1)
    .describe(
      'Shell command (sh). Runs in the workspace; scripts/ is on PATH.',
    ),
  timeoutSec: z
    .number()
    .int()
    .min(1)
    .max(600)
    .optional()
    .describe('Timeout in seconds (capped by the safety setting)'),
});

export const shellTool: ToolDef = {
  name: 'shell',
  description:
    "Run a shell command in Lotti's workspace (curl, rg, jq, git, python3 available). No secrets in the environment. " +
    'Output is capped and commands time out. Use it for small automations and for scripts in scripts/.',
  inputSchema: schema,
  kind: 'server',
  status: { de: 'Führe Befehl aus …', en: 'Running a command …' },
  async handler(args: z.infer<typeof schema>, { app, run }) {
    if (!app.settings.bool('shell.enabled'))
      return 'The shell tool is turned off in the settings.';
    const r = await runShell(app, args.command, {
      ...(args.timeoutSec ? { timeoutSec: args.timeoutSec } : {}),
      ...(run.signal ? { signal: run.signal } : {}),
    });
    return r.text;
  },
};
