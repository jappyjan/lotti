import { ByteWriter } from '../protocol/bytes.ts';
import { packRaw4, stride4 } from '../image/raw4.ts';

/** One glyph: coverage 0–15 per pixel, row-major, `width × height`. */
export interface Glyph {
  codepoint: number;
  width: number;
  height: number;
  /** Bitmap left edge relative to the pen. */
  xOff: number;
  /** Bitmap top relative to the baseline (down is positive, so usually negative). */
  yOff: number;
  advance: number;
  levels: Uint8Array;
}

export interface BitmapFont {
  lineHeight: number;
  /** Baseline, from the top of a line. */
  baseline: number;
  glyphs: Glyph[];
}

/** Shrinks a glyph's bitmap to its lit pixels (empty glyphs become 0×0). */
export function trimGlyph(g: Glyph): Glyph {
  let x0 = g.width,
    y0 = g.height,
    x1 = 0,
    y1 = 0;
  for (let y = 0; y < g.height; y++)
    for (let x = 0; x < g.width; x++)
      if (g.levels[y * g.width + x]) {
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x >= x1) x1 = x + 1;
        if (y >= y1) y1 = y + 1;
      }
  if (x1 <= x0)
    return {
      ...g,
      width: 0,
      height: 0,
      xOff: 0,
      yOff: 0,
      levels: new Uint8Array(0),
    };
  const w = x1 - x0,
    h = y1 - y0,
    levels = new Uint8Array(w * h);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++)
      levels[y * w + x] = g.levels[(y0 + y) * g.width + x0 + x]!;
  return {
    ...g,
    width: w,
    height: h,
    xOff: g.xOff + x0,
    yOff: g.yOff + y0,
    levels,
  };
}

/**
 * Resource type 3, the Wisp bitmap font: `line_h u8, baseline u8, glyphs u16,
 * {codepoint u32, w u8, h u8, x_off i8, y_off i8, advance u8, offset u32}…`
 * sorted by codepoint, then RAW4 glyph bitmaps (`offset` counts from their start).
 */
export function fontResource(font: BitmapFont): Uint8Array {
  const glyphs = [...font.glyphs].sort((a, b) => a.codepoint - b.codepoint);
  for (let i = 1; i < glyphs.length; i++)
    if (glyphs[i]!.codepoint === glyphs[i - 1]!.codepoint)
      throw new RangeError(
        `duplicate glyph U+${glyphs[i]!.codepoint.toString(16)}`,
      );
  const check = (v: number, lo: number, hi: number, what: string) => {
    if (!Number.isInteger(v) || v < lo || v > hi)
      throw new RangeError(`${what} ${v} out of range`);
  };
  check(font.lineHeight, 1, 255, 'line height');
  check(font.baseline, 0, 255, 'baseline');
  const w = new ByteWriter(4 + 13 * glyphs.length)
    .u8(font.lineHeight)
    .u8(font.baseline)
    .u16(glyphs.length);
  const bitmaps: Uint8Array[] = [];
  let offset = 0;
  for (const g of glyphs) {
    check(g.width, 0, 255, 'glyph width');
    check(g.height, 0, 255, 'glyph height');
    check(g.xOff, -128, 127, 'x_off');
    check(g.yOff, -128, 127, 'y_off');
    check(g.advance, 0, 255, 'advance');
    w.u32(g.codepoint)
      .u8(g.width)
      .u8(g.height)
      .i8(g.xOff)
      .i8(g.yOff)
      .u8(g.advance)
      .u32(offset);
    const bits = packRaw4(g.width, g.height, g.levels).data;
    bitmaps.push(bits);
    offset += stride4(g.width) * g.height;
  }
  for (const b of bitmaps) w.bytes(b);
  return w.finish();
}
