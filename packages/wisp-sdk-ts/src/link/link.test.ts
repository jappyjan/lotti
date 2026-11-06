import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FakeGlasses } from '../testing/fake-glasses.ts';
import { rng } from '../testing/random.ts';
import { createLoopbackPair } from '../transports/loopback.ts';
import {
  FrameDecoder,
  FrameFlag,
  FRAME_OVERHEAD,
  encodeFrame,
  seqDiff,
} from '../protocol/frame.ts';
import {
  Display,
  ErrorCode,
  MFlags,
  Service,
  Session,
  System,
  decodeBody,
  encodeBody,
} from '../protocol/messages.ts';
import type { Transport, TransportReceiver } from './transport.ts';
import { ClockEstimator } from './clock.ts';
import { WispError, WispTimeoutError, LinkClosedError } from './errors.ts';
import { WispLink } from './link.ts';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until(cond: () => boolean, ms = 2000) {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error('condition not met in time');
    await sleep(2);
  }
}

test('request/response, events and error responses over a loopback', async () => {
  const [a, b] = createLoopbackPair();
  const phone = new WispLink(a);
  const glasses = new FakeGlasses(b);
  glasses.override = (m) => {
    if (m.svc === Service.system && m.op === 99) {
      glasses.link.respondError(m, ErrorCode.busy, 'later');
      return true;
    }
    return false;
  };

  const pong = await phone.call(Session.ping, { token: 0xdeadbeef });
  assert.equal(pong.token, 0xdeadbeef);

  await assert.rejects(
    phone.request(Service.system, 99, new Uint8Array(0)),
    (e: WispError) => {
      assert.ok(e instanceof WispError);
      assert.equal(e.code, ErrorCode.busy);
      assert.equal(e.detail, 'later');
      return true;
    },
  );

  const events: number[] = [];
  phone.events.on('event', (m) => events.push(m.op));
  glasses.link.emitEvent(Service.input, 3, Uint8Array.from([1, 1, 0, 0, 0, 0]));
  await until(() => events.length === 1);
  assert.deepEqual(events, [3]);

  await phone.close();
  assert.equal(glasses.link.isClosed, true);
});

test('timeouts and close reject pending requests', async () => {
  const [a, b] = createLoopbackPair();
  const phone = new WispLink(a, { requestTimeoutMs: 30 });
  const glasses = new FakeGlasses(b);
  glasses.override = () => true; // never answer
  await assert.rejects(phone.call(System.info), WispTimeoutError);
  const pending = phone.call(System.info, {}, { timeoutMs: 10_000 });
  await phone.close();
  await assert.rejects(pending, LinkClosedError);
  assert.throws(() => phone.notify(Display.clearAll), LinkClosedError);
});

/** Watches the phone → glasses byte stream and tracks bytes in flight. */
function windowWatcher() {
  const toGlasses = new FrameDecoder();
  const toPhone = new FrameDecoder();
  const sent = new Map<number, number>();
  let maxInFlight = 0;
  const inFlight = () => [...sent.values()].reduce((x, y) => x + y, 0);
  return {
    get maxInFlight() {
      return maxInFlight;
    },
    tap(chunk: Uint8Array, from: 'a' | 'b') {
      if (from === 'a') {
        for (const f of toGlasses.push(chunk)) {
          if (!(f.fflags & FrameFlag.ctrl) && !sent.has(f.seq))
            sent.set(f.seq, f.body.length + FRAME_OVERHEAD);
          maxInFlight = Math.max(maxInFlight, inFlight());
        }
      } else {
        for (const f of toPhone.push(chunk)) {
          const m = decodeBody(f.body)!;
          if (f.fflags & FrameFlag.ctrl) {
            const ack = m.payload[0]! | (m.payload[1]! << 8);
            for (const seq of [...sent.keys()])
              if (seqDiff(ack, seq) >= 0) sent.delete(seq);
          }
        }
      }
      return chunk;
    },
  };
}

test('byte credits: never more than the peer window in flight, nothing lost', async () => {
  const watch = windowWatcher();
  const [a, b] = createLoopbackPair({
    tamper: (c, from) => watch.tap(c, from),
  });
  const phone = new WispLink(a);
  const glasses = new FakeGlasses(b, { rxWindow: 1000 });
  await phone.call(Session.hello, { maxFrame: 4096, rxWindow: 16384 });
  phone.setPeerLimits({ maxFrame: 4096, rxWindow: 1000 });

  for (let i = 0; i < 300; i++)
    phone.notify(Display.fill, { layer: 1, value: i & 15, x: i });
  await phone.call(Session.ping, { token: 7 });
  const fills = glasses.named('FILL');
  assert.equal(fills.length, 300);
  assert.deepEqual(
    fills.map((f) => f.fields.x),
    Array.from({ length: 300 }, (_, i) => i),
  );
  assert.ok(watch.maxInFlight <= 1000, `in flight ${watch.maxInFlight}`);
  assert.ok(watch.maxInFlight > 500, 'the window was actually used');
  await phone.close();
});

