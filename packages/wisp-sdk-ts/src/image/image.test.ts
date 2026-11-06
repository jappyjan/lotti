import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Codec } from '../protocol/constants.ts';
import { ByteReader, toHex, utf8Encode } from '../protocol/bytes.ts';
import { rng } from '../testing/random.ts';
import {
  animationResource,
  decodePixels,
  encodePixels,
  encodeSmallest,
  imageResource,
  xorFrames,
} from './codec.ts';
import { resourceHash, setSha256, sha256 } from './hash.ts';
import { lz4Compress, lz4Decompress } from './lz4.ts';
import {
  getPixel4,
  packRaw4,
  toRaw4,
  unpackRaw4,
  type Image4,
} from './raw4.ts';
import { decodeRle4, encodeRle4 } from './rle4.ts';

function randomImage(
  r: ReturnType<typeof rng>,
  w: number,
  h: number,
  runny: boolean,
): Image4 {
  const levels = new Uint8Array(w * h);
  let v = 0;
  for (let i = 0; i < levels.length; i++) {
    if (!runny || r.next() < 0.1) v = r.int(0, 15);
    levels[i] = v;
  }
  return packRaw4(w, h, levels);
}

test('RAW4 packing: high nibble is the left pixel, rows padded', () => {
  const img = packRaw4(3, 2, [1, 2, 3, 4, 5, 6]);
  assert.equal(toHex(img.data), '1230' + '4560');
  assert.equal(getPixel4(img, 2, 1), 6);
  assert.deepEqual(unpackRaw4(img), Uint8Array.from([1, 2, 3, 4, 5, 6]));
});

test('toRaw4: greyscale, RGBA luma, alpha and inversion', () => {
  assert.deepEqual(
    toRaw4({ width: 4, height: 1, data: [0, 17, 128, 255] }).data,
    Uint8Array.from([0x01, 0x8f]),
  );
  const rgba = [
    255, 255, 255, 255, 255, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 255,
  ];
  assert.deepEqual(
    unpackRaw4(toRaw4({ width: 4, height: 1, data: rgba })),
    Uint8Array.from([15, 4, 0, 0]),
  );
  assert.deepEqual(
    unpackRaw4(
      toRaw4({ width: 2, height: 1, data: [0, 255] }, { invert: true }),
    ),
    Uint8Array.from([15, 0]),
  );
  assert.throws(
    () => toRaw4({ width: 2, height: 2, data: [1, 2, 3] }),
    RangeError,
  );
});

test('dithering keeps the mean brightness of a flat in-between grey', () => {
  const grey = 100; // between levels 5 (85) and 6 (102)
  for (const dither of ['floyd-steinberg', 'ordered'] as const) {
    const img = toRaw4(
      { width: 32, height: 32, data: new Array(1024).fill(grey) },
      { dither },
    );
    const px = unpackRaw4(img);
    const mean = (px.reduce((a, b) => a + b, 0) / px.length) * 17;
    assert.ok(Math.abs(mean - grey) < 3, `${dither}: ${mean}`);
    assert.ok(new Set(px).size > 1, dither);
  }
});

test('RLE4: runs of up to 16, crossing rows, odd widths', () => {
  const img = packRaw4(3, 2, [7, 7, 7, 7, 7, 1]);
  assert.equal(toHex(encodeRle4(img)), '47' + '01');
  const long = packRaw4(20, 1, new Array(20).fill(15));
  assert.equal(toHex(encodeRle4(long)), 'ff' + '3f');
  const r = rng(5);
  for (let i = 0; i < 200; i++) {
    const w = r.int(1, 40);
    const h = r.int(1, 20);
    const im = randomImage(r, w, h, r.next() < 0.5);
    assert.deepEqual(decodeRle4(encodeRle4(im), w, h), im);
  }
  assert.throws(() => decodeRle4(Uint8Array.from([0x0f]), 2, 1), RangeError);
});

