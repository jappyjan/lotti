import { ByteWriter } from '../protocol/bytes.ts';
import { Codec, type CodecId } from '../protocol/constants.ts';
import { lz4Compress, lz4Decompress } from './lz4.ts';
import { stride4, type Image4 } from './raw4.ts';
import { decodeRle4, encodeRle4 } from './rle4.ts';

export function encodePixels(img: Image4, codec: CodecId): Uint8Array {
  switch (codec) {
    case Codec.raw4:
      return img.data;
    case Codec.rle4:
      return encodeRle4(img);
    case Codec.lz4:
      return lz4Compress(img.data);
    case Codec.lz4Rle:
      return lz4Compress(encodeRle4(img));
  }
}

export function decodePixels(
  data: Uint8Array,
  codec: number,
  width: number,
  height: number,
): Image4 {
  const size = stride4(width) * height;
  switch (codec) {
    case Codec.raw4:
      if (data.length !== size)
        throw new RangeError(`RAW4 needs ${size} bytes`);
      return { width, height, data };
    case Codec.rle4:
      return decodeRle4(data, width, height);
    case Codec.lz4: {
      const raw = lz4Decompress(data, size);
      if (raw.length !== size)
        throw new RangeError(`LZ4 gave ${raw.length} of ${size} bytes`);
      return { width, height, data: raw };
    }
    case Codec.lz4Rle:
      // RLE4 never takes more than one byte per pixel.
      return decodeRle4(lz4Decompress(data, width * height), width, height);
    default:
      throw new RangeError(`unknown codec ${codec}`);
  }
}

export interface Encoded {
  codec: CodecId;
  data: Uint8Array;
}

/**
 * Encodes with every codec in `codecs` (RAW4 is always allowed) and returns
 * the smallest. Ties go to the cheaper codec to decode.
 */
export function encodeSmallest(
  img: Image4,
  codecs: Iterable<CodecId> = [Codec.raw4, Codec.rle4, Codec.lz4, Codec.lz4Rle],
): Encoded {
  let best: Encoded = { codec: Codec.raw4, data: img.data };
  const allowed = new Set(codecs);
  let rle: Uint8Array | undefined;
  for (const codec of [Codec.rle4, Codec.lz4, Codec.lz4Rle] as const) {
    if (!allowed.has(codec)) continue;
    let data: Uint8Array;
    if (codec === Codec.rle4) data = rle ??= encodeRle4(img);
    else if (codec === Codec.lz4Rle)
      data = lz4Compress((rle ??= encodeRle4(img)));
    else data = encodePixels(img, codec);
    if (data.length < best.data.length) best = { codec, data };
  }
  return best;
}

/** XOR of two equally sized RAW4 frames: the payload of a delta frame. */
export function xorFrames(prev: Image4, next: Image4): Image4 {
  if (prev.width !== next.width || prev.height !== next.height)
    throw new RangeError('delta frames need equal sizes');
  const data = new Uint8Array(next.data.length);
  for (let i = 0; i < data.length; i++) data[i] = prev.data[i]! ^ next.data[i]!;
  return { width: next.width, height: next.height, data };
}

/** Resource type 1: `w u16, h u16, bpp u8, codec u8, data…`. */
export function imageResource(
  img: Image4,
  encoded: Encoded = encodeSmallest(img),
) {
  return new ByteWriter(6 + encoded.data.length)
    .u16(img.width)
    .u16(img.height)
    .u8(4)
    .u8(encoded.codec)
    .bytes(encoded.data)
    .finish();
}

export interface AnimationFrame {
  image: Image4;
  durationMs: number;
}

export interface AnimationOptions {
  codec?: CodecId;
  /** Allow XOR delta frames (cap `deltaFrames`); default true. */
  delta?: boolean;
}

/**
 * Resource type 2: `w u16, h u16, frames u16, codec u8,
 * {duration_ms u16, kind u8, size u32, data…}…`. Each frame is stored as a key
 * frame or an XOR delta against the previous one, whichever is smaller.
 */
export function animationResource(
  frames: AnimationFrame[],
  opts: AnimationOptions = {},
) {
  if (!frames.length) throw new RangeError('an animation needs frames');
  const { width, height } = frames[0]!.image;
  const codec = opts.codec ?? Codec.lz4;
  const w = new ByteWriter()
    .u16(width)
    .u16(height)
    .u16(frames.length)
    .u8(codec);
  let prev: Image4 | undefined;
  for (const f of frames) {
    if (f.image.width !== width || f.image.height !== height)
      throw new RangeError('animation frames need equal sizes');
    let kind = 0;
    let data = encodePixels(f.image, codec);
    if (prev && opts.delta !== false) {
      const delta = encodePixels(xorFrames(prev, f.image), codec);
      if (delta.length < data.length) {
        kind = 1;
        data = delta;
      }
    }
    w.u16(f.durationMs).u8(kind).u32(data.length).bytes(data);
    prev = f.image;
  }
  return w.finish();
}
