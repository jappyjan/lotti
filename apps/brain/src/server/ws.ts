import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocketServer, type WebSocket } from 'ws';
import type { App } from '../app.ts';
import { CancelledError, reportAction } from '../agent/loop.ts';
import { PRESENCE_EVENTS } from '../catchup.ts';
import { isoLocal, parseIso, parseOffsetMin } from '../util/clock.ts';
import { newId } from '../util/crypto.ts';
import { MAINTAIN_WAIT_MS } from '../conversations.ts';
import type { Conn } from './hub.ts';

/** `Authorization: Bearer …` only (HTTP routes never take a token from the URL: it leaks into logs). */
export function bearerOf(req: IncomingMessage): string | undefined {
  const h = req.headers.authorization;
  if (h?.toLowerCase().startsWith('bearer ')) return h.slice(7).trim();
  return undefined;
}

/** The `/ws` upgrade also accepts `?token=` (some WebSocket clients cannot set headers). */
function wsTokenOf(req: IncomingMessage): string | undefined {
  return (
    bearerOf(req) ??
    new URL(req.url ?? '/', 'http://x').searchParams.get('token') ??
    undefined
  );
}

const sockets = new WeakMap<Server, WebSocketServer>();

/** Terminate all live sockets of a server (used on shutdown). */
export function closeWebSockets(server: Server): void {
  for (const c of sockets.get(server)?.clients ?? []) c.terminate();
}

/** Live socket per docs/protocol.md. Attach to the http server; path /ws. */
export function attachWebSocket(app: App, server: Server): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1_000_000 });
  sockets.set(server, wss);
  // Liveness: a phone that vanished (network gone, app killed) never sends a close. Without this the hub
  // keeps the dead socket, pushes are sent into the void and APNs never fires.
  const alive = new WeakMap<WebSocket, boolean>();
  const ping = setInterval(() => {
    for (const ws of wss.clients) {
      if (alive.get(ws) === false) {
        ws.terminate(); // emits 'close' -> hub.remove
        continue;
      }
      alive.set(ws, false);
      try {
        ws.ping();
      } catch {
        ws.terminate();
      }
    }
  }, app.config.wsPingIntervalMs);
  ping.unref?.();
  server.on('close', () => clearInterval(ping));
  server.on('upgrade', (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(req.url ?? '/', 'http://x');
    if (url.pathname !== '/ws') {
      socket.destroy();
      return;
    }
    const device = app.auth.verifyDevice(wsTokenOf(req));
    if (!device) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      alive.set(ws, true);
      ws.on('pong', () => alive.set(ws, true));
      onConnection(app, ws, device.id, device.name);
    });
  });
  return wss;
}

function onConnection(
  app: App,
  ws: WebSocket,
  deviceId: string,
  deviceName: string,
): void {
  const conn: Conn = {
    id: newId('conn_'),
    deviceId,
    deviceName,
    ready: false,
    send: (m) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(m));
    },
    close: () => ws.close(),
  };
  app.hub.add(conn);
  ws.on('close', () => app.hub.remove(conn));
  ws.on('error', () => app.hub.remove(conn));
  let chain: Promise<void> = Promise.resolve();
  ws.on('message', (data) => {
    let msg: any;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      conn.send({ type: 'error', message: 'Invalid JSON.' });
      return;
    }
    if (!msg || typeof msg.type !== 'string') {
      conn.send({ type: 'error', message: 'Missing "type".' });
      return;
    }
    // hello must complete before other messages are handled (they queue behind it)
    const run = () =>
      handle(app, conn, msg).catch((e) => {
        app.log.error(
          'ws handler failed',
          e instanceof Error ? e.stack : String(e),
        );
        conn.send({
          type: 'error',
          ...(msg.id ? { id: String(msg.id) } : {}),
          message: e instanceof Error ? e.message : String(e),
        });
      });
    if (msg.type === 'hello') chain = chain.then(run);
    else if (!conn.ready)
      chain = chain.then(() => handle(app, conn, { type: 'hello' }).then(run));
    else void run();
  });
}

/** How long `hello` waits for conversation maintenance before welcoming (it continues in the background). */
export const HELLO_MAINTAIN_MS = MAINTAIN_WAIT_MS;

