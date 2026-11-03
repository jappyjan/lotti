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

export function createHttpServer(app: App): Server {
  const failures = new Map<string, { n: number; since: number }>();
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
  failures: Map<string, { n: number; since: number }>,
): Promise<void> {
  const url = new URL(req.url ?? '/', 'http://x');
  const path = url.pathname;
  const method = req.method ?? 'GET';

  if (path === '/health' && method === 'GET')
    return send(res, 200, { ok: true });

  if (path === '/api/v1/pair' && method === 'POST') {
    const ip = req.socket.remoteAddress ?? '?';
    const f = failures.get(ip);
    const now = Date.now();
    if (f && now - f.since < 10 * 60_000 && f.n >= 10)
      throw new HttpError(429, 'Too many attempts');
    const b = (await readJson(req)) as { code?: string; deviceName?: string };
    const r =
      typeof b.code === 'string'
        ? app.auth.pair(b.code, String(b.deviceName ?? 'device'))
        : null;
    if (!r) {
      failures.set(
        ip,
        !f || now - f.since >= 10 * 60_000
          ? { n: 1, since: now }
          : { n: f.n + 1, since: f.since },
      );
      throw new HttpError(401, 'Invalid or used pairing code');
    }
    app.log.info(`paired device ${b.deviceName ?? 'device'}`);
    return send(res, 200, { token: r.token });
  }

  if (path === '/api/v1/pair/code' && method === 'GET') {
    const ip = req.socket.remoteAddress ?? '';
    if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(ip))
      throw new HttpError(
        403,
        'Only from the server itself (see the server logs)',
      );
    const code = app.auth.currentPairingCode() ?? app.auth.newPairingCode();
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
      const r = await app.ops.invoke(m[1]!, await readJson(req), 'app');
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
