import { Emitter } from '../events.ts';
import {
  DEFAULT_MAX_FRAME,
  FRAME_OVERHEAD,
  FrameFlag,
  encodeFrame,
  seqDiff,
  type Frame,
} from '../protocol/frame.ts';
import {
  ErrorCode,
  ErrorPayload,
  MFlags,
  Service,
  Session,
  decodeBody,
  encodeBody,
  type MessageDef,
  type RequestOf,
  type ResponseOf,
} from '../protocol/messages.ts';
import { PayloadError, type Fields, type Struct } from '../protocol/struct.ts';
import { clearTimer, setTimer, type TimerHandle } from '../timers.ts';
import { LinkClosedError, WispError, WispTimeoutError } from './errors.ts';
import { FrameReceiver } from './receiver.ts';
import type { Transport } from './transport.ts';

export interface LinkOptions {
  /** Largest frame body we accept (our `max_frame`). Default 4096. */
  maxFrame?: number;
  /** Bytes of frames we buffer before acknowledging (our `rx_window`). Default 16384. */
  rxWindow?: number;
  /** Default request timeout. Default 5000 ms. */
  requestTimeoutMs?: number;
  /** Longest a consumed frame waits for its `CREDIT`. Default 20 ms. */
  creditDelayMs?: number;
  /**
   * Unacknowledged frames and no `CREDIT` for this long: resend them all.
   * Recovers a lost last frame or a lost `CREDIT`. Default 1000 ms.
   */
  ackTimeoutMs?: number;
  /** `route` byte for frames that don't set one (see `routeByte`). Default 0. */
  route?: number;
}

/** A message received from the peer. */
export interface Incoming {
  svc: number;
  /** The frame's `route` byte; bits 2–3 are the source lens. */
  route: number;
  op: number;
  mflags: number;
  req: number;
  payload: Uint8Array;
}

export interface SendOptions {
  /** Full `route` byte; build it with `routeByte(dest, source)`. */
  route?: number;
  mflags?: number;
  req?: number;
}

export interface RequestOptions {
  route?: number;
  timeoutMs?: number;
}

export interface LinkStats {
  txFrames: number;
  rxFrames: number;
  /** Control frames (`CREDIT`, `RESYNC`) sent and received. */
  txControl: number;
  rxControl: number;
  retransmits: number;
  ackTimeouts: number;
  resyncsSent: number;
  resyncsReceived: number;
  corrupt: number;
  duplicates: number;
}

export interface LinkEvents {
  /** Unsolicited messages (`EVENT` flag). */
  event: Incoming;
  /**
   * Requests from the peer. A listener must answer every request with
   * `req ≠ 0` exactly once (`respond`, `respondError`); `req = 0` gets no
   * answer. If nobody listens, requests that want a response get error
   * `unsupported op`. `PING`, `CREDIT` and `RESYNC` are handled by the link.
   */
  request: Incoming;
  close: Error | undefined;
}

interface Outgoing {
  svc: number;
  route: number;
  body: Uint8Array;
}

interface Sent {
  seq: number;
  frame: Uint8Array;
}

interface Pending {
  resolve(m: Incoming): void;
  reject(e: Error): void;
  timer: TimerHandle;
  name: string;
}

const CONTROL_OPS = new Set([Session.credit.op, Session.resync.op]);
const DEFAULT_RX_WINDOW = 16384;

/**
 * One Wisp connection: frames, byte credits, resync and request/response
 * correlation over a {@link Transport}. Symmetric, so it also serves as the
 * glasses side in tests and simulators.
 *
 * Flow control (protocol 0.2): `CREDIT` and `RESYNC` travel in control
 * frames (`fflags.CTRL`, seq 0), outside the window and never acknowledged
 * or retransmitted; both are cumulative, so a lost one is repaired by the
 * next. Every duplicate we receive is answered with a `CREDIT`, and frames
 * unacknowledged for `ackTimeoutMs` are resent, so a lost `CREDIT` (even
 * with a full window), `RESYNC` or last frame never stalls the link.
 */
export class WispLink {
  readonly events = new Emitter<LinkEvents>();
  readonly stats: LinkStats = {
    txFrames: 0,
    rxFrames: 0,
    txControl: 0,
    rxControl: 0,
    retransmits: 0,
    ackTimeouts: 0,
    resyncsSent: 0,
    resyncsReceived: 0,
    corrupt: 0,
    duplicates: 0,
  };

