/** Little-endian byte helpers. No Node or DOM APIs, so they run anywhere. */

export function utf8Encode(text: string): Uint8Array {
  const out: number[] = [];
  for (const ch of text) {
    const c = ch.codePointAt(0)!;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000)
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else
      out.push(
        0xf0 | (c >> 18),
        0x80 | ((c >> 12) & 63),
        0x80 | ((c >> 6) & 63),
        0x80 | (c & 63),
      );
  }
  return Uint8Array.from(out);
}

/** Decodes UTF-8, replacing malformed sequences with U+FFFD. */
export function utf8Decode(bytes: Uint8Array): string {
  let s = '';
  let i = 0;
  while (i < bytes.length) {
    const b = bytes[i]!;
    if (b < 0x80) {
      s += String.fromCharCode(b);
      i++;
      continue;
    }
    const need =
      b >= 0xf8 ? 0 : b >= 0xf0 ? 3 : b >= 0xe0 ? 2 : b >= 0xc0 ? 1 : 0;
    let c = b & (0x3f >> need);
    let k = 1;
    for (; k <= need; k++) {
      const n = bytes[i + k];
      if (n === undefined || (n & 0xc0) !== 0x80) break;
      c = (c << 6) | (n & 63);
    }
    if (need === 0 || k <= need || c > 0x10ffff) {
      s += '\ufffd';
      i++;
      continue;
    }
    s += String.fromCodePoint(c);
    i += need + 1;
  }
  return s;
}

export function toHex(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

export function fromHex(hex: string): Uint8Array {
  if (hex.length % 2) throw new Error('odd hex length');
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const v = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(v)) throw new Error('bad hex');
    out[i] = v;
  }
  return out;
}

export function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** Growable little-endian writer. */
export class ByteWriter {
  private buf: Uint8Array;
  private view: DataView;
  length = 0;

  constructor(capacity = 64) {
    this.buf = new Uint8Array(capacity);
    this.view = new DataView(this.buf.buffer);
  }

  private reserve(n: number): number {
    const at = this.length;
    if (at + n > this.buf.length) {
      const next = new Uint8Array(Math.max(this.buf.length * 2, at + n));
      next.set(this.buf.subarray(0, at));
      this.buf = next;
      this.view = new DataView(next.buffer);
    }
    this.length += n;
    return at;
  }

  u8(v: number): this {
    const at = this.reserve(1);
    this.view.setUint8(at, v);
    return this;
  }
  i8(v: number): this {
    const at = this.reserve(1);
    this.view.setInt8(at, v);
    return this;
  }
  u16(v: number): this {
    const at = this.reserve(2);
    this.view.setUint16(at, v, true);
    return this;
  }
  i16(v: number): this {
    const at = this.reserve(2);
    this.view.setInt16(at, v, true);
    return this;
  }
  u32(v: number): this {
    const at = this.reserve(4);
    this.view.setUint32(at, v, true);
    return this;
  }
  i32(v: number): this {
    const at = this.reserve(4);
    this.view.setInt32(at, v, true);
    return this;
  }
  u64(v: number | bigint): this {
    const at = this.reserve(8);
    this.view.setBigUint64(at, BigInt(v), true);
    return this;
  }
  bytes(b: Uint8Array): this {
    const at = this.reserve(b.length);
    this.buf.set(b, at);
    return this;
  }
  /** Fixed-size field, zero-padded; throws if `b` doesn't fit. */
  fixed(b: Uint8Array, size: number): this {
    if (b.length > size)
      throw new RangeError(`field longer than ${size} bytes`);
    const at = this.reserve(size);
    this.buf.fill(0, at, at + size);
    this.buf.set(b, at);
    return this;
  }

  finish(): Uint8Array {
    return this.buf.slice(0, this.length);
  }
}

/**
 * Little-endian reader. Reads past the end return `undefined`, so decoders can
 * default missing trailing fields (the append-only rule).
 */
export class ByteReader {
  private readonly view: DataView;
  offset = 0;

  constructor(readonly data: Uint8Array) {
    this.view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  }

  get remaining(): number {
    return this.data.length - this.offset;
  }

  private take(n: number): number | undefined {
    if (this.offset + n > this.data.length) {
      this.offset = this.data.length;
      return undefined;
    }
    const at = this.offset;
    this.offset += n;
    return at;
  }

  u8(): number | undefined {
    const at = this.take(1);
    return at === undefined ? undefined : this.view.getUint8(at);
  }
  i8(): number | undefined {
    const at = this.take(1);
    return at === undefined ? undefined : this.view.getInt8(at);
  }
  u16(): number | undefined {
    const at = this.take(2);
    return at === undefined ? undefined : this.view.getUint16(at, true);
  }
  i16(): number | undefined {
    const at = this.take(2);
    return at === undefined ? undefined : this.view.getInt16(at, true);
  }
  u32(): number | undefined {
    const at = this.take(4);
    return at === undefined ? undefined : this.view.getUint32(at, true);
  }
  i32(): number | undefined {
    const at = this.take(4);
    return at === undefined ? undefined : this.view.getInt32(at, true);
  }
  u64(): number | undefined {
    const at = this.take(8);
    return at === undefined
      ? undefined
      : Number(this.view.getBigUint64(at, true));
  }
  bytes(n: number): Uint8Array | undefined {
    const at = this.take(n);
    return at === undefined ? undefined : this.data.slice(at, at + n);
  }
  rest(): Uint8Array {
    const at = this.offset;
    this.offset = this.data.length;
    return this.data.slice(at);
  }
}
