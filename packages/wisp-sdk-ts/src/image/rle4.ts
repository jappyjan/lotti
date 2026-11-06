import { stride4, type Image4 } from './raw4.ts';

/**
 * RLE4: one byte per run, high nibble = run length − 1 (1–16), low nibble =
 * value. Runs cover the `w × h` pixels in row order and may cross rows; the
 * RAW4 padding nibble of odd-width rows is not encoded.
 */
export function encodeRle4(img: Image4): Uint8Array {
  const { width: w, height: h, data } = img;
  const stride = stride4(w);
  const out: number[] = [];
  let value = -1;
  let run = 0;
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const b = data[y * stride + (x >> 1)]!;
      const v = x & 1 ? b & 15 : b >> 4;
      if (v === value && run < 16) run++;
      else {
        if (run) out.push(((run - 1) << 4) | value);
        value = v;
        run = 1;
      }
    }
  if (run) out.push(((run - 1) << 4) | value);
  return Uint8Array.from(out);
}

export function decodeRle4(
  rle: Uint8Array,
  width: number,
  height: number,
): Image4 {
  const stride = stride4(width);
  const data = new Uint8Array(stride * height);
  const total = width * height;
  let p = 0;
  for (const b of rle) {
    const v = b & 15;
    for (let k = (b >> 4) + 1; k > 0; k--, p++) {
      if (p >= total) throw new RangeError('RLE4 data longer than the image');
      const y = Math.floor(p / width);
      const x = p - y * width;
      data[y * stride + (x >> 1)]! |= x & 1 ? v : v << 4;
    }
  }
  if (p !== total)
    throw new RangeError(`RLE4 data covers ${p} of ${total} pixels`);
  return { width, height, data };
}