  readonly maxFrame: number;
  readonly rxWindow: number;
  private readonly requestTimeoutMs: number;
  private readonly creditDelayMs: number;
  private readonly ackTimeoutMs: number;
  private readonly route: number;

  private peerMaxFrame = DEFAULT_MAX_FRAME;
  /** Until `HELLO` tells us, assume room for one default frame. */
  private peerWindow = DEFAULT_MAX_FRAME + FRAME_OVERHEAD;

  private readonly receiver: FrameReceiver;
  private txSeq = 0;
  private readonly queue: Outgoing[] = [];
  private readonly unacked: Sent[] = [];
  private inflight = 0;

  private writing = false;
  /** Frames waiting for the transport; the head may be partly written. */
  private readonly txChunks: Uint8Array[] = [];
  private headPartial = false;
  private readonly controlFrames = new WeakSet<Uint8Array>();
  private drained: (() => void)[] = [];
  lastTxAt = 0;
  lastRxAt = 0;

  private ackBytes = 0;
  private creditTimer: TimerHandle | undefined;
  private ackTimer: TimerHandle | undefined;

  private nextReq = 1;
  private readonly pending = new Map<number, Pending>();
  private keepalive: TimerHandle | undefined;
  private closed: LinkClosedError | undefined;

  constructor(
    private readonly transport: Transport,
    opts: LinkOptions = {},
  ) {
    this.maxFrame = opts.maxFrame ?? DEFAULT_MAX_FRAME;
    this.rxWindow = opts.rxWindow ?? DEFAULT_RX_WINDOW;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 5000;
    this.creditDelayMs = opts.creditDelayMs ?? 20;
    this.ackTimeoutMs = opts.ackTimeoutMs ?? 1000;
    this.route = opts.route ?? 0;
    this.receiver = new FrameReceiver(this.maxFrame);
    transport.attach({
      onData: (chunk) => this.receive(chunk),
      onClose: (err) => this.shutdown(err),
    });
  }

  get isClosed(): boolean {
    return this.closed !== undefined;
  }

  /** Applies the peer's `max_frame` and `rx_window` (from `HELLO`; 0 = defaults). */
  setPeerLimits(limits: { maxFrame: number; rxWindow: number }) {
    this.peerMaxFrame = limits.maxFrame || DEFAULT_MAX_FRAME;
    this.peerWindow = limits.rxWindow || DEFAULT_RX_WINDOW;
    this.pump();
  }

  /** Largest payload that fits one frame to the peer. */
  get maxPayload(): number {
    return this.peerMaxFrame - 4;
  }

  /** Bytes sent and not yet acknowledged, plus bytes waiting for credit. */
  get backlog(): number {
    return (
      this.inflight +
      this.queue.reduce((a, o) => a + o.body.length + FRAME_OVERHEAD, 0)
    );
  }

  // ── sending ────────────────────────────────────────────────────────────

  /** Queues one message. Fire and forget: use `request` to get a response. */
  send(svc: number, op: number, payload: Uint8Array, opts: SendOptions = {}) {
    if (this.closed) throw this.closed;
    const body = encodeBody(
      { op, mflags: opts.mflags ?? 0, req: opts.req ?? 0 },
      payload,
    );
    if (body.length > this.peerMaxFrame)
      throw new RangeError(
        `message of ${body.length} bytes exceeds max_frame ${this.peerMaxFrame}`,
      );
    const route = opts.route ?? this.route;
    if (svc === Service.session && CONTROL_OPS.has(op) && !body[1])
      this.transmitControl(route, body);
    else {
      this.queue.push({ svc, route, body });
      this.pump();
    }
  }

  /** Sends a request and resolves with the response (rejects on `ERROR`). */
  request(
    svc: number,
    op: number,
    payload: Uint8Array,
    opts: RequestOptions = {},
  ): Promise<Incoming> {
    if (this.closed) return Promise.reject(this.closed);
    const req = this.allocReq();
    const name = `${svc}/${op}`;
    return new Promise<Incoming>((resolve, reject) => {
      const timeoutMs = opts.timeoutMs ?? this.requestTimeoutMs;
      const timer = setTimer(() => {
        this.pending.delete(req);
        reject(new WispTimeoutError(`${name} timed out after ${timeoutMs} ms`));
      }, timeoutMs);
      this.pending.set(req, { resolve, reject, timer, name });
      try {
        this.send(svc, op, payload, { req, route: opts.route });
      } catch (err) {
        clearTimer(timer);
        this.pending.delete(req);
        reject(err as Error);
      }
    });
  }

