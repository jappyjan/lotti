import type { App } from '../app.ts';
import { isoLocal } from '../util/clock.ts';
import { newId } from '../util/crypto.ts';

export interface Conn {
  id: string;
  deviceId: string;
  deviceName: string;
  /** true after `hello` */
  ready: boolean;
  /** Channel and language of this socket's last ask (how a confirmed action is reported back). */
  channel?: 'glasses' | 'phone';
  locale?: 'de' | 'en';
  send(msg: Record<string, unknown>): void;
  close(): void;
}

export interface PhoneResult {
  ok: boolean;
  text: string;
}

/** All live sockets, phone-tool round trips, running asks. Transport-agnostic (see ws.ts). */
export class Hub {
  private conns = new Set<Conn>();
  private pending = new Map<
    string,
    {
      resolve: (r: PhoneResult) => void;
      timer: ReturnType<typeof setTimeout>;
      connId: string;
    }
  >();
  private asks = new Map<string, AbortController>();
  constructor(private app: App) {}

  add(c: Conn): void {
    this.conns.add(c);
  }
  remove(c: Conn): void {
    this.conns.delete(c);
    for (const [id, p] of this.pending) {
      if (p.connId === c.id) {
        clearTimeout(p.timer);
        p.resolve({ ok: false, text: 'The phone disconnected.' });
        this.pending.delete(id);
      }
    }
  }
  /** Close every socket of a device (e.g. after it was revoked). */
  disconnectDevice(deviceId: string): void {
    for (const c of [...this.conns])
      if (c.deviceId === deviceId) {
        try {
          c.close();
        } catch {
          /* already gone */
        }
        this.remove(c);
      }
  }
  connections(): Conn[] {
    return [...this.conns].filter((c) => c.ready);
  }
  hasConnections(): boolean {
    return this.connections().length > 0;
  }
  connectedDeviceIds(): string[] {
    return [...new Set(this.connections().map((c) => c.deviceId))];
  }

  broadcast(msg: Record<string, unknown>, except?: Conn): void {
    for (const c of this.connections()) if (c !== except) this.safeSend(c, msg);
  }
  safeSend(c: Conn, msg: Record<string, unknown>): void {
    try {
      c.send(msg);
    } catch (e) {
      this.app.log.warn('send failed', String(e));
    }
  }

  // ---- phone tools -------------------------------------------------------
  /**
   * Ask the phone to run a tool; 10 s timeout. Goes to the socket that asked (`connId`), else (jobs,
   * catch-up, or that socket is gone) to the most recently connected one.
   */
  callPhone(
    name: string,
    args: Record<string, unknown>,
    opts: {
      askId?: string;
      signal?: AbortSignal;
      callId?: string;
      connId?: string;
    } = {},
  ): Promise<PhoneResult> {
    const conns = this.connections();
    const conn =
      (opts.connId && conns.find((c) => c.id === opts.connId)) ||
      conns[conns.length - 1];
    if (!conn)
      return Promise.resolve({
        ok: false,
        text: 'The phone is not connected.',
      });
    const callId = opts.callId ?? newId('call_');
    return new Promise<PhoneResult>((resolve) => {
      const done = (r: PhoneResult) => {
        const p = this.pending.get(callId);
        if (p) clearTimeout(p.timer);
        this.pending.delete(callId);
        opts.signal?.removeEventListener('abort', onAbort);
        resolve(r);
      };
      const onAbort = () => done({ ok: false, text: 'Cancelled.' });
      const timer = setTimeout(
        () =>
          done({
            ok: false,
            text: `The phone did not answer ${name} within ${this.app.config.phoneToolTimeoutMs / 1000} s.`,
          }),
        this.app.config.phoneToolTimeoutMs,
      );
      this.pending.set(callId, { resolve: done, timer, connId: conn.id });
      opts.signal?.addEventListener('abort', onAbort, { once: true });
      this.safeSend(conn, {
        type: 'tool_call',
        callId,
        ...(opts.askId ? { askId: opts.askId } : {}),
        name,
        args,
      });
    });
  }

  /** A phone's answer; only the socket the call went to can answer it. */
  toolResult(callId: string, ok: boolean, text: string, connId?: string): void {
    const p = this.pending.get(callId);
    if (p && (!connId || p.connId === connId)) p.resolve({ ok, text });
  }

  /** `location` phone tool wrapper: location_access start/end around the call + log. */
  async readLocation(
    source: 'agent' | 'catchup',
    askId?: string,
    signal?: AbortSignal,
    connId?: string,
  ): Promise<PhoneResult> {
    if (!this.app.settings.bool('location.enabled'))
      return {
        ok: false,
        text: 'Location access is turned off in the settings.',
      };
    const callId = newId('call_');
    this.broadcast({
      type: 'location_access',
      phase: 'start',
      callId,
      at: isoLocal(this.app.clock.now()),
    });
    let r: PhoneResult = { ok: false, text: 'failed' };
    try {
      r = await this.callPhone(
        'location',
        {},
        {
          ...(askId ? { askId } : {}),
          ...(signal ? { signal } : {}),
          ...(connId ? { connId } : {}),
          callId,
        },
      );
    } finally {
      this.broadcast({
        type: 'location_access',
        phase: 'end',
        callId,
        at: isoLocal(this.app.clock.now()),
      });
      this.app.db.run(
        'INSERT INTO location_log(at,call_id,source,ask_id,ok,detail) VALUES(?,?,?,?,?,?)',
        this.app.clock.now(),
        callId,
        source,
        askId ?? null,
        r.ok ? 1 : 0,
        r.text.slice(0, 200),
      );
    }
    return r;
  }

  // ---- asks ----------------------------------------------------------------
  // Keyed by connection + ask id: two devices may send the same id without cancelling each other.
  private askKey = (connId: string, id: string) => `${connId}\u0000${id}`;
  registerAsk(connId: string, id: string): AbortController {
    const key = this.askKey(connId, id);
    this.asks.get(key)?.abort();
    const ac = new AbortController();
    this.asks.set(key, ac);
    return ac;
  }
  finishAsk(connId: string, id: string, ac: AbortController): void {
    const key = this.askKey(connId, id);
    if (this.asks.get(key) === ac) this.asks.delete(key);
  }
  cancelAsk(connId: string, id: string): boolean {
    const ac = this.asks.get(this.askKey(connId, id));
    if (!ac) return false;
    const e = new Error('cancelled');
    e.name = 'CancelledError';
    ac.abort(e);
    return true;
  }
}
