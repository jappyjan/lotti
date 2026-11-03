import type { App } from '../app.ts';
import { isoLocal } from '../util/clock.ts';
import { newId } from '../util/crypto.ts';

export interface Conn {
  id: string;
  deviceId: string;
  deviceName: string;
  /** true after `hello` */
  ready: boolean;
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
  /** Ask the phone to run a tool; 10 s timeout. The most recently connected socket is used. */
  callPhone(
    name: string,
    args: Record<string, unknown>,
    opts: { askId?: string; signal?: AbortSignal; callId?: string } = {},
  ): Promise<PhoneResult> {
    const conns = this.connections();
    const conn = conns[conns.length - 1];
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

  toolResult(callId: string, ok: boolean, text: string): void {
    this.pending.get(callId)?.resolve({ ok, text });
  }

  /** `location` phone tool wrapper: location_access start/end around the call + log. */
  async readLocation(
    source: 'agent' | 'catchup',
    askId?: string,
    signal?: AbortSignal,
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
        { ...(askId ? { askId } : {}), ...(signal ? { signal } : {}), callId },
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
  registerAsk(id: string): AbortController {
    this.asks.get(id)?.abort();
    const ac = new AbortController();
    this.asks.set(id, ac);
    return ac;
  }
  finishAsk(id: string, ac: AbortController): void {
    if (this.asks.get(id) === ac) this.asks.delete(id);
  }
  cancelAsk(id: string): boolean {
    const ac = this.asks.get(id);
    if (!ac) return false;
    const e = new Error('cancelled');
    e.name = 'CancelledError';
    ac.abort(e);
    return true;
  }
}
