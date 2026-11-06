// Stock G2 transport framing ("TPL", the `0xAA` multipart envelope), as far as
// the stock OTA path needs it. Written from the documented layout:
//
//   AA <dir> <seq> <len> <total> <num> <sid> <flag> <chunk…> [CRC-16 LE, last packet only]
//
// - dir 0x21 phone → glasses, 0x12 glasses → phone (low nibble source, high
//   nibble destination/type);
// - seq: one value for every packet of one message (the reassembly key);
// - len: bytes after the 8-byte header in this packet, the CRC included;
// - total / num: packet count and 1-based packet number;
// - CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over the whole message
//   payload, little-endian, after the last chunk. The CRC may straddle the last
//   two packets: the receiver concatenates every chunk and strips 2 bytes.
//
// Sources: docs/spikes/s1-ble.md, packages/lotti-kit G2Frame.swift, openCFW
// `g2/docs/reference/protocols.md` §3 and `g2/src/apollo-main/app/
// a-12-ota-transport/ota_transport.c` (MIT), webflasher `src/lib/g2BleOta.js`
// `makeBleEnvelopeFrames` / `parseBleAck` (MIT).

export const TPL_MAGIC = 0xaa;
export const TPL_TO_GLASSES = 0x21;
export const TPL_FROM_GLASSES = 0x12;
export const TPL_HEADER_SIZE = 8;
/** Bytes of message (payload + CRC) per packet; webflasher and the Even app use 232. */
export const TPL_CHUNK_SIZE = 232;
/** A packet is at most header + chunk: 240 bytes, below the 244-byte write limit. */
export const TPL_MAX_PACKET = TPL_HEADER_SIZE + TPL_CHUNK_SIZE;

/** CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR. Check "123456789" = 0x29B1. */
export function crc16CcittFalse(data: Uint8Array): number {
  let crc = 0xffff;
  for (let i = 0; i < data.length; i++) {
    crc ^= data[i]! << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

export interface TplMessage {
  dir: number;
  seq: number;
  sid: number;
  flag: number;
  payload: Uint8Array;
}

/** Splits one message into packets (phone → glasses unless `dir` says otherwise). */
export function encodeTpl(
  message: { sid: number; seq: number; flag?: number; payload: Uint8Array },
  dir: number = TPL_TO_GLASSES,
): Uint8Array[] {
  const { sid, seq, payload } = message;
  const flag = message.flag ?? 0;
  for (const [name, v] of [
    ['sid', sid],
    ['seq', seq],
    ['flag', flag],
  ] as const) {
    if (!Number.isInteger(v) || v < 0 || v > 0xff)
      throw new RangeError(`TPL ${name} must be one byte, got ${v}`);
  }
  const crc = crc16CcittFalse(payload);
  const body = new Uint8Array(payload.length + 2);
  body.set(payload);
  body[payload.length] = crc & 0xff;
  body[payload.length + 1] = crc >>> 8;
  const total = Math.max(1, Math.ceil(body.length / TPL_CHUNK_SIZE));
  if (total > 0xff)
    throw new RangeError(
      `TPL message of ${payload.length} bytes needs ${total} packets`,
    );
  const packets: Uint8Array[] = [];
  for (let i = 0; i < total; i++) {
    const chunk = body.subarray(i * TPL_CHUNK_SIZE, (i + 1) * TPL_CHUNK_SIZE);
    const packet = new Uint8Array(TPL_HEADER_SIZE + chunk.length);
    packet.set([TPL_MAGIC, dir, seq, chunk.length, total, i + 1, sid, flag]);
    packet.set(chunk, TPL_HEADER_SIZE);
    packets.push(packet);
  }
  return packets;
}

export type TplFeedResult =
  | { kind: 'message'; message: TplMessage }
  | { kind: 'partial' }
  | { kind: 'ignored'; reason: string }
  | { kind: 'crc-error'; seq: number; sid: number };

/**
 * Reassembles packets into messages. Keyed by (dir, sid, seq); a gap, a
 * duplicate or an out-of-order packet drops that message. A message whose CRC
 * does not match is reported as `crc-error` and never delivered.
 */
export class TplAssembler {
  private partial = new Map<
    number,
    { next: number; total: number; chunks: Uint8Array[] }
  >();

  feed(packet: Uint8Array): TplFeedResult {
    if (packet.length < TPL_HEADER_SIZE || packet[0] !== TPL_MAGIC)
      return { kind: 'ignored', reason: 'not a TPL packet' };
    const dir = packet[1]!;
    const seq = packet[2]!;
    const len = packet[3]!;
    const total = packet[4]!;
    const num = packet[5]!;
    const sid = packet[6]!;
    const flag = packet[7]!;
    if (packet.length < TPL_HEADER_SIZE + len)
      return { kind: 'ignored', reason: 'truncated packet' };
    if (total < 1 || num < 1 || num > total)
      return { kind: 'ignored', reason: 'bad packet numbering' };
    const chunk = packet.slice(TPL_HEADER_SIZE, TPL_HEADER_SIZE + len);
    const key = (dir << 16) | (sid << 8) | seq;

    let chunks: Uint8Array[];
    if (total === 1) {
      this.partial.delete(key);
      chunks = [chunk];
    } else if (num === 1) {
      this.partial.set(key, { next: 2, total, chunks: [chunk] });
      return { kind: 'partial' };
    } else {
      const part = this.partial.get(key);
      if (!part || part.next !== num || part.total !== total) {
        this.partial.delete(key);
        return { kind: 'ignored', reason: 'packet out of order' };
      }
      part.chunks.push(chunk);
      if (num < total) {
        part.next = num + 1;
        return { kind: 'partial' };
      }
      this.partial.delete(key);
      chunks = part.chunks;
    }

    const size = chunks.reduce((n, c) => n + c.length, 0);
    if (size < 2)
      return { kind: 'ignored', reason: 'message shorter than its CRC' };
    const body = new Uint8Array(size);
    let at = 0;
    for (const c of chunks) {
      body.set(c, at);
      at += c.length;
    }
    const payload = body.slice(0, size - 2);
    const crc = body[size - 2]! | (body[size - 1]! << 8);
    if (crc !== crc16CcittFalse(payload))
      return { kind: 'crc-error', seq, sid };
    return { kind: 'message', message: { dir, seq, sid, flag, payload } };
  }

  reset(): void {
    this.partial.clear();
  }
}