test('LZ4: round trips, compresses, and decodes reference-style input', () => {
  const r = rng(6);
  for (let n = 0; n < 40; n++) {
    const src = r.bytes(n);
    assert.deepEqual(lz4Decompress(lz4Compress(src)), src);
  }
  for (let i = 0; i < 300; i++) {
    const n = r.int(0, 3000);
    const runny = r.next() < 0.5;
    const src = runny
      ? Uint8Array.from({ length: n }, (_, k) => (k >> r.int(2, 6)) & 3)
      : r.bytes(n);
    assert.deepEqual(lz4Decompress(lz4Compress(src)), src);
  }
  const zeros = new Uint8Array(10000);
  assert.ok(lz4Compress(zeros).length < 100);
  assert.deepEqual(lz4Decompress(lz4Compress(zeros)), zeros);
  // Hand-made block: 4 literals "abcd", match offset 4 length 8, last literals "xyzzy".
  const block = Uint8Array.from([
    0x44,
    ...utf8Encode('abcd'),
    4,
    0,
    0x50,
    ...utf8Encode('xyzzy'),
  ]);
  assert.equal(
    new TextDecoder().decode(lz4Decompress(block)),
    'abcdabcdabcdxyzzy',
  );
  assert.throws(
    () => lz4Decompress(Uint8Array.from([0x10, 0x61, 9, 0])),
    RangeError,
  );
});

test('codecs round trip and encodeSmallest picks the smallest allowed', () => {
  const r = rng(7);
  for (let i = 0; i < 100; i++) {
    const img = randomImage(r, r.int(1, 64), r.int(1, 32), r.next() < 0.7);
    for (const codec of [
      Codec.raw4,
      Codec.rle4,
      Codec.lz4,
      Codec.lz4Rle,
    ] as const)
      assert.deepEqual(
        decodePixels(encodePixels(img, codec), codec, img.width, img.height),
        img,
      );
    const best = encodeSmallest(img);
    for (const codec of [
      Codec.raw4,
      Codec.rle4,
      Codec.lz4,
      Codec.lz4Rle,
    ] as const)
      assert.ok(best.data.length <= encodePixels(img, codec).length);
    assert.equal(encodeSmallest(img, [Codec.raw4]).codec, Codec.raw4);
  }
});

test('XOR delta frames and the animation resource layout', () => {
  const a = packRaw4(4, 2, [1, 2, 3, 4, 5, 6, 7, 8]);
  const b = packRaw4(4, 2, [1, 2, 3, 4, 5, 6, 7, 9]);
  assert.deepEqual(
    unpackRaw4(xorFrames(a, b)),
    Uint8Array.from([0, 0, 0, 0, 0, 0, 0, 1]),
  );
  assert.deepEqual(xorFrames(xorFrames(a, b), a), b);

  const big = packRaw4(
    64,
    64,
    new Uint8Array(4096).map((_, i) => (i * 7) & 15),
  );
  const big2 = { ...big, data: big.data.slice() };
  big2.data[100] ^= 0x11;
  const res = animationResource(
    [
      { image: big, durationMs: 40 },
      { image: big2, durationMs: 50 },
    ],
    { codec: Codec.rle4 },
  );
  const rd = new ByteReader(res);
  assert.deepEqual(
    [rd.u16(), rd.u16(), rd.u16(), rd.u8()],
    [64, 64, 2, Codec.rle4],
  );
  const f0 = [rd.u16(), rd.u8(), rd.u32()];
  assert.deepEqual(f0.slice(0, 2), [40, 0]);
  rd.bytes(f0[2]!);
  const [dur, kind, size] = [rd.u16(), rd.u8(), rd.u32()];
  assert.deepEqual([dur, kind], [50, 1]);
  const delta = decodePixels(rd.bytes(size!)!, Codec.rle4, 64, 64);
  assert.deepEqual(xorFrames(big, delta), big2);
  assert.equal(rd.remaining, 0);

  const ir = imageResource(a, { codec: Codec.raw4, data: a.data });
  assert.equal(toHex(ir), '0400' + '0200' + '04' + '00' + toHex(a.data));
});

test('resource hash is the first 16 bytes of SHA-256, injectable', async () => {
  assert.equal(
    toHex(await sha256(utf8Encode('abc'))),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  );
  assert.equal(
    toHex(await resourceHash(utf8Encode('abc'))),
    'ba7816bf8f01cfea414140de5dae2223',
  );
  setSha256(() => new Uint8Array(32).fill(1));
  try {
    assert.equal(toHex(await resourceHash(utf8Encode('abc'))), '01'.repeat(16));
  } finally {
    setSha256(undefined);
  }
});
