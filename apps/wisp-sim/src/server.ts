import { readFile } from 'node:fs/promises';
import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, type RawData, type WebSocket } from 'ws';
import { LENS_H, LENS_W, SimCore, type Lens, type LensStats } from './core.ts';
import { SimStorage } from './storage.ts';

export interface SimOptions {
  /** Default 8360; 0 picks a free port. */
  port?: number;
  /** Default 127.0.0.1 (the simulator is a local tool). */
  host?: string;
  /** Mirror persisted resources to this directory. */
  dataDir?: string;
  /** persist_bytes. Default 8 MiB. */
  persistBytes?: number;
  /** Tick period for animations and tweens. Default 4 ms. */
  tickMs?: number;
  log?: (line: string) => void;
}

export interface Sim {
  readonly core: SimCore;
  /** http://host:port/ — the viewer. */
  readonly url: string;
  /** ws://host:port/link — what an SDK connects to (right temple, mirrored to both lenses). */
  readonly linkUrl: string;
  readonly port: number;
  close(): Promise<void>;
}

const VIEWER = new URL('../../viewer/', import.meta.url);
const TYPES: Record<string, string> = {
  html: 'text/html; charset=utf-8',
  js: 'text/javascript; charset=utf-8',
  css: 'text/css; charset=utf-8',
};

/** Viewer → simulator input. */
type ViewerInput =
  | { type: 'touch'; lens: Lens; phase: number; pos: number }
  | { type: 'gesture'; lens: Lens; kind: number }
  | { type: 'wear'; worn: boolean };

const asBytes = (d: RawData): Uint8Array =>
  Array.isArray(d)
    ? new Uint8Array(Buffer.concat(d))
    : d instanceof ArrayBuffer
      ? new Uint8Array(d)
      : new Uint8Array(d.buffer, d.byteOffset, d.byteLength);

/**
 * Starts the simulator: the core in WebAssembly, phone links on
 * `ws://…/link?lens=left|right&mirror=0|1` (binary messages carry the Wisp
 * byte stream), the viewer on `/` with its own socket on `/viewer`, and a
 * small HTTP API (`/api/stats`, `/api/frame?lens=1|2` as RAW4, `POST /api/input`).
 */
