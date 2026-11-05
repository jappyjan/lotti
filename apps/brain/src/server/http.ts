import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from 'node:http';
import type { AddressInfo } from 'node:net';
import type { App } from '../app.ts';
import { bearerOf, attachWebSocket, closeWebSockets } from './ws.ts';
import { handleMcp } from './mcp.ts';
import { callbackBounce } from '../integrations/oauth/common.ts';

const MAX_BODY = 2_000_000;

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of req) {
    n += (c as Buffer).length;
    if (n > MAX_BODY) throw new HttpError(413, 'Body too large');
    chunks.push(c as Buffer);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'Invalid JSON');
  }
}

class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

function send(res: ServerResponse, status: number, body: unknown): void {
  const s = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(s);
}

export interface RunningServer {
  server: Server;
  port: number;
  close(): Promise<void>;
}

const FAIL_WINDOW_MS = 10 * 60_000;
const FAIL_PER_IP = 10;

/** Wrong pairing codes per IP and in total, over a sliding 10 minute window. Old entries are pruned. */
export class PairFailures {
  private perIp = new Map<string, number[]>();
  blocked(ip: string, now: number): boolean {
    this.prune(now);
    // Per IP only: a global cap would let anyone block pairing for everyone. Brute force stays
    // out of reach anyway (single-use 8-character codes that expire after 15 minutes).
    return (this.perIp.get(ip)?.length ?? 0) >= FAIL_PER_IP;
  }
  note(ip: string, now: number): void {
    this.prune(now);
    this.perIp.set(ip, [...(this.perIp.get(ip) ?? []), now]);
  }
  /** Number of IPs tracked (for tests). */
  get size(): number {
    return this.perIp.size;
  }
  private prune(now: number): void {
    const cut = now - FAIL_WINDOW_MS;
    for (const [ip, ts] of this.perIp) {
      const keep = ts.filter((t) => t > cut);
      if (keep.length) this.perIp.set(ip, keep);
      else this.perIp.delete(ip);
    }
  }
}

export function createHttpServer(app: App): Server {
  const failures = new PairFailures();
  const server = createServer((req, res) => {
    route(app, req, res, failures).catch((e) => {
      if (e instanceof HttpError)
        send(res, e.status, { ok: false, error: e.message });
      else {
        app.log.error('http error', e instanceof Error ? e.stack : String(e));
        send(res, 500, { ok: false, error: 'Internal error' });
      }
    });
  });
  attachWebSocket(app, server);
  return server;
}

async function route(
  app: App,
  req: IncomingMessage,
  res: ServerResponse,
  failures: PairFailures,
): Promise<void> {
  const url = new URL(req.url ?? '/', 'http://x');
  const path = url.pathname;
  const method = req.method ?? 'GET';

  if (path === '/health' && method === 'GET')
    return send(res, 200, { ok: true });

  // OAuth redirect target for providers that want an https URL. No auth: the browser has none. It only
  // bounces to the app's fixed scheme with the allow-listed parameters (the code is useless without
  // the server-side PKCE verifier and single-use state).
  if (path === '/oauth/callback' && method === 'GET') {
    const target = callbackBounce(url.searchParams);
    if (!target) throw new HttpError(400, 'Missing state');
    const esc = target.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
    res.writeHead(302, {
      location: target,
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
    res.end(
      `<!doctype html><meta charset="utf-8"><title>Lotti</title><p>Back to Lotti: <a href="${esc}">open the app</a></p>`,
    );
    return;
  }

  if (path === '/api/v1/pair' && method === 'POST') {
    const ip = req.socket.remoteAddress ?? '?';
    const now = app.clock.now();
    if (failures.blocked(ip, now))
      throw new HttpError(429, 'Too many attempts');
    const b = (await readJson(req)) as { code?: string; deviceName?: string };
    const r =
      typeof b.code === 'string'
        ? app.auth.pair(b.code, String(b.deviceName ?? 'device'))
        : null;
    if (!r) {
      failures.note(ip, now);
      throw new HttpError(401, 'Invalid, used or expired pairing code');
    }
    app.log.info(`paired device ${b.deviceName ?? 'device'}`);
    return send(res, 200, { token: r.token });
  }

  if (path === '/api/v1/pair/code' && method === 'GET') {
    const ip = req.socket.remoteAddress ?? '';
    // A reverse proxy / `tailscale serve` on the same host connects from loopback for everyone;
    // forwarded-* headers mean the request did not originate on this machine.
    const proxied = ['x-forwarded-for', 'forwarded', 'x-real-ip'].some(
      (h) => req.headers[h] !== undefined,
    );
    if (proxied || !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(ip))
      throw new HttpError(
        403,
        'Only from the server itself (see the server logs)',
      );
    // Anything on this host can reach loopback (the agent's shell, web_fetch, ...): once a device is
    // paired, new codes come only from the app (pairing.new_code).
    if (app.auth.hasDevices())
      throw new HttpError(
        403,
        'Already paired: create a pairing code in the app.',
      );
    const code = app.auth.ensureStartupCode()!;
    app.log.info(`Pairing code: ${code}`);
    return send(res, 200, { code });
  }

  if (path === '/mcp/admin' || path === '/mcp/tools') {
    const mode = path === '/mcp/admin' ? 'admin' : 'tools';
    const token = bearerOf(req);
    if (mode === 'admin' && app.auth.adminTokens().length === 0)
      throw new HttpError(404, 'Not found'); // OFF until a token exists
    if (
      !(mode === 'admin'
        ? app.auth.verifyAdmin(token)
        : app.auth.verifyInternal(token))
    )
      throw new HttpError(401, 'Unauthorized');
    if (method !== 'POST') throw new HttpError(405, 'POST JSON-RPC only');
    const out = await handleMcp(app, mode, await readJson(req), req.headers);
    if (out === null) {
      res.writeHead(202);
      res.end();
      return;
    }
    return send(res, 200, out);
  }

  if (path.startsWith('/api/v1/')) {
    const device = app.auth.verifyDevice(bearerOf(req));
    if (!device) throw new HttpError(401, 'Unauthorized');
    if (path === '/api/v1/ops' && method === 'GET')
      return send(res, 200, app.ops.describe('app'));
    const m = /^\/api\/v1\/ops\/([\w.]+)$/.exec(path);
    if (m && method === 'POST') {
      const r = await app.ops.invoke(m[1]!, await readJson(req), 'app', {
        deviceId: device.id,
      });
      if (!r.ok)
        return send(res, r.error.startsWith('Unknown operation') ? 404 : 400, {
          ok: false,
          error: r.error,
        });
      return send(res, 200, {
        ok: true,
        result: r.result,
        ...(r.undoHandle ? { undo: r.undoHandle } : {}),
      });
    }
    throw new HttpError(404, 'Not found');
  }
  throw new HttpError(404, 'Not found');
}

export function listen(
  app: App,
  port = app.config.port,
): Promise<RunningServer> {
  const server = createHttpServer(app);
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, () => {
      const actual = (server.address() as AddressInfo).port;
      resolve({
        server,
        port: actual,
        close: () =>
          new Promise<void>((r) => {
            closeWebSockets(server);
            server.closeAllConnections();
            server.close(() => r());
          }),
      });
    });
  });
}
