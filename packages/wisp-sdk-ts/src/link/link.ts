import { Emitter } from '../events.ts';
import {
  DEFAULT_MAX_FRAME,
  FRAME_OVERHEAD,
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
  type MessageBody,
  type MessageDef,
  type RequestOf,
  type ResponseOf,
} from '../protocol/messages.ts';
import type { Fields, Struct } from '../protocol/struct.ts';
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
  retransmits: number;
  resyncsSent: number;
  resyncsReceived: number;
  corrupt: number;
  duplicates: number;
}

export interface LinkEvents {
  /** Unsolicited messages (`EVENT` flag). */
  event: Incoming;
  /**
   * Requests from the peer. If nobody listens, requests that want a response
   * get error `unsupported op`. `PING`, `CREDIT` and `RESYNC` are handled by
   * the link itself.
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
  /** Bytes counted against the peer's window (0 for CREDIT / RESYNC). */
  weight: number;
}

interface Pending {
  resolve(m: Incoming): void;
  reject(e: Error): void;
  timer: TimerHandle;
  name: string;
}

const CONTROL_OPS = new Set([Session.credit.op, Session.resync.op]);
/** Acknowledge after this many unacknowledged control frames. */
const CONTROL_ACK_EVERY = 32;
const RESYNC_HOLDOFF_MS = 100;
/** Window full and no CREDIT for this long: probe with RESYNC (a CREDIT may be lost). */
const STALL_PROBE_MS = 250;

/**
 * One Wisp connection: frames, byte credits, resync and request/response
 * correlation over a {@link Transport}. Symmetric, so it also serves as the
 * glasses side in tests and simulators.
 *
 * Flow control as read from the spec: `CREDIT` and `RESYNC` frames carry a
 * `seq` like any frame but are never held back by the window and don't count
 * against it (otherwise two full windows could deadlock). A lost `CREDIT`
 * would stall a full window forever, so a sender that waits too long sends
 * `RESYNC`, which makes the peer resend its unacknowledged frames.
 */
export class WispLink {
  readonly events = new Emitter<LinkEvents>();
  readonly stats: LinkStats = {
    txFrames: 0,
    rxFrames: 0,
    retransmits: 0,
    resyncsSent: 0,
    resyncsReceived: 0,
    corrupt: 0,
    duplicates: 0,
  };

  readonly maxFrame: number;
  readonly rxWindow: number;
  private readonly requestTimeoutMs: number;
  private readonly creditDelayMs: number;
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
  private readonly txChunks: Uint8Array[] = [];
  private drained: (() => void)[] = [];
  lastTxAt = 0;
  lastRxAt = 0;

  private ackBytes = 0;
  private ackControl = 0;
  private creditTimer: TimerHandle | undefined;
  private resyncHold: TimerHandle | undefined;
  private stallTimer: TimerHandle | undefined;

  private nextReq = 1;
  private readonly pending = new Map<number, Pending>();
  private keepalive: TimerHandle | undefined;
  private closed: LinkClosedError | undefined;

  constructor(
    private readonly transport: Transport,
    opts: LinkOptions = {},
  ) {
    this.maxFrame = opts.maxFrame ?? DEFAULT_MAX_FRAME;
    this.rxWindow = opts.rxWindow ?? 16384;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 5000;
    this.creditDelayMs = opts.creditDelayMs ?? 20;
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

  /** Applies the peer's `max_frame` and `rx_window` (from `HELLO`). */
  setPeerLimits(limits: { maxFrame: number; rxWindow: number }) {
    this.peerMaxFrame = limits.maxFrame || DEFAULT_MAX_FRAME;
    this.peerWindow = limits.rxWindow;
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
    if (svc === Service.session && CONTROL_OPS.has(op))
      this.transmit(svc, route, body, 0);
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
      if (this.inflight > 0 && this.inflight + size > this.peerWindow) {
        this.armStallProbe();
        break;
      }
      this.queue.shift();
      this.transmit(next.svc, next.route, next.body, size);
    }
    if (!this.queue.length && !this.writing && !this.txChunks.length)
      this.resolveDrained();
  }

  private transmit(
    svc: number,
    route: number,
    body: Uint8Array,
    weight: number,
  ) {
    const seq = this.txSeq;
    this.txSeq = (this.txSeq + 1) & 0xffff;
    const frame = encodeFrame({ svc, route, seq, body });
    this.unacked.push({ seq, frame, weight });
    this.inflight += weight;
    this.stats.txFrames++;
    this.write(frame);
  }

  private write(frame: Uint8Array) {
    this.txChunks.push(frame);
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
    for (const e of r.push(chunk)) {
      if (e.kind === 'resync') this.sendResync(e.lastGoodSeq);
      else if (e.kind === 'early') {
        // CREDIT and RESYNC are cumulative, so they act even out of order;
        // otherwise two sides that both see a gap would drop each other's
        // RESYNC forever.
        const msg = decodeBody(e.frame.body);
        if (msg && isControl(e.frame.svc, msg)) this.onControl(msg);
      } else this.onFrame(e.frame);
    }
    this.stats.corrupt += r.corrupt - before;
    this.stats.duplicates = r.duplicates;
  }

