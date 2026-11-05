import { ByteReader, ByteWriter, utf8Decode, utf8Encode } from './bytes.ts';

/**
 * Field types of the spec. `bytes`, `utf8` and lists take the rest of the
 * payload, so they only appear last. A list (`{…}…` in the spec) repeats
 * fixed-size items to the end of the payload; its `count` names the field
 * that holds the item count, which `encode` fills in when it is missing.
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
export type FieldType = Scalar | ListType;
export type Fields = { readonly [name: string]: FieldType };

type ValueOf<T> = T extends 'str16' | 'utf8'
  ? string
  : T extends 'hash16' | 'sha256' | 'bytes'
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
  /** Ignores trailing bytes; missing trailing fields get their default. */
  decode(payload: Uint8Array): Values<F>;
}

const FIXED: Partial<Record<Scalar, number>> = {
  str16: 16,
  hash16: 16,
  sha256: 32,
};

function zero(t: FieldType): unknown {
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
  for (const [name, t] of Object.entries(fields))
    if (typeof t !== 'string')
      v[t.count] ??= ((values[name] ?? []) as unknown[]).length;
  for (const [name, t] of Object.entries(fields)) writeField(w, t, v[name]);
}

function itemSize(fields: Fields): number {
  let n = 0;
  for (const t of Object.values(fields)) {
    if (typeof t !== 'string')
      throw new Error('nested lists are not supported');
    n +=
      {
        u8: 1,
        i8: 1,
        u16: 2,
        i16: 2,
        u32: 4,
        i32: 4,
        u64: 8,
        str16: 16,
        hash16: 16,
        sha256: 32,
      }[t as 'u8'] ?? 0;
  }
  return n;
}

function readField(r: ByteReader, t: FieldType): unknown {
  if (typeof t !== 'string') {
    const size = itemSize(t.item);
    const items: unknown[] = [];
    while (r.remaining >= size && size > 0)
      items.push(readFields(r, t.item, {}));
    r.rest();
    return items;
  }
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

function readFields(
  r: ByteReader,
  fields: Fields,
  defaults: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [name, t] of Object.entries(fields))
    out[name] = readField(r, t) ?? defaults[name] ?? zero(t);
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
