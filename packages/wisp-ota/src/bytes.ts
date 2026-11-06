// Little-endian helpers over plain Uint8Array (no Buffer, no TextDecoder), so
// the library runs unchanged in Node, browsers and React Native.

export function readU32(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw new RangeError(
      `u32 read at 0x${offset.toString(16)} is out of bounds`,
    );
  }
  return (
    (bytes[offset]! |
      (bytes[offset + 1]! << 8) |
      (bytes[offset + 2]! << 16) |
      (bytes[offset + 3]! << 24)) >>>
    0
  );
}

export function writeU32(
  bytes: Uint8Array,
  offset: number,
  value: number,
): void {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw new RangeError(
      `u32 write at 0x${offset.toString(16)} is out of bounds`,
    );
  }
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >>> 8) & 0xff;
  bytes[offset + 2] = (value >>> 16) & 0xff;
  bytes[offset + 3] = (value >>> 24) & 0xff;
}

/** A NUL-padded ASCII field as read: `text` up to the first NUL. */
export interface FixedString {
  text: string;
  /** A NUL exists inside the field. */
  terminated: boolean;
  /** Every byte before the NUL is printable ASCII (0x20–0x7E). */
  printable: boolean;
  /** Every byte after the first NUL is NUL too. */
  cleanPadding: boolean;
}

export function readFixedString(
  bytes: Uint8Array,
  offset: number,
  size: number,
): FixedString {
  const field = bytes.subarray(offset, offset + size);
  const nul = field.indexOf(0);
  const end = nul === -1 ? field.length : nul;
  let text = '';
  let printable = true;
  for (let i = 0; i < end; i++) {
    const c = field[i]!;
    if (c < 0x20 || c > 0x7e) printable = false;
    text += String.fromCharCode(c);
  }
  let cleanPadding = true;
  for (let i = end; i < field.length; i++)
    if (field[i] !== 0) cleanPadding = false;
  return { text, terminated: nul !== -1, printable, cleanPadding };
}

/** Writes `text` NUL-padded into a `size`-byte field. Needs room for one NUL. */
export function writeFixedString(
  bytes: Uint8Array,
  offset: number,
  size: number,
  text: string,
): void {
  const encoded = asciiBytes(text);
  if (encoded.length >= size) {
    throw new RangeError(
      `"${text}" does not fit a ${size}-byte NUL-terminated field`,
    );
  }
  bytes.fill(0, offset, offset + size);
  bytes.set(encoded, offset);
}

/** Printable ASCII only; anything else is a caller bug. */
export function asciiBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x20 || c > 0x7e)
      throw new RangeError(`non-printable character in "${text}"`);
    out[i] = c;
  }
  return out;
}

export function equalBytes(
  a: ArrayLike<number>,
  b: ArrayLike<number>,
): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export function hex32(value: number): string {
  return `0x${(value >>> 0).toString(16).padStart(8, '0')}`;
}

export function hex(value: number): string {
  return `0x${value.toString(16)}`;
}