  /** Typed request: encodes `fields`, decodes the response. */
  async call<M extends MessageDef>(
    def: M,
    fields: Partial<RequestOf<M>> = {},
    opts: RequestOptions = {},
  ): Promise<ResponseOf<M>> {
    try {
      const res = await this.request(
        def.svc,
        def.op,
        structOf(def.request).encode(fields),
        opts,
      );
      return (def.response ?? EMPTY).decode(res.payload) as ResponseOf<M>;
    } catch (err) {
      if (err instanceof WispError && !err.op)
        throw new WispError(err.code, err.detail, def.name);
      if (err instanceof PayloadError)
        throw new WispError(ErrorCode.badPayload, err.message, def.name);
      throw err;
    }
  }

  /** Typed fire-and-forget (`req = 0`). */
  notify<M extends MessageDef>(
    def: M,
    fields: Partial<RequestOf<M>> = {},
    opts: SendOptions = {},
  ) {
    this.send(def.svc, def.op, structOf(def.request).encode(fields), opts);
  }

  /** Answers a request from the peer (no-op if it wanted no response). */
  respond(to: Incoming, payload: Uint8Array = new Uint8Array(0)) {
    if (!to.req) return;
    this.send(to.svc, to.op, payload, { req: to.req, mflags: MFlags.response });
  }

  respondError(to: Incoming, code: number, message = '') {
    if (!to.req) return;
    this.send(to.svc, to.op, ErrorPayload.encode({ code, message }), {
      req: to.req,
      mflags: MFlags.response | MFlags.error,
    });
  }

  /** Sends an unsolicited event. */
  emitEvent(svc: number, op: number, payload: Uint8Array, route?: number) {
    this.send(svc, op, payload, { mflags: MFlags.event, route });
  }

  /** Resolves once everything queued so far has been handed to the transport. */
  flush(): Promise<void> {
    if (!this.queue.length && !this.writing && !this.txChunks.length)
      return Promise.resolve();
    return new Promise((resolve) => this.drained.push(resolve));
  }

  private allocReq(): number {
    for (let i = 0; i < 0xffff; i++) {
      const req = this.nextReq;
      this.nextReq = (this.nextReq % 0xffff) + 1;
      if (!this.pending.has(req)) return req;
    }
    throw new Error('too many requests in flight');
  }

  private pump() {
    while (this.queue.length && !this.closed) {
      const next = this.queue[0]!;
      const size = next.body.length + FRAME_OVERHEAD;
      if (this.inflight > 0 && this.inflight + size > this.peerWindow) break;
      this.queue.shift();
      this.transmit(next.svc, next.route, next.body);
    }
    if (!this.queue.length && !this.writing && !this.txChunks.length)
      this.resolveDrained();
  }

  private transmit(svc: number, route: number, body: Uint8Array) {
    const seq = this.txSeq;
    this.txSeq = (this.txSeq + 1) & 0xffff;
    const frame = encodeFrame({ svc, route, seq, body });
    this.unacked.push({ seq, frame });
    this.inflight += frame.length;
    this.stats.txFrames++;
    this.write(frame);
    this.armAckTimer();
  }

  /** A control frame: seq 0, outside the window, ahead of queued data. */
  private transmitControl(route: number, body: Uint8Array) {
    this.stats.txControl++;
    const frame = encodeFrame({
      svc: Service.session,
      route,
      fflags: FrameFlag.ctrl,
      seq: 0,
      body,
    });
    this.controlFrames.add(frame);
    this.write(frame, true);
  }

  private write(frame: Uint8Array, urgent = false) {
    // The head chunk may be half written; anything behind it starts at a frame boundary.
    if (urgent && this.txChunks.length) this.txChunks.splice(1, 0, frame);
    else this.txChunks.push(frame);
    if (!this.writing) void this.writeLoop();
  }

