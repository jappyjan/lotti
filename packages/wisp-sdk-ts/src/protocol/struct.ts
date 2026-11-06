import { ByteReader, ByteWriter, utf8Decode, utf8Encode } from './bytes.ts';

/**
 * Field types of the spec. `bytes`, `utf8` and lists take the rest of the
 * payload, so they only appear last. A list (`{…}…` in the spec) is counted:
 * `count` names the earlier field with the item count, which is
 * authoritative, and each item is (remaining bytes / count) long, so items
 * can grow. Readers take the fields they know from each item and skip the
 * rest; a remainder that isn't a multiple of the count is a bad payload.
 * `encode` fills in a missing count.
 */
export type Scalar =
  | 'u8'
  | 'i8'
  | 'u16'
  | 'i16'
  | 'u32'
  | 'i32'
  | 'u64'
  | 'str16'
  | 'hash16'
  | 'sha256'
  | 'bytes'
  | 'utf8';
export interface ListType {
  readonly count: string;
  readonly item: Fields;
}
/** A counted list whose item layout the message doesn't fix (sensor samples): raw bytes. */
export interface CountedBytes {
  readonly count: string;
  readonly bytes: true;
}
export type FieldType = Scalar | ListType | CountedBytes;

/** A payload that breaks its layout: a field cut in half, or a list that doesn't divide by its count (error 2). */
export class PayloadError extends Error {
  readonly code = 2;
  override name = 'PayloadError';
}
export type Fields = { readonly [name: string]: FieldType };

type ValueOf<T> = T extends 'str16' | 'utf8'
  ? string
  : T extends 'hash16' | 'sha256' | 'bytes' | CountedBytes
    ? Uint8Array
    : T extends ListType
      ? Values<T['item']>[]
      : number;

export type Values<F extends Fields> = {
  -readonly [K in keyof F]: ValueOf<F[K]>;
};

export interface Struct<F extends Fields = Fields> {
  readonly fields: F;
  /** Missing fields are written as their default (zero unless stated). */
  encode(values?: Partial<Values<F>>): Uint8Array;
  /**
   * Ignores trailing bytes; missing trailing fields get their default.
   * Throws `PayloadError` for a field cut in half or a list that doesn't
   * divide by its count.
   */
  decode(payload: Uint8Array): Values<F>;
}

const FIXED: Partial<Record<Scalar, number>> = {
  str16: 16,
  hash16: 16,
  sha256: 32,
};

const SIZE: Partial<Record<Scalar, number>> = {
  u8: 1,
  i8: 1,
  u16: 2,
  i16: 2,
  u32: 4,
  i32: 4,
  u64: 8,
  ...FIXED,
};

const isCountedBytes = (t: FieldType): t is CountedBytes =>
  typeof t !== 'string' && 'bytes' in t;

/** `count` items share `len` bytes evenly; no items means no bytes. */
const listFits = (len: number, count: number) =>
  count ? len % count === 0 : len === 0;

function zero(t: FieldType): unknown {
  if (isCountedBytes(t)) return new Uint8Array(0);
  if (typeof t !== 'string') return [];
  switch (t) {
    case 'str16':
    case 'utf8':
      return '';
    case 'hash16':
    case 'sha256':
      return new Uint8Array(FIXED[t]!);
    case 'bytes':
      return new Uint8Array(0);
    default:
      return 0;
  }
}

function writeField(w: ByteWriter, t: FieldType, v: unknown) {
  if (isCountedBytes(t)) {
    w.bytes((v ?? new Uint8Array(0)) as Uint8Array);
    return;
  }
  if (typeof t !== 'string') {
    for (const item of (v ?? []) as Record<string, unknown>[])
      writeFields(w, t.item, item);
    return;
  }
  switch (t) {
    case 'u8':
    case 'i8':
    case 'u16':
    case 'i16':
    case 'u32':
    case 'i32':
    case 'u64': {
      const n = (v ?? 0) as number;
      if (t === 'u64') w.u64(n);
      else w[t](n);
      return;
    }
    case 'str16':
      w.fixed(utf8Encode((v ?? '') as string), 16);
      return;
    case 'hash16':
    case 'sha256':
      w.fixed((v ?? new Uint8Array(0)) as Uint8Array, FIXED[t]!);
      return;
    case 'bytes':
      w.bytes((v ?? new Uint8Array(0)) as Uint8Array);
      return;
    case 'utf8':
      w.bytes(utf8Encode((v ?? '') as string));
      return;
  }
}

function writeFields(
  w: ByteWriter,
  fields: Fields,
  values: Record<string, unknown>,
) {
  const v = { ...values };
  for (const [name, t] of Object.entries(fields)) {
    if (isCountedBytes(t)) {
      const len = ((values[name] ?? new Uint8Array(0)) as Uint8Array).length;
      if (!listFits(len, (v[t.count] ?? 0) as number))
        throw new RangeError(
          `${name}: ${len} bytes don't split into ${t.count} items`,
        );
    } else if (typeof t !== 'string') {
      const n = ((values[name] ?? []) as unknown[]).length;
      v[t.count] ??= n;
      if (v[t.count] !== n)
        throw new RangeError(
          `${name}: ${t.count} ${String(v[t.count])} but ${n} items`,
        );
    }
  }
  for (const [name, t] of Object.entries(fields)) writeField(w, t, v[name]);
}

function readField(r: ByteReader, t: Scalar): unknown {
  const size = SIZE[t];
  if (size !== undefined && r.remaining > 0 && r.remaining < size)
    throw new PayloadError(`${t} field cut in half`);
  switch (t) {
    case 'str16': {
      const b = r.bytes(16);
      if (!b) return undefined;
      const end = b.indexOf(0);
      return utf8Decode(end < 0 ? b : b.subarray(0, end));
    }
    case 'hash16':
    case 'sha256':
      return r.bytes(FIXED[t]!);
    case 'bytes':
      return r.rest();
    case 'utf8':
      return utf8Decode(r.rest());
    default:
      return r[t]();
  }
}

/** A counted list: `count` items of (rest / count) bytes each. */
function readList(
  r: ByteReader,
  t: ListType | CountedBytes,
  count: number,
): unknown {
  const rest = r.rest();
  if (!listFits(rest.length, count))
    throw new PayloadError(
      `${rest.length} bytes don't split into ${count} items`,
    );
  if (isCountedBytes(t)) return rest;
  const stride = count ? rest.length / count : 0;
  const items: unknown[] = [];
  for (let i = 0; i < count; i++)
    items.push(
      readFields(
        new ByteReader(rest.subarray(i * stride, (i + 1) * stride)),
        t.item,
        {},
      ),
    );
  return items;
}

function readFields(
  r: ByteReader,
  fields: Fields,
  defaults: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [name, t] of Object.entries(fields))
    out[name] =
      typeof t === 'string'
        ? (readField(r, t) ?? defaults[name] ?? zero(t))
        : readList(r, t, (out[t.count] ?? 0) as number);
  return out;
}

export function struct<const F extends Fields>(
  fields: F,
  defaults: Partial<Values<F>> = {},
): Struct<F> {
  return {
    fields,
    encode(values = {}) {
      const w = new ByteWriter();
      writeFields(w, fields, { ...defaults, ...values });
      return w.finish();
    },
    decode(payload) {
      return readFields(new ByteReader(payload), fields, defaults) as Values<F>;
    },
  };
}

export const empty = struct({});