test('before HELLO is answered the peer window is one default frame (4106 bytes)', async () => {
  const watch = windowWatcher();
  const [a, b] = createLoopbackPair({
    tamper: (c, from) => watch.tap(c, from),
  });
  const phone = new WispLink(a);
  const glasses = new FakeGlasses(b);
  glasses.override = () => true; // the glasses answer nothing, so no HELLO response either
  for (let i = 0; i < 20; i++)
    phone.notify(Display.image, { layer: 1, data: new Uint8Array(1000) });
  await until(() => glasses.named('IMAGE').length === 20);
  // 4 x 1014 bytes fit in 4106, a fifth doesn't (the glasses' CREDITs make room)
  assert.ok(watch.maxInFlight <= 4106, `in flight ${watch.maxInFlight}`);
  assert.ok(watch.maxInFlight >= 4 * 1014, `in flight ${watch.maxInFlight}`);
  await phone.close();
});

/**
 * Fault injection both ways: lost writes and flipped bits, so CREDIT and
 * RESYNC control frames get lost and damaged too. Recovery relies only on
 * the protocol: RESYNC, a CREDIT for every duplicate and the ack timeout,
 * which also brings back a lost last frame (no keepalive traffic here).
 */
for (const [seed, both, loss, controlLoss] of [
  [9, false, 0.08, 0],
  [10, true, 0.08, 0],
  [21, true, 0.15, 0],
  [22, true, 0.05, 0.5],
  [23, true, 0.02, 0.9],
] as const)
  test(`lossy link (seed ${seed}): ${both ? 'both ways' : 'phone → glasses'}, ${loss * 100} % damaged, ${controlLoss * 100} % of control frames lost: in order, exactly once`, async () => {
    const r = rng(seed);
    let damaged = 0;
    let controlsLost = 0;
    const [a, b] = createLoopbackPair({
      mtu: 60,
      tamper: (chunk, from) => {
        if (controlLoss && r.next() < controlLoss && hasControlFrame(chunk)) {
          controlsLost++;
          return undefined;
        }
        if ((from !== 'a' && !both) || r.next() > loss) return chunk;
        damaged++;
        if (r.next() < 0.5) return undefined; // lost write
        const c = chunk.slice();
        c[r.int(0, c.length - 1)] ^= 0x20;
        return c;
      },
    });
    const opts = { requestTimeoutMs: 20_000, ackTimeoutMs: 30 };
    const phone = new WispLink(a, opts);
    const glasses = new FakeGlasses(b, opts);
    phone.setPeerLimits({ maxFrame: 4096, rxWindow: 2000 });
    glasses.link.setPeerLimits({ maxFrame: 4096, rxWindow: 16384 });

    const N = 400;
    for (let i = 0; i < N; i++) {
      phone.notify(Display.fill, { layer: 2, x: i, w: r.int(0, 999) });
      if (both && i % 50 === 0)
        glasses.link.emitEvent(
          Service.input,
          3,
          Uint8Array.of(1, 1, 0, 0, 0, i / 50),
        );
    }
    await phone.call(Session.ping, { token: 1 });
    // The last FILLs need no answer; the ack timeout makes sure they arrive.
    await until(() => glasses.named('FILL').length >= N, 15_000);
    const xs = glasses.named('FILL').map((f) => f.fields.x);
    assert.deepEqual(
      xs,
      Array.from({ length: N }, (_, i) => i),
    );
    assert.ok(damaged + controlsLost > 5, `damaged ${damaged}`);
    if (controlLoss)
      assert.ok(controlsLost > 3, `control frames lost ${controlsLost}`);
    assert.ok(phone.stats.retransmits > 0);
    await phone.close();
  });

function hasControlFrame(chunk: Uint8Array) {
  for (let i = 0; i + 4 <= chunk.length; i++)
    if (
      chunk[i] === 0x57 &&
      chunk[i + 1] === 0 &&
      chunk[i + 3] === FrameFlag.ctrl
    )
      return true;
  return false;
}

