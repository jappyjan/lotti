import { spawn } from 'node:child_process';

export interface ProcResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

/**
 * Run a subprocess to completion (stdin optional). It runs in its own process group; abort, `timeoutMs`
 * (total) or `idleTimeoutMs` (no output for that long) kill the whole group: SIGTERM, then SIGKILL after 3 s.
 */
export function runProc(
  bin: string,
  args: string[],
  o: {
    env?: Record<string, string>;
    cwd?: string;
    input?: string;
    signal?: AbortSignal;
    timeoutMs?: number;
    idleTimeoutMs?: number;
  } = {},
): Promise<ProcResult> {
  return new Promise((resolve, reject) => {
    if (o.signal?.aborted) return reject(new Error('cancelled'));
    const child = spawn(bin, args, {
      env: o.env,
      ...(o.cwd ? { cwd: o.cwd } : {}),
      stdio: ['pipe', 'pipe', 'pipe'],
      detached: true,
    });
    let stdout = '';
    let stderr = '';
    let exited = false;
    const cap = (s: string, d: string) => (s + d).slice(-200_000);
    const killGroup = (sig: NodeJS.Signals) => {
      try {
        if (child.pid) process.kill(-child.pid, sig);
      } catch {
        try {
          child.kill(sig);
        } catch {
          /* gone */
        }
      }
    };
    const kill = () => {
      killGroup('SIGTERM');
      setTimeout(() => {
        if (!exited) killGroup('SIGKILL');
      }, 3000).unref();
    };
    const onAbort = () => {
      kill();
      reject(new Error('cancelled'));
    };
    o.signal?.addEventListener('abort', onAbort, { once: true });
    const timer = setTimeout(() => {
      kill();
      reject(
        new Error(
          `${bin} timed out after ${Math.round((o.timeoutMs ?? 0) / 1000)} s`,
        ),
      );
    }, o.timeoutMs ?? 300_000);
    let idle: ReturnType<typeof setTimeout> | undefined;
    const armIdle = () => {
      if (!o.idleTimeoutMs) return;
      clearTimeout(idle);
      idle = setTimeout(() => {
        kill();
        reject(
          new Error(
            `${bin} was silent for ${Math.round(o.idleTimeoutMs! / 1000)} s`,
          ),
        );
      }, o.idleTimeoutMs);
    };
    armIdle();
    child.stdout.setEncoding('utf8').on('data', (d: string) => {
      stdout = cap(stdout, d);
      armIdle();
    });
    child.stderr.setEncoding('utf8').on('data', (d: string) => {
      stderr = cap(stderr, d);
      armIdle();
    });
    const done = () => {
      clearTimeout(timer);
      clearTimeout(idle);
      o.signal?.removeEventListener('abort', onAbort);
    };
    child.on('exit', () => (exited = true));
    child.on('error', (e) => {
      done();
      reject(new Error(`Cannot run ${bin}: ${e.message}`));
    });
    child.on('close', (code) => {
      exited = true;
      done();
      resolve({ code, stdout, stderr });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(o.input ?? '');
  });
}

/** Only what a CLI needs from the environment (never MASTER_KEY etc.). */
export function baseEnv(extra: Record<string, string>): Record<string, string> {
  const keep = ['PATH', 'HOME', 'LANG', 'TMPDIR', 'USER', 'SHELL', 'LC_ALL'];
  return {
    ...Object.fromEntries(
      keep.flatMap((k) => (process.env[k] ? [[k, process.env[k]!]] : [])),
    ),
    ...extra,
  };
}

export const stripAnsi = (s: string) =>
  // eslint-disable-next-line no-control-regex
  s.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '');
