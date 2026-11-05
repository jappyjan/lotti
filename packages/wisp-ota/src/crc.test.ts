import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { crc32 as zlibCrc32 } from 'node:zlib';
import { crc32, crc32Bitwise, crc32cMsb, crc32cMsbBitwise } from './crc.ts';
import { filler } from './testing/synthetic.ts';

const CHECK = new Uint8Array(
  [...('123456789' as string)].map((c) => c.charCodeAt(0)),
);

describe('CRC-32C MSB-first (EVENOTA layer)', () => {
  it('matches the openCFW check value', () => {
    // open_cfw.py crc32c_msb(b"123456789") == 0xc052a8c8
    assert.equal(crc32cMsb(CHECK), 0xc052a8c8);
    assert.equal(crc32cMsbBitwise(CHECK), 0xc052a8c8);
  });

  it('is 0 for empty input (init 0, xorout 0)', () => {
    assert.equal(crc32cMsb(new Uint8Array()), 0);
    assert.equal(crc32cMsbBitwise(new Uint8Array()), 0);
  });

  it('matches openCFW on 0..255 x3', () => {
    const data = new Uint8Array(768).map((_, i) => i & 0xff);
    assert.equal(crc32cMsb(data), 0x5476eb03);
  });

  it('table and bitwise implementations agree', () => {
    for (const length of [1, 2, 3, 7, 64, 1000, 4099]) {
      const data = filler(length, length);
      assert.equal(crc32cMsb(data), crc32cMsbBitwise(data), `length ${length}`);
    }
  });
});

describe('zlib CRC-32 (main-app preamble layer)', () => {
  it('matches the standard check value', () => {
    assert.equal(crc32(CHECK), 0xcbf43926);
    assert.equal(crc32Bitwise(CHECK), 0xcbf43926);
  });

  it('matches node:zlib and Python zlib', () => {
    const data = new Uint8Array(768).map((_, i) => i & 0xff);
    assert.equal(crc32(data), 0xb0c0df2a);
    for (const length of [0, 1, 5, 333, 8191]) {
      const d = filler(length, length + 9);
      assert.equal(crc32(d), zlibCrc32(d) >>> 0, `length ${length}`);
      assert.equal(crc32Bitwise(d), zlibCrc32(d) >>> 0, `length ${length}`);
    }
  });
});