test('a lost CREDIT with a full window: the ack timeout resends, the duplicates bring a fresh CREDIT', async () => {
  let phone: WispLink | undefined;
  let dropped = 0;
  const [a, b] = createLoopbackPair({
    tamper: (chunk, from) => {
      // Every CREDIT from the glasses is lost until the phone's ack timeout fires.
      if (from === 'b' && !phone?.stats.ackTimeouts && hasControlFrame(chunk)) {
        dropped++;
        return undefined;
      }
      return chunk;
    },
  });
  phone = new WispLink(a, { ackTimeoutMs: 40 });
  const glasses = new FakeGlasses(b, { creditDelayMs: 1 });
  phone.setPeerLimits({ maxFrame: 4096, rxWindow: 300 });
  for (let i = 0; i < 30; i++) phone.notify(Display.fill, { layer: 1, x: i });
  await until(() => glasses.named('FILL').length === 12); // 12 x 24 bytes: the window is full
  await sleep(20);
  assert.equal(glasses.named('FILL').length, 12, 'stalled');
  // Only the duplicates' CREDIT can unblock it: the glasses consumed everything already.
  await until(() => glasses.named('FILL').length === 30, 3000);
  await until(() => phone.backlog === 0, 3000);
  assert.ok(dropped >= 1);
  assert.equal(phone.stats.ackTimeouts, 1);
  assert.ok(glasses.link.stats.duplicates >= 12);
  await phone.close();
});

test('every request with req ≠ 0 gets exactly one response; req = 0 gets none', async () => {
  const responses = new Map<number, number>();
  const toPhone = new FrameDecoder();
  const [a, b] = createLoopbackPair({
    tamper: (chunk, from) => {
      if (from === 'b')
        for (const f of toPhone.push(chunk)) {
          const m = decodeBody(f.body)!;
          if (m.mflags & MFlags.response)
            responses.set(m.req, (responses.get(m.req) ?? 0) + 1);
        }
      return chunk;
    },
  });
  const phone = new WispLink(a);
  const glasses = new FakeGlasses(b);
  const reqs: Promise<unknown>[] = [
    phone.request(Service.resource, 2, Uint8Array.of(1, 0, 0, 0, 0, 0, 9)), // PUT_DATA
    phone.request(Service.input, 1, Uint8Array.of(2)), // CONFIG
    phone.request(Service.session, 6, new Uint8Array(0)), // BYE
    phone.request(Service.display, 99, new Uint8Array(0)), // unknown op: error 1
    phone.request(Service.session, 4, Uint8Array.of(1, 2)), // PING cut in half: error 2
  ];
  const results = await Promise.allSettled(reqs);
  phone.send(Service.input, 1, Uint8Array.of(2)); // req 0
  phone.send(Service.display, 99, new Uint8Array(0)); // req 0, unknown op: still silent
  await phone.call(Session.ping, { token: 5 });
  await sleep(20);
  assert.deepEqual([...responses.values()], [1, 1, 1, 1, 1, 1]);
  assert.deepEqual(
    results.map((r) =>
      r.status === 'fulfilled' ? 0 : (r.reason as WispError).code,
    ),
    [0, 0, 0, ErrorCode.unsupportedOp, ErrorCode.badPayload],
  );
  assert.equal(responses.has(0), false);
  assert.equal(glasses.received.length, 6); // the link answers both PINGs itself
  await phone.close();
});

/** A transport the test drives by hand. */
function manualTransport() {
  const written: Uint8Array[] = [];
  let rx: TransportReceiver | undefined;
  const t: Transport = {
    mtu: 1000,
    attach: (r) => (rx = r),
    write: async (c) => void written.push(c.slice()),
    close: async () => rx?.onClose(),
  };
  return { t, written, deliver: (b: Uint8Array) => rx!.onData(b) };
}

test('a duplicate is answered with CREDIT; a gap triggers RESYNC with the last good seq; both are control frames', async () => {
  const m = manualTransport();
  const link = new WispLink(m.t);
  const got: number[] = [];
  link.events.on('event', (e) => got.push(e.payload[0]!));
  const ev = (seq: number, v: number) =>
    encodeFrame({
      svc: 4,
      route: 0,
      seq,
      body: encodeBody(
        { op: 3, mflags: MFlags.event, req: 0 },
        Uint8Array.from([v]),
      ),
    });
  m.deliver(ev(0, 10));
  m.deliver(ev(0, 11)); // duplicate
  m.deliver(ev(1, 12));
  m.deliver(ev(3, 13)); // gap: 2 missing
  assert.deepEqual(got, [10, 12]);
  assert.equal(link.stats.duplicates, 1);
  await link.flush();
  const out = new FrameDecoder().push(
    m.written.reduce((x, y) => new Uint8Array([...x, ...y]), new Uint8Array(0)),
  );
  assert.ok(out.every((f) => f.fflags === FrameFlag.ctrl && f.seq === 0));
  const sent = out.map((f) => decodeBody(f.body)!);
  assert.deepEqual(
    sent.map((b) => [b.op, b.payload[0]]),
    [
      [Session.credit.op, 0], // for the duplicate
      [Session.resync.op, 1],
    ],
  );
  m.deliver(ev(2, 14));
  m.deliver(ev(3, 15));
  assert.deepEqual(got, [10, 12, 14, 15]);
  await link.close();
});