export async function startSim(opts: SimOptions = {}): Promise<Sim> {
  const log = opts.log ?? (() => {});
  const core = await SimCore.create({
    storage: new SimStorage(opts.persistBytes, opts.dataDir),
  });
  const links = new Map<number, WebSocket>();
  const viewers = new Set<WebSocket>();
  let worn = true;

  const pump = () => {
    for (const [id, ws] of links) {
      for (;;) {
        const out = core.pull(id);
        if (!out.length) break;
        ws.send(out);
      }
    }
  };

  const input = (m: ViewerInput) => {
    if (m.type === 'touch') core.touch(m.lens, m.phase, m.pos);
    else if (m.type === 'gesture') core.gesture(m.lens, m.kind);
    else if (m.type === 'wear') core.setWorn((worn = m.worn));
    pump();
  };

  // Frames per second over the last ~second, per lens.
  const started = performance.now();
  const rate = {
    1: { frame: 0, at: started, fps: 0 },
    2: { frame: 0, at: started, fps: 0 },
  };
  const lensStats = (lens: Lens) => {
    const s = core.stats(lens);
    const r = rate[lens];
    const now = performance.now();
    if (now - r.at >= 1000 || s.frame < r.frame) {
      r.fps =
        s.frame >= r.frame ? ((s.frame - r.frame) * 1000) / (now - r.at) : 0;
      r.frame = s.frame;
      r.at = now;
    }
    return { ...s, fps: Math.round(r.fps * 10) / 10 };
  };
  const stats = () => ({
    type: 'stats',
    links: links.size,
    viewers: viewers.size,
    worn,
    persistBytes: core.storage.bytes,
    lenses: { 1: lensStats(1), 2: lensStats(2) } as Record<
      Lens,
      LensStats & { fps: number }
    >,
  });

  // Frame updates for viewers: [1, lens, x u16, y u16, w u16, h u16, display_on, rows…]
  const display = { 1: { on: true, frame: 0 }, 2: { on: true, frame: 0 } };
  const update = (
    lens: Lens,
    r: { x: number; y: number; w: number; h: number },
    on: boolean,
  ) => {
    const px = core.region(lens, r);
    const msg = new Uint8Array(11 + px.length);
    const v = new DataView(msg.buffer);
    msg[0] = 1;
    msg[1] = lens;
    v.setUint16(2, r.x, true);
    v.setUint16(4, r.y, true);
    v.setUint16(6, r.w, true);
    v.setUint16(8, r.h, true);
    msg[10] = on ? 1 : 0;
    msg.set(px, 11);
    return msg;
  };
  const pushFrames = () => {
    for (const lens of [1, 2] as const) {
      const d = core.takeDamage(lens);
      const powerChanged = d.displayOn !== display[lens].on;
      display[lens] = { on: d.displayOn, frame: d.frame };
      if (!viewers.size) continue;
      const r = powerChanged ? { x: 0, y: 0, w: LENS_W, h: LENS_H } : d.damage;
      if (!r) continue;
      const msg = update(lens, r, d.displayOn);
      for (const v of viewers) v.send(msg);
    }
  };

  const tickMs = opts.tickMs ?? 4;
  const ticker = setInterval(() => {
    const ended = core.tick();
    if (ended) log(`session timed out on lens mask ${ended}`);
    pump();
  }, tickMs);
  const framer = setInterval(pushFrames, 16);
  const statser = setInterval(() => {
    if (!viewers.size) return;
    const s = JSON.stringify(stats());
    for (const v of viewers) v.send(s);
  }, 500);

  const serveFile = async (res: ServerResponse, name: string) => {
    try {
      const body = await readFile(new URL(name, VIEWER));
      res.writeHead(200, {
        'content-type':
          TYPES[name.split('.').pop()!] ?? 'application/octet-stream',
      });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  };

  const http = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? '/', 'http://sim');
    if (url.pathname === '/' || url.pathname === '/index.html')
      return void serveFile(res, 'index.html');
    if (/^\/[\w-]+\.(js|css)$/.test(url.pathname))
      return void serveFile(res, url.pathname.slice(1));
    if (url.pathname === '/api/stats') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return void res.end(JSON.stringify(stats()));
    }
    if (url.pathname === '/api/frame') {
      const lens = url.searchParams.get('lens') === '1' ? 1 : 2;
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'x-wisp-size': `${LENS_W}x${LENS_H}`,
      });
      return void res.end(core.frame(lens));
    }
    if (url.pathname === '/api/input' && req.method === 'POST') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        try {
          input(JSON.parse(body) as ViewerInput);
          res.writeHead(204).end();
        } catch (err) {
          res.writeHead(400).end(String(err));
        }
      });
      return;
    }
    res.writeHead(404).end('not found');
  });

  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  http.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://sim');
    if (url.pathname !== '/link' && url.pathname !== '/viewer')
      return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (url.pathname === '/viewer') {
        viewers.add(ws);
        for (const lens of [1, 2] as const)
          ws.send(
            update(
              lens,
              { x: 0, y: 0, w: LENS_W, h: LENS_H },
              display[lens].on,
            ),
          );
        ws.send(JSON.stringify(stats()));
        ws.on('message', (d, binary) => {
          if (binary) return;
          try {
            input(JSON.parse(String(d)) as ViewerInput);
          } catch {
            /* ignore bad input */
          }
        });
        ws.on('close', () => viewers.delete(ws));
        return;
      }
      const lens: Lens = url.searchParams.get('lens') === 'left' ? 1 : 2;
      const mirror = url.searchParams.get('mirror') !== '0';
      const id = core.openLink(lens, mirror);
      links.set(id, ws);
      log(
        `link ${id} open (lens ${lens === 1 ? 'left' : 'right'}${mirror ? ', mirrored' : ''})`,
      );
      ws.on('message', (d) => {
        core.receive(id, asBytes(d));
        pump();
      });
      ws.on('close', () => {
        links.delete(id);
        core.closeLink(id);
        log(`link ${id} closed`);
      });
    });
  });

  const host = opts.host ?? '127.0.0.1';
  await new Promise<void>((resolve, reject) => {
    http.once('error', reject);
    http.listen(opts.port ?? 8360, host, () => resolve());
  });
  const port = (http.address() as AddressInfo).port;
  const base = `${host.includes(':') ? `[${host}]` : host}:${port}`;
  return {
    core,
    port,
    url: `http://${base}/`,
    linkUrl: `ws://${base}/link`,
    async close() {
      clearInterval(ticker);
      clearInterval(framer);
      clearInterval(statser);
      for (const ws of [...links.values(), ...viewers]) ws.terminate();
      wss.close();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    },
  };
}
