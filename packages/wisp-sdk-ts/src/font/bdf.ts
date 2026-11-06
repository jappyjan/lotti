import { trimGlyph, type BitmapFont, type Glyph } from './font.ts';

export interface BdfOptions {
  /** Which code points to keep. Default: all. */
  filter?: (codepoint: number) => boolean;
  /** Level for set pixels (BDF is 1 bpp). Default 15. */
  level?: number;
  /** Crop each bitmap to its lit pixels. Default true. */
  trim?: boolean;
}

/**
 * Bakes a BDF bitmap font (X11 / Glyph Bitmap Distribution Format 2.1) into
 * a {@link BitmapFont}; pass the result to `fontResource`.
 */
export function parseBdf(text: string, opts: BdfOptions = {}): BitmapFont {
  const level = opts.level ?? 15;
  const lines = text.split(/\r?\n/);
  let ascent: number | undefined,
    descent: number | undefined,
    bbox: number[] | undefined;
  const glyphs: Glyph[] = [];
  for (let i = 0; i < lines.length; i++) {
    const [key, ...args] = lines[i]!.trim().split(/\s+/);
    if (key === 'FONT_ASCENT') ascent = Number(args[0]);
    else if (key === 'FONT_DESCENT') descent = Number(args[0]);
    else if (key === 'FONTBOUNDINGBOX') bbox = args.map(Number);
    else if (key === 'STARTCHAR') {
      let cp = -1,
        advance = 0,
        bbx = [0, 0, 0, 0];
      const rows: string[] = [];
      for (i++; i < lines.length; i++) {
        const [k, ...a] = lines[i]!.trim().split(/\s+/);
        if (k === 'ENCODING') cp = Number(a[0]);
        else if (k === 'DWIDTH') advance = Number(a[0]);
        else if (k === 'BBX') bbx = a.map(Number);
        else if (k === 'BITMAP') {
          for (i++; i < lines.length && lines[i]!.trim() !== 'ENDCHAR'; i++)
            rows.push(lines[i]!.trim());
          break;
        } else if (k === 'ENDCHAR') break;
      }
      if (cp < 0 || (opts.filter && !opts.filter(cp))) continue;
      const [w, h, xo, yo] = bbx as [number, number, number, number];
      const levels = new Uint8Array(w * h);
      for (let y = 0; y < h; y++) {
        const hex = rows[y] ?? '';
        for (let x = 0; x < w; x++) {
          const nib = parseInt(hex[x >> 2] ?? '0', 16);
          if ((nib >> (3 - (x & 3))) & 1) levels[y * w + x] = level;
        }
      }
      // BDF: the bitmap's bottom sits yo above the baseline; Wisp wants its top.
      const g: Glyph = {
        codepoint: cp,
        width: w,
        height: h,
        xOff: xo,
        yOff: -(yo + h),
        advance,
        levels,
      };
      glyphs.push(opts.trim === false ? g : trimGlyph(g));
    }
  }
  if (ascent === undefined || descent === undefined) {
    if (!bbox)
      throw new Error(
        'BDF without FONT_ASCENT/FONT_DESCENT or FONTBOUNDINGBOX',
      );
    descent = -bbox[3]!;
    ascent = bbox[1]! - descent;
  }
  return { lineHeight: ascent + descent, baseline: ascent, glyphs };
}
