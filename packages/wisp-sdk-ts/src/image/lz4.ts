/**
 * LZ4 block format (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md),
 * written from the format description. A greedy single-probe compressor: not
 * as tight as the reference one, but small, and its output is valid LZ4.
 */

const MIN_MATCH = 4;
/** The last match must start at least 12 bytes before the end. */
const MF_LIMIT = 12;
/** The last 5 bytes are always literals. */
const LAST_LITERALS = 5;
const HASH_BITS = 12;

function read32(b: Uint8Array, i: number): number {
  return (
    (b[i]! | (b[i + 1]! << 8) | (b[i + 2]! << 16) | (b[i + 3]! << 24)) >>> 0
  );
}

export function lz4Compress(src: Uint8Array): Uint8Array {
  const n = src.length;
  const out = new Uint8Array(n + Math.ceil(n / 255) + 16);
  let o = 0;
  const writeLen = (len: number) => {
    for (; len >= 255; len -= 255) out[o++] = 255;
    out[o++] = len;
  };
  const emit = (
    anchor: number,
    litEnd: number,
    offset: number,
    matchLen: number,
  ) => {
    const lit = litEnd - anchor;
    const ml = matchLen - MIN_MATCH;
    out[o++] = (Math.min(lit, 15) << 4) | (matchLen ? Math.min(ml, 15) : 0);
    if (lit >= 15) writeLen(lit - 15);
    out.set(src.subarray(anchor, litEnd), o);
    o += lit;
    if (!matchLen) return;
    out[o++] = offset & 255;
    out[o++] = offset >> 8;
    if (ml >= 15) writeLen(ml - 15);
  };

  const table = new Int32Array(1 << HASH_BITS).fill(-1);
  let anchor = 0;
  let ip = 0;
  const mfLimit = n - MF_LIMIT;
  const matchLimit = n - LAST_LITERALS;
  while (ip < mfLimit) {
    const seq = read32(src, ip);
    const h = Math.imul(seq, 2654435761) >>> (32 - HASH_BITS);
    const ref = table[h]!;
    table[h] = ip;
    if (ref < 0 || ip - ref > 0xffff || read32(src, ref) !== seq) {
      ip++;
      continue;
    }
    let len = MIN_MATCH;
    while (ip + len < matchLimit && src[ref + len] === src[ip + len]) len++;
    emit(anchor, ip, ip - ref, len);
    ip += len;
    anchor = ip;
  }
  emit(anchor, n, 0, 0);
  return out.slice(0, o);
}

/** Decodes an LZ4 block. `maxSize` bounds the output (and catches bad input). */
export function lz4Decompress(src: Uint8Array, maxSize = 1 << 24): Uint8Array {
  let out = new Uint8Array(Math.min(maxSize, Math.max(64, src.length * 4)));
  let o = 0;
  let i = 0;
  const ensure = (extra: number) => {
    if (o + extra > maxSize) throw new RangeError('LZ4 output exceeds maxSize');
    if (o + extra <= out.length) return;
    const next = new Uint8Array(
      Math.min(maxSize, Math.max(out.length * 2, o + extra)),
    );
    next.set(out.subarray(0, o));
    out = next;
  };
  const readLen = (len: number): number => {
    if (len !== 15) return len;
    for (;;) {
      if (i >= src.length) throw new RangeError('truncated LZ4 length');
      const b = src[i++]!;
      len += b;
      if (b !== 255) return len;
    }
  };
  while (i < src.length) {
    const token = src[i++]!;
    const lit = readLen(token >> 4);
    if (i + lit > src.length) throw new RangeError('truncated LZ4 literals');
    ensure(lit);
    out.set(src.subarray(i, i + lit), o);
    o += lit;
    i += lit;
    if (i >= src.length) break;
    if (i + 2 > src.length) throw new RangeError('truncated LZ4 offset');
    const offset = src[i]! | (src[i + 1]! << 8);
    i += 2;
    if (offset === 0 || offset > o) throw new RangeError('bad LZ4 offset');
    const ml = readLen(token & 15) + MIN_MATCH;
    ensure(ml);
    for (let k = 0; k < ml; k++, o++) out[o] = out[o - offset]!;
  }
  return out.slice(0, o);
}