export async function handle(app: App, conn: Conn, msg: any): Promise<void> {
  const hub = app.hub;
  switch (msg.type) {
    case 'hello': {
      if (conn.ready) return;
      app.auth.touchDevice(
        conn.deviceId,
        msg.deviceName ? String(msg.deviceName) : undefined,
        msg.apnsToken ? String(msg.apnsToken) : undefined,
      );
      // Compaction / closing may wait on the LLM: the app gets its welcome after at most HELLO_MAINTAIN_MS.
      await app.conversations.maintainBounded(HELLO_MAINTAIN_MS);
      const conv = app.conversations.current(); // may broadcast `conversation new` to the others
      conn.ready = true;
      conn.send({
        type: 'welcome',
        serverVersion: app.config.version,
        conversationId: conv.id,
        settings: {
          catchup: app.settings.bool('catchup.enabled'),
          activeProvider: app.providers.activeId(),
        },
      });
      conn.send(app.inbox.full());
      for (const item of app.inbox.drainPushQueue(conn.deviceId))
        conn.send({ type: 'push', item });
      return;
    }
    case 'ask': {
      const id = String(msg.id ?? '');
      const text = String(msg.text ?? '').trim();
      if (!id || !text) {
        conn.send({
          type: 'error',
          ...(id ? { id } : {}),
          message: 'ask needs id and text.',
        });
        return;
      }
      const channel: 'glasses' | 'phone' =
        msg.channel === 'glasses' ? 'glasses' : 'phone';
      const locale: 'de' | 'en' = msg.locale === 'de' ? 'de' : 'en';
      conn.channel = channel;
      conn.locale = locale;
      app.settings.noteLocale(locale);
      const now = parseIso(msg.now) ?? app.clock.now();
      const utcOffsetMin = parseOffsetMin(msg.now);
      if (utcOffsetMin !== null) app.settings.notePhoneOffset(utcOffsetMin);
      const ac = hub.registerAsk(conn.id, id);
      // First frame for this ask at once: the app treats an ask with no frame within 6 s as unreachable.
      hub.safeSend(conn, {
        type: 'status',
        id,
        text: locale === 'de' ? 'Denke nach …' : 'Thinking …',
      });
      void (async () => {
        try {
          await app.conversations.maintainBounded();
          const conv = app.conversations.current();
          hub.broadcast({
            type: 'message',
            conversationId: conv.id,
            role: 'user',
            text,
            channel,
            at: isoLocal(app.clock.now()),
          });
          const a = await app.ask({
            text,
            channel,
            locale,
            now,
            ...(utcOffsetMin !== null ? { utcOffsetMin } : {}),
            askId: id,
            connId: conn.id,
            signal: ac.signal,
            onStatus: (t) =>
              hub.safeSend(conn, { type: 'status', id, text: t }),
          });
          hub.safeSend(conn, {
            type: 'answer',
            id,
            conversationId: a.conversationId,
            text: a.text,
            followUps: a.followUps,
            actions: a.actions,
            ...(a.undo ? { undo: a.undo } : {}),
          });
          // To every socket, the asker too (clients filter by channel).
          hub.broadcast({
            type: 'message',
            conversationId: a.conversationId,
            role: 'assistant',
            text: a.text,
            channel,
            at: isoLocal(app.clock.now()),
          });
        } catch (e) {
          const cancelled = e instanceof CancelledError || ac.signal.aborted;
          hub.safeSend(conn, {
            type: 'error',
            id,
            message: cancelled
              ? 'cancelled'
              : e instanceof Error
                ? e.message
                : String(e),
          });
        } finally {
          hub.finishAsk(conn.id, id, ac);
        }
      })();
      return;
    }
    case 'cancel':
      hub.cancelAsk(conn.id, String(msg.id ?? ''));
      return;
    case 'tool_result':
      hub.toolResult(
        String(msg.callId ?? ''),
        !!msg.ok,
        String(msg.text ?? ''),
        conn.id,
      );
      return;
    case 'perform': {
      const actionId = String(msg.actionId ?? '');
      const action = app.actions.get(actionId);
      const r = await app.actions.perform(actionId);
      let text = r.text;
      // An action that really ran is reported by the model, not by the tool's own output.
      if (action && action.status === 'proposed' && action.target === 'server') {
        const channel = conn.channel ?? 'phone';
        const locale = conn.locale ?? app.settings.lastLocale();
        text = await reportAction(app, {
          title: action.title,
          ok: r.ok,
          result: r.text,
          channel,
          locale,
        });
        const conv = app.conversations.current();
        hub.broadcast({
          type: 'message',
          conversationId: conv.id,
          role: 'assistant',
          text,
          channel,
          at: isoLocal(app.clock.now()),
        });
      }
      conn.send({
        type: 'performed',
        id: String(msg.id ?? ''),
        ok: r.ok,
        text,
        result: r.text,
        ...(r.undoHandle ? { undo: r.undoHandle } : {}),
      });
      return;
    }
    case 'undo': {
      const r = await app.actions.undo(String(msg.undoId ?? ''));
      conn.send({
        type: 'performed',
        id: String(msg.id ?? ''),
        ok: r.ok,
        text: r.text,
      });
      return;
    }
    case 'inbox_event':
      if (['shown', 'opened', 'dismissed'].includes(msg.event))
        app.inbox.applyEvent(String(msg.itemId), msg.event);
      return;
    case 'inbox_sync':
      conn.send(app.inbox.full());
      return;
    case 'presence': {
      if (!(PRESENCE_EVENTS as readonly string[]).includes(msg.event)) {
        conn.send({
          type: 'error',
          message: `Unknown presence event ${String(msg.event)}`,
        });
        return;
      }
      const at = parseIso(msg.at) ?? app.clock.now();
      void app.catchup
        .onPresence(msg.event, at, msg.detail ? String(msg.detail) : undefined)
        .catch((e) => app.log.warn('presence failed', String(e)));
      return;
    }
    default:
      conn.send({
        type: 'error',
        message: `Unknown message type ${String(msg.type)}`,
      });
  }
}
