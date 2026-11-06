import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  crc16CcittFalse,
  encodeTpl,
  TPL_CHUNK_SIZE,
  TPL_FROM_GLASSES,
  TplAssembler,
} from './tpl.ts';

const ascii = (s: string) => Uint8Array.from(s, (c) => c.charCodeAt(0));

describe('TPL framing', () => {
  it('CRC-16/CCITT-FALSE check value', () => {
    assert.equal(crc16CcittFalse(ascii('123456789')), 0x29b1);
  });

  it('a short message is one packet with the CRC at the end, little-endian', () => {
    const [packet, ...rest] = encodeTpl({
      sid: 0xc0,
      seq: 7,
      payload: Uint8Array.of(0),
    });
    assert.equal(rest.length, 0);
    const crc = crc16CcittFalse(Uint8Array.of(0));
    assert.deepEqual(
      packet,
      Uint8Array.of(0xaa, 0x21, 7, 3, 1, 1, 0xc0, 0, 0, crc & 0xff, crc >> 8),
    );
  });

  it('a 4 KiB block splits into 232-byte chunks, the CRC may straddle packets, and reassembles', () => {
    for (const size of [
      4096,
      2 * TPL_CHUNK_SIZE - 1,
      2 * TPL_CHUNK_SIZE - 2,
      1,
    ]) {
      const payload = Uint8Array.from(
        { length: size },
        (_, i) => (i * 31) & 0xff,
      );
      const packets = encodeTpl(
        { sid: 0xc1, seq: 200, payload },
        TPL_FROM_GLASSES,
      );
      assert.equal(packets.length, Math.ceil((size + 2) / TPL_CHUNK_SIZE));
      packets.forEach((p, i) => {
        assert.equal(p[4], packets.length);
        assert.equal(p[5], i + 1);
        assert.equal(p[2], 200);
      });
      const asm = new TplAssembler();
      const results = packets.map((p) => asm.feed(p));
      const last = results.at(-1)!;
      assert.equal(last.kind, 'message');
      if (last.kind === 'message')
        assert.deepEqual(last.message.payload, payload);
    }
  });

  it('a corrupted message is reported as crc-error, never delivered', () => {
    const packets = encodeTpl({
      sid: 0xc0,
      seq: 1,
      payload: Uint8Array.of(3, 8),
    });
    packets[0]![8] ^= 1;
    assert.equal(new TplAssembler().feed(packets[0]!).kind, 'crc-error');
  });

  it('a gap drops the message', () => {
    const packets = encodeTpl({
      sid: 0xc1,
      seq: 1,
      payload: new Uint8Array(1000),
    });
    const asm = new TplAssembler();
    asm.feed(packets[0]!);
    assert.equal(asm.feed(packets[2]!).kind, 'ignored');
    assert.equal(asm.feed(packets[3]!).kind, 'ignored');
  });

  it('rejects out-of-range header fields', () => {
    assert.throws(
      () => encodeTpl({ sid: 0x100, seq: 0, payload: new Uint8Array(1) }),
      RangeError,
    );
    assert.throws(
      () => encodeTpl({ sid: 0, seq: -1, payload: new Uint8Array(1) }),
      RangeError,
    );
  });
});