test('control frames act in any state: CREDIT and RESYNC while we wait out a gap', async () => {
  const m = manualTransport();
  const link = new WispLink(m.t, { ackTimeoutMs: 10_000 });
  link.setPeerLimits({ maxFrame: 4096, rxWindow: 16384 });
  for (let i = 0; i < 4; i++) link.notify(Display.fill, { x: i });
  await link.flush();
  const ev = (seq: number) =>
    encodeFrame({
      svc: 4,
      route: 0,
      seq,
      body: encodeBody(
        { op: 3, mflags: MFlags.event, req: 0 },
        new Uint8Array(6),
      ),
    });
  const ctrl = (op: number, seq: number) =>
    encodeFrame({
      svc: 0,
      route: 0,
      fflags: FrameFlag.ctrl,
      seq: 0x7777, // ignored
      body: encodeBody(
        { op, mflags: 0, req: 0 },
        Uint8Array.of(seq & 255, seq >> 8),
      ),
    });
  m.deliver(ev(0));
  m.deliver(ev(2)); // gap: we send RESYNC and drop until seq 1 arrives
  m.deliver(ctrl(Session.credit.op, 1));
  assert.equal(link.backlog, 2 * 24); // FILL frames are 24 bytes
  const before = m.written.length;
  m.deliver(ctrl(Session.resync.op, 2)); // acks seq 2, resends seq 3
  assert.equal(link.backlog, 24);
  await link.flush();
  const resent = new FrameDecoder().push(
    m.written
      .slice(before)
      .reduce((x, y) => new Uint8Array([...x, ...y]), new Uint8Array(0)),
  );
  assert.deepEqual(
    resent.map((f) => f.seq),
    [3],
  );
  assert.equal(link.stats.rxControl, 2);
  await link.close();
});

test('CREDIT coalesces: one ack per quarter window or 20 ms', async () => {
  const m = manualTransport();
  const link = new WispLink(m.t, { rxWindow: 400 });
  const ev = (seq: number) =>
    encodeFrame({
      svc: 4,
      route: 0,
      seq,
      body: encodeBody(
        { op: 3, mflags: MFlags.event, req: 0 },
        new Uint8Array(16),
      ),
    });
  for (let s = 0; s < 6; s++) m.deliver(ev(s)); // 30 bytes each → 4 frames reach 100
  await link.flush();
  const credits = () =>
    new FrameDecoder()
      .push(
        m.written.reduce(
          (x, y) => new Uint8Array([...x, ...y]),
          new Uint8Array(0),
        ),
      )
      .map((f) => decodeBody(f.body)!)
      .filter((b) => b.op === Session.credit.op)
      .map((b) => Session.credit.request!.decode(b.payload).ackSeq);
  assert.deepEqual(credits(), [3]);
  await sleep(40);
  assert.deepEqual(credits(), [3, 5]);
  await link.close();
});

test('keepalive pings an idle link below the session timeout', async () => {
  const [a, b] = createLoopbackPair();
  const phone = new WispLink(a);
  const glasses = new FakeGlasses(b);
  let pings = 0;
  glasses.link.events.on('request', () => {});
  const orig = glasses.link.respond.bind(glasses.link);
  glasses.link.respond = (to, p) => {
    if (to.svc === 0 && to.op === Session.ping.op) pings++;
    orig(to, p);
  };
  phone.startKeepalive(30);
  await sleep(140);
  assert.ok(pings >= 2, `pings ${pings}`);
  await phone.close();
});

test('clock estimator recovers offset and drift', () => {
  const c = new ClockEstimator();
  const rate = 1.015; // glasses run 1.5 % fast
  const r = rng(11);
  for (let i = 0; i < 20; i++) {
    const sent = 1_700_000_000_000 + i * 500;
    const rtt = 8 + r.int(0, i % 4 === 0 ? 80 : 4);
    const mid = sent + rtt / 2;
    c.addSample(
      sent,
      sent + rtt,
      42_000_000 + (mid - 1_700_000_000_000) * 1000 * rate,
    );
  }
  assert.ok(Math.abs(c.driftPpm - 15000) < 300, `drift ${c.driftPpm}`);
  const t = 1_700_000_005_000;
  const expected = 42_000_000 + 5_000_000 * rate;
  assert.ok(Math.abs(c.toGlassUs(t) - expected) < 3000);
  assert.ok(Math.abs(c.toPhoneMs(expected) - t) < 3);
});
