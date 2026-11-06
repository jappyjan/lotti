import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ByteReader,
  ByteWriter,
  fromHex,
  toHex,
  utf8Decode,
  utf8Encode,
} from './bytes.ts';
import { crc16 } from './crc.ts';

test('utf8 round trips every plane and matches the platform encoder', () => {
  for (const s of ['', 'abc', 'Grüße', '日本語', 'emoji 🙂👓', '\u0000x']) {
    const b = utf8Encode(s);
    assert.deepEqual(b, new TextEncoder().encode(s));
    assert.equal(utf8Decode(b), s);
  }
});

test('utf8 decode replaces malformed sequences', () => {
  assert.equal(utf8Decode(Uint8Array.from([0x61, 0xc3, 0x62])), 'a�b');
  assert.equal(utf8Decode(Uint8Array.from([0xff, 0x80])), '��');
  assert.equal(utf8Decode(Uint8Array.from([0xe6, 0x97])), '��');
});

test('writer/reader are little-endian and reads past the end give undefined', () => {
  const b = new ByteWriter(1)
    .u8(1)
    .u16(0x0302)
    .i16(-2)
    .u32(0x07060504)
    .u64(2 ** 40 + 1)
    .finish();
  assert.equal(toHex(b), '010203feff04050607' + '0100000000010000');
  const r = new ByteReader(b);
  assert.deepEqual(
    [r.u8(), r.u16(), r.i16(), r.u32(), r.u64()],
    [1, 0x0302, -2, 0x07060504, 2 ** 40 + 1],
  );
  assert.equal(r.u8(), undefined);
  assert.deepEqual(fromHex(toHex(b)), b);
});

test('crc16 CCITT-FALSE check value', () => {
  assert.equal(crc16(utf8Encode('123456789')), 0x29b1);
  assert.equal(crc16(new Uint8Array(0)), 0xffff);
});