  private async writeLoop() {
    this.writing = true;
    const mtu = Math.max(1, this.transport.mtu);
    try {
      while (this.txChunks.length && !this.closed) {
        // Pack frames back to back into writes of up to `mtu` bytes.
        const out = new Uint8Array(
          Math.min(
            mtu,
            this.txChunks.reduce((a, c) => a + c.length, 0),
          ),
        );
        let o = 0;
        while (o < out.length) {
          const c = this.txChunks[0]!;
          const n = Math.min(c.length, out.length - o);
          out.set(c.subarray(0, n), o);
          o += n;
          this.headPartial = n < c.length;
          if (n === c.length) this.txChunks.shift();
          else this.txChunks[0] = c.subarray(n);
        }
        this.lastTxAt = Date.now();
        await this.transport.write(out);
      }
    } catch (err) {
      this.shutdown(err as Error);
    } finally {
      this.writing = false;
    }
    if (!this.queue.length) this.resolveDrained();
  }

  private resolveDrained() {
    const d = this.drained;
    this.drained = [];
    for (const fn of d) fn();
  }

  // ── receiving ──────────────────────────────────────────────────────────

  private receive(chunk: Uint8Array) {
    if (this.closed) return;
    this.lastRxAt = Date.now();
    const r = this.receiver;
    const before = r.corrupt;
    let duplicate = false;
    for (const e of r.push(chunk)) {
      if (e.kind === 'frame') this.onFrame(e.frame);
      else if (e.kind === 'control') this.onControl(e.frame);
      else if (e.kind === 'duplicate') duplicate = true;
      else if (e.kind === 'resync') this.sendResync(e.lastGoodSeq);
      // 'early' frames are dropped: our RESYNC or the peer's ack timeout brings them back.
      if (this.closed) return;
    }
    // Every duplicate gets a CREDIT; one covers all of them in this chunk.
    if (duplicate) this.sendCredit();
    this.stats.corrupt += r.corrupt - before;
    this.stats.duplicates = r.duplicates;
  }

  private onFrame(f: Frame) {
    this.stats.rxFrames++;
    this.ackBytes += f.body.length + FRAME_OVERHEAD;
    this.scheduleCredit();
    const msg = decodeBody(f.body);
    if (!msg) return;

    const incoming: Incoming = { svc: f.svc, route: f.route, ...msg };
    if (msg.mflags & MFlags.response) return this.settle(incoming);
    if (msg.mflags & MFlags.event) return this.events.emit('event', incoming);
    if (f.svc === Service.session && msg.op === Session.ping.op) {
      try {
        const { token } = Session.ping.request!.decode(msg.payload);
        return this.respond(incoming, Session.ping.response!.encode({ token }));
      } catch (err) {
        if (!(err instanceof PayloadError)) throw err;
        return this.respondError(incoming, ErrorCode.badPayload, err.message);
      }
    }
    if (this.events.listenerCount('request'))
      this.events.emit('request', incoming);
    else this.respondError(incoming, ErrorCode.unsupportedOp);
  }

  private onControl(f: Frame) {
    this.stats.rxControl++;
    const msg = decodeBody(f.body);
    // Only CREDIT and RESYNC requests exist as control frames; ignore anything else.
    if (
      !msg ||
      f.svc !== Service.session ||
      msg.mflags ||
      msg.payload.length < 2
    )
      return;
    const seq = msg.payload[0]! | (msg.payload[1]! << 8);
    if (msg.op === Session.credit.op) this.onCredit(seq);
    else if (msg.op === Session.resync.op) this.onResync(seq);
  }

  private settle(m: Incoming) {
    const p = this.pending.get(m.req);
    if (!p) return;
    this.pending.delete(m.req);
    clearTimer(p.timer);
    if (m.mflags & MFlags.error) {
      let e = {
        code: ErrorCode.badPayload as number,
        message: 'malformed ERROR',
      };
      try {
        e = ErrorPayload.decode(m.payload);
      } catch (err) {
        if (!(err instanceof PayloadError)) throw err;
      }
      p.reject(new WispError(e.code, e.message));
    } else p.resolve(m);
  }

  private scheduleCredit() {
    if (this.ackBytes >= this.rxWindow / 4) return this.sendCredit();
    if (this.ackBytes > 0 && this.creditTimer === undefined)
      this.creditTimer = setTimer(() => this.sendCredit(), this.creditDelayMs);
  }