  private onFrame(f: Frame) {
    this.stats.rxFrames++;
    if (this.resyncHold !== undefined) {
      clearTimer(this.resyncHold);
      this.resyncHold = undefined;
    }
    const msg = decodeBody(f.body);
    const control = msg !== undefined && isControl(f.svc, msg);
    if (control) this.ackControl++;
    else this.ackBytes += f.body.length + FRAME_OVERHEAD;
    this.scheduleCredit();
    if (!msg) return;
    if (control) return this.onControl(msg);

    const incoming: Incoming = { svc: f.svc, route: f.route, ...msg };
    if (msg.mflags & MFlags.response) return this.settle(incoming);
    if (msg.mflags & MFlags.event) return this.events.emit('event', incoming);
    if (f.svc === Service.session && msg.op === Session.ping.op)
      return this.respond(incoming, msg.payload.slice(0, 4));
    if (this.events.listenerCount('request'))
      this.events.emit('request', incoming);
    else this.respondError(incoming, ErrorCode.unsupportedOp);
  }

  private onControl(msg: MessageBody) {
    if (msg.op === Session.credit.op)
      this.onCredit(Session.credit.request!.decode(msg.payload).ackSeq);
    else this.onResync(Session.resync.request!.decode(msg.payload).lastGoodSeq);
  }

  private settle(m: Incoming) {
    const p = this.pending.get(m.req);
    if (!p) return;
    this.pending.delete(m.req);
    clearTimer(p.timer);
    if (m.mflags & MFlags.error) {
      const e = ErrorPayload.decode(m.payload);
      p.reject(new WispError(e.code, e.message));
    } else p.resolve(m);
  }

  private scheduleCredit() {
    if (
      this.ackBytes >= this.rxWindow / 4 ||
      this.ackControl >= CONTROL_ACK_EVERY
    )
      return this.sendCredit();
    if (this.ackBytes > 0 && this.creditTimer === undefined)
      this.creditTimer = setTimer(() => this.sendCredit(), this.creditDelayMs);
  }

  private sendCredit() {
    if (this.creditTimer !== undefined) clearTimer(this.creditTimer);
    this.creditTimer = undefined;
    if (this.closed) return;
    this.ackBytes = 0;
    this.ackControl = 0;
    this.notify(Session.credit, { ackSeq: this.receiver.lastGoodSeq });
  }

  private sendResync(lastGoodSeq: number) {
    if (this.closed) return;
    this.stats.resyncsSent++;
    this.notify(Session.resync, { lastGoodSeq });
    // If this RESYNC gets lost too, allow another one after a while.
    if (this.resyncHold !== undefined) clearTimer(this.resyncHold);
    this.resyncHold = setTimer(() => {
      this.resyncHold = undefined;
      this.receiver.rearmResync();
    }, RESYNC_HOLDOFF_MS);
  }

  /** Asks the peer to resend everything after the last frame we got in order. */
  private probe() {
    this.receiver.rearmResync();
    this.sendResync(this.receiver.lastGoodSeq);
  }

  private ackThrough(seq: number) {
    // Ignore acks for frames we never sent.
    if (seqDiff(seq, (this.txSeq - 1) & 0xffff) > 0) return;
    while (this.unacked.length && seqDiff(seq, this.unacked[0]!.seq) >= 0) {
      this.inflight -= this.unacked.shift()!.weight;
    }
  }

  private onCredit(ackSeq: number) {
    this.ackThrough(ackSeq);
    this.disarmStallProbe();
    this.pump();
  }

  private armStallProbe() {
    if (this.stallTimer !== undefined) return;
    this.stallTimer = setTimer(() => {
      this.stallTimer = undefined;
      if (this.closed || !this.queue.length) return;
      this.probe();
      this.armStallProbe();
    }, STALL_PROBE_MS);
  }

  private disarmStallProbe() {
    if (this.stallTimer !== undefined) clearTimer(this.stallTimer);
    this.stallTimer = undefined;
  }

  private onResync(lastGoodSeq: number) {
    this.stats.resyncsReceived++;
    this.ackThrough(lastGoodSeq);
    this.disarmStallProbe();
    for (const s of this.unacked) {
      this.stats.retransmits++;
      this.write(s.frame);
    }
    this.pump();
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
    for (const t of [this.creditTimer, this.resyncHold, this.stallTimer])
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

function isControl(svc: number, msg: MessageBody): boolean {
  return svc === Service.session && CONTROL_OPS.has(msg.op) && !msg.mflags;
}

const EMPTY: Struct = {
  fields: {},
  encode: () => new Uint8Array(0),
  decode: () => ({}),
};

function structOf(s: Struct<Fields> | undefined): Struct {
  return s ?? EMPTY;
}
