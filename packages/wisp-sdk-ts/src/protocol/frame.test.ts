import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rng } from '../testing/random.ts';
import { concatBytes, toHex } from './bytes.ts';
import {
  FrameDecoder,
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
    const got = split(stream, r, 40).flatMap((c) => d.push(c));
    assert.deepEqual(
      got,
      frames.filter((_, i) => i !== victim),
      `round ${round} kind ${kind}`,
    );
    assert.ok(errors.length >= 1);
  }
});

test('decoder: a corrupt len pointing far ahead does not hide the frames behind it', () => {
  const frames = [
    frame(0, new Uint8Array(20)),
    frame(1, Uint8Array.from([1, 2, 3])),
    frame(2, new Uint8Array(0)),
  ];
  const bad = encodeFrame(frames[0]!);
  bad[5] = 0x03; // len 0x314: plausible, but far longer than what follows
  const d = new FrameDecoder();
  const got = d.push(
    concatBytes([bad, encodeFrame(frames[1]!), encodeFrame(frames[2]!)]),
  );
  assert.deepEqual(got, frames.slice(1));
});

test('seqDiff wraps', () => {
  assert.equal(seqDiff(0, 0xffff), 1);
  assert.equal(seqDiff(0xffff, 0), -1);
  assert.equal(seqDiff(5, 5), 0);
});
