/** A 4 bpp image: `data` is RAW4 (stride `ceil(w/2)`, high nibble = left pixel). */
export interface Image4 {
  width: number;
  height: number;
  data: Uint8Array;
}

/** Anything shaped like a canvas `ImageData` (RGBA) or a greyscale buffer. */
export interface PixelSource {
  width: number;
  height: number;
  /** RGBA (4 bytes per pixel) or greyscale (1 byte per pixel), 0–255. */
  data: ArrayLike<number>;
}

export type Dither = 'none' | 'floyd-steinberg' | 'ordered';

export interface ToRaw4Options {
  dither?: Dither;
  /** Reverse the levels (dark pixels lit). Default false: light = lit. */
  invert?: boolean;
}

export const stride4 = (width: number) => (width + 1) >> 1;

export function getPixel4(img: Image4, x: number, y: number): number {
  const b = img.data[y * stride4(img.width) + (x >> 1)]!;
  return x & 1 ? b & 15 : b >> 4;
}

/** Packs one level (0–15) per pixel into RAW4. */
export function packRaw4(
  width: number,
  height: number,
  levels: ArrayLike<number>,
): Image4 {
  const stride = stride4(width);
  const data = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const v = levels[y * width + x]! & 15;
      data[y * stride + (x >> 1)]! |= x & 1 ? v : v << 4;
    }
  return { width, height, data };
}

/** One level (0–15) per pixel, row-major, no padding. */
export function unpackRaw4(img: Image4): Uint8Array {
  const out = new Uint8Array(img.width * img.height);
  for (let y = 0; y < img.height; y++)
    for (let x = 0; x < img.width; x++)
      out[y * img.width + x] = getPixel4(img, x, y);
  return out;
}

const BAYER4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];

/**
 * Converts RGBA or greyscale pixels to RAW4. Luma uses Rec. 601 weights and is
 * multiplied by alpha, so transparent pixels become 0 (off).
 */
export function toRaw4(src: PixelSource, opts: ToRaw4Options = {}): Image4 {
  const { width: w, height: h, data } = src;
  const n = w * h;
  const rgba = data.length === n * 4;
  if (!rgba && data.length !== n)
    throw new RangeError(
      `expected ${n} or ${n * 4} values, got ${data.length}`,
    );
  const luma = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let v: number;
    if (rgba) {
      const p = i * 4;
      v =
        (0.299 * data[p]! + 0.587 * data[p + 1]! + 0.114 * data[p + 2]!) *
        (data[p + 3]! / 255);
    } else v = data[i]!;
    luma[i] = opts.invert ? 255 - v : v;
  }

  const levels = new Uint8Array(n);
  const dither = opts.dither ?? 'none';
  const q = (v: number) =>
    Math.min(15, Math.max(0, Math.round((v * 15) / 255)));
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (dither === 'ordered') {
        const t = (BAYER4[(y & 3) * 4 + (x & 3)]! + 0.5) / 16 - 0.5;
        levels[i] = q(luma[i]! + t * 17);
      } else if (dither === 'floyd-steinberg') {
        const old = luma[i]!;
        const lv = q(old);
        levels[i] = lv;
        const err = old - lv * 17;
        if (x + 1 < w) luma[i + 1]! += (err * 7) / 16;
        if (y + 1 < h) {
          if (x > 0) luma[i + w - 1]! += (err * 3) / 16;
          luma[i + w]! += (err * 5) / 16;
          if (x + 1 < w) luma[i + w + 1]! += err / 16;
        }
      } else levels[i] = q(luma[i]!);
    }
  return packRaw4(w, h, levels);
}
