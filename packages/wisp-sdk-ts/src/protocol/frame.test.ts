import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rng } from '../testing/random.ts';
import { concatBytes, toHex } from './bytes.ts';
import { crc16 } from './crc.ts';
import {
  FrameDecoder,
  FrameFlag,
  encodeFrame,
  routeByte,
  seqDiff,
  type Frame,
  type FrameError,
} from './frame.ts';

const frame = (seq: number, body: Uint8Array, svc = 2): Frame => ({
  svc,
  route: routeByte(1),
  fflags: 0,
  seq,
  body,
});

function split(
  bytes: Uint8Array,
  r: ReturnType<typeof rng>,
  max: number,
): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (let i = 0; i < bytes.length;) {
    const n = r.int(1, max);
    out.push(bytes.subarray(i, i + n));
    i += n;
  }
  return out;
}

test('frame layout: magic, svc, route, fflags, len, seq, body, crc', () => {
  const f = encodeFrame({
    svc: 0,
    route: 1,
    seq: 0x0102,
    body: Uint8Array.from([0xaa, 0xbb]),
  });
  assert.equal(toHex(f.subarray(0, 10)), '570001000200020' + '1aabb');
  assert.equal(f.length, 12);
});

test('decoder: randomized chunking reassembles every frame (1000 rounds)', () => {
  const r = rng(1);
  for (let round = 0; round < 1000; round++) {
    const frames = Array.from({ length: r.int(1, 8) }, (_, i) =>
      frame(i, r.bytes(r.int(0, 300)), r.int(0, 7)),
    );
    const stream = concatBytes(frames.map((f) => encodeFrame(f)));
    const d = new FrameDecoder();
    const got = split(stream, r, r.int(1, 64)).flatMap((c) => d.push(c));
    assert.deepEqual(got, frames);
    assert.equal(d.buffered, 0);
  }
});

test('decoder: resyncs after garbage, bad CRC and bogus lengths', () => {
  const r = rng(2);
  for (let round = 0; round < 500; round++) {
    const frames = Array.from({ length: 6 }, (_, i) =>
      frame(i, r.bytes(r.int(0, 100))),
    );
    const encoded = frames.map((f) => encodeFrame(f));
    const victim = r.int(0, 5);
    const kind = r.int(0, 1);
    const bad = encoded[victim]!.slice();
    if (kind === 0) bad[r.int(8, bad.length - 1)] ^= 1 << r.int(0, 7); // body or crc bit flip
    if (kind === 1) bad[5] = 0xff; // len > maxFrame
    const parts = encoded.map((e, i) => (i === victim ? bad : e));
    // Garbage, including a stray magic byte, before the first frame.
    const stream = concatBytes([Uint8Array.from([0x00, 0x57, 0x13]), ...parts]);
    const errors: FrameError[] = [];
    const d = new FrameDecoder({
      maxFrame: 1024,
      onError: (k) => errors.push(k),
    });
    // A magic lookalike in the dropped bytes may carry a plausible len and
    // wait for that many bytes; on a link the ack timeout supplies them. Here
    // later traffic does.
    const later = Array.from({ length: 12 }, (_, i) =>
      frame(6 + i, new Uint8Array(100)),
    );
    const got = split(stream, r, 40).flatMap((c) => d.push(c));
    for (const f of later) {
      if (got.length >= 5) break;
      got.push(...d.push(encodeFrame(f)));
    }
    assert.deepEqual(
      got.slice(0, 5),
      frames.filter((_, i) => i !== victim),
      `round ${round} kind ${kind}`,
    );
    assert.ok(errors.length >= 1);
  }
});

test('decoder: a corrupt len holds frames back until the resend brings enough bytes', () => {
  const frames = [
    frame(0, new Uint8Array(20)),
    frame(1, Uint8Array.from([1, 2, 3])),
    frame(2, new Uint8Array(0)),
  ];
  const bad = encodeFrame(frames[0]!);
  bad[5] = 0x01; // len 0x114: plausible, but longer than what follows
  const errors: FrameError[] = [];
  const d = new FrameDecoder({ onError: (k) => errors.push(k) });
  const good = frames.map((f) => encodeFrame(f));
  assert.deepEqual(d.push(concatBytes([bad, good[1]!, good[2]!])), []);
  // The sender's ack timeout resends all three; once the bogus length is
  // covered its CRC fails and everything behind it is rescanned.
  const got = [];
  for (let i = 0; i < 12 && got.length < 4; i++)
    got.push(...d.push(concatBytes(good)));
  assert.deepEqual(got.slice(0, 2), frames.slice(1));
  assert.deepEqual(errors, ['crc']);
});

test('decoder: a frame whose body holds a whole valid frame is delivered intact', () => {
  // e.g. a PUT_DATA of a captured Wisp stream, arriving in small chunks
  const inner = encodeFrame(frame(9, Uint8Array.from([4, 0, 0, 0, 1, 2]), 0));
  const outer = frame(
    3,
    concatBytes([Uint8Array.from([2, 0, 0, 0]), inner, inner]),
    3,
  );
  const r = rng(5);
  for (let round = 0; round < 50; round++) {
    const d = new FrameDecoder();
    const got = split(encodeFrame(outer), r, 12).flatMap((c) => d.push(c));
    assert.deepEqual(got, [outer]);
  }
});

test('decoder: reserved route or fflags bits make a frame bad', () => {
  const good = [frame(0, Uint8Array.of(1)), frame(1, Uint8Array.of(2))];
  for (const [at, v] of [
    [2, 0x10],
    [2, 0x80],
    [3, 0x02],
    [3, 0x81],
  ] as const) {
    const bad = encodeFrame(good[0]!);
    bad[at] = v;
    const crc = crc16(bad, 0, bad.length - 2);
    bad[bad.length - 2] = crc & 255;
    bad[bad.length - 1] = crc >> 8;
    const errors: FrameError[] = [];
    const d = new FrameDecoder({ onError: (k) => errors.push(k) });
    assert.deepEqual(d.push(concatBytes([bad, encodeFrame(good[1]!)])), [
      good[1],
    ]);
    assert.deepEqual(errors, ['reserved']);
  }
  assert.throws(() => encodeFrame({ ...good[0]!, route: 0x10 }), RangeError);
  assert.throws(() => encodeFrame({ ...good[0]!, fflags: 2 }), RangeError);
  const ctrl = { ...good[0]!, fflags: FrameFlag.ctrl };
  assert.deepEqual(new FrameDecoder().push(encodeFrame(ctrl)), [ctrl]);
});

test('seqDiff wraps', () => {
  assert.equal(seqDiff(0, 0xffff), 1);
  assert.equal(seqDiff(0xffff, 0), -1);
  assert.equal(seqDiff(5, 5), 0);
});
