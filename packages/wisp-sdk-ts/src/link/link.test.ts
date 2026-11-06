import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FakeGlasses } from '../testing/fake-glasses.ts';
import { rng } from '../testing/random.ts';
import { createLoopbackPair } from '../transports/loopback.ts';
import {
  FrameDecoder,
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
          const m = decodeBody(f.body)!;
          const control = f.svc === 0 && (m.op === 2 || m.op === 3);
          if (!control && !sent.has(f.seq))
            sent.set(f.seq, f.body.length + FRAME_OVERHEAD);
          maxInFlight = Math.max(maxInFlight, inFlight());
        }
      } else {
        for (const f of toPhone.push(chunk)) {
          const m = decodeBody(f.body)!;
          if (f.svc === 0 && (m.op === 2 || m.op === 3)) {
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

for (const both of [false, true])
  test(`resync: damaged chunks ${both ? 'both ways' : 'phone → glasses'} are recovered in order, exactly once`, async () => {
    const r = rng(both ? 10 : 9);
    let damaged = 0;
    const [a, b] = createLoopbackPair({
      mtu: 60,
      tamper: (chunk, from) => {
        if ((from !== 'a' && !both) || r.next() > 0.08) return chunk;
        damaged++;
        if (r.next() < 0.5) return undefined; // lost write
        const c = chunk.slice();
        c[r.int(0, c.length - 1)] ^= 0x20;
        return c;
      },
    });
    const phone = new WispLink(a, { requestTimeoutMs: 20_000 });
    const glasses = new FakeGlasses(b);
    phone.setPeerLimits({ maxFrame: 4096, rxWindow: 2000 });
    glasses.link.setPeerLimits({ maxFrame: 4096, rxWindow: 16384 });

    const N = 400;
    for (let i = 0; i < N; i++)
      phone.notify(Display.fill, { layer: 2, x: i, w: r.int(0, 999) });
    // A lost tail is only noticed when something follows it: keep the link
    // busy like the keepalive would, until the final request gets through.
    let done = false;
    const final = phone
      .call(Session.ping, { token: 1 })
      .then(() => (done = true));
    while (!done) {
      await sleep(20);
      if (!done) phone.notify(Session.ping, { token: 2 });
    }
    await final;
    const xs = glasses.named('FILL').map((f) => f.fields.x);
    assert.deepEqual(
      xs,
      Array.from({ length: N }, (_, i) => i),
    );
    assert.ok(damaged > 5, `damaged ${damaged}`);
    assert.ok(phone.stats.retransmits > 0);
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

test('duplicate seq is dropped silently; a gap triggers RESYNC with the last good seq', async () => {
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
  const resync = out
    .map((f) => decodeBody(f.body)!)
    .find((b) => b.op === Session.resync.op)!;
  assert.deepEqual(Session.resync.request!.decode(resync.payload), {
    lastGoodSeq: 1,
  });
  m.deliver(ev(2, 14));
  m.deliver(ev(3, 15));
  assert.deepEqual(got, [10, 12, 14, 15]);
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