  private sendCredit() {
    if (this.creditTimer !== undefined) clearTimer(this.creditTimer);
    this.creditTimer = undefined;
    if (this.closed) return;
    this.ackBytes = 0;
    this.notify(Session.credit, { ackSeq: this.receiver.lastGoodSeq });
  }

  private sendResync(lastGoodSeq: number) {
    if (this.closed) return;
    this.stats.resyncsSent++;
    this.notify(Session.resync, { lastGoodSeq });
  }

  /** Frees every frame up to `seq`; true when that freed any. */
  private ackThrough(seq: number): boolean {
    // Ignore acks for frames we never sent.
    if (seqDiff(seq, (this.txSeq - 1) & 0xffff) > 0) return false;
    const before = this.unacked.length;
    while (this.unacked.length && seqDiff(seq, this.unacked[0]!.seq) >= 0)
      this.inflight -= this.unacked.shift()!.frame.length;
    return this.unacked.length < before;
  }

  private onCredit(ackSeq: number) {
    if (this.ackThrough(ackSeq)) this.armAckTimer(true);
    this.pump();
  }

  private onResync(lastGoodSeq: number) {
    this.stats.resyncsReceived++;
    this.ackThrough(lastGoodSeq);
    this.retransmitAll();
    this.armAckTimer(true);
    this.pump();
  }

  private retransmitAll() {
    // Data frames still waiting to be written would go out twice (and pile
    // up under heavy loss): drop them, keeping control frames and a
    // half-written head. Every data frame not yet acked is in `unacked`.
    const keep = this.txChunks.filter(
      (c, i) => (i === 0 && this.headPartial) || this.controlFrames.has(c),
    );
    this.txChunks.splice(0, this.txChunks.length, ...keep);
    for (const s of this.unacked) {
      this.stats.retransmits++;
      this.write(s.frame);
    }
  }

  /** Starts the ack timeout if frames wait for a CREDIT (`restart`: count from now). */
  private armAckTimer(restart = false) {
    if (restart && this.ackTimer !== undefined) {
      clearTimer(this.ackTimer);
      this.ackTimer = undefined;
    }
    if (this.ackTimer !== undefined || !this.unacked.length || this.closed)
      return;
    this.ackTimer = setTimer(() => {
      this.ackTimer = undefined;
      if (this.closed || !this.unacked.length) return;
      // Still writing them out: the peer can't have acknowledged them yet.
      if (!this.txChunks.length) {
        this.stats.ackTimeouts++;
        this.retransmitAll();
      }
      this.armAckTimer();
    }, this.ackTimeoutMs);
  }

  // ── session upkeep ─────────────────────────────────────────────────────

  /**
   * Sends `PING` whenever nothing was sent for `intervalMs`; pick it well
   * below the glasses' `session_timeout_ms`.
   */
  startKeepalive(intervalMs: number, onError?: (err: Error) => void) {
    this.stopKeepalive();
    let token = 0;
    const tick = () => {
      if (this.closed) return;
      if (Date.now() - this.lastTxAt >= intervalMs * 0.9) {
        token = (token + 1) >>> 0;
        this.call(Session.ping, { token }, { timeoutMs: intervalMs }).catch(
          (err: Error) => onError?.(err),
        );
      }
      this.keepalive = setTimer(tick, intervalMs);
    };
    this.keepalive = setTimer(tick, intervalMs);
  }

  stopKeepalive() {
    if (this.keepalive !== undefined) clearTimer(this.keepalive);
    this.keepalive = undefined;
  }

  /** Closes the transport and fails everything pending. */
  async close() {
    if (this.closed) return;
    this.shutdown();
    await this.transport.close();
  }

  private shutdown(reason?: Error) {
    if (this.closed) return;
    this.closed = new LinkClosedError(reason);
    this.stopKeepalive();
    for (const t of [this.creditTimer, this.ackTimer])
      if (t !== undefined) clearTimer(t);
    for (const p of this.pending.values()) {
      clearTimer(p.timer);
      p.reject(this.closed);
    }
    this.pending.clear();
    this.queue.length = 0;
    this.resolveDrained();
    this.events.emit('close', reason);
  }
}

const EMPTY: Struct = {
  fields: {},
  encode: () => new Uint8Array(0),
  decode: () => ({}),
};

function structOf(s: Struct<Fields> | undefined): Struct {
  return s ?? EMPTY;
}
