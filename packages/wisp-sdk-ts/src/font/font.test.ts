import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseBdf } from './bdf.ts';
import { fontResource, trimGlyph } from './font.ts';

const BDF = `STARTFONT 2.1
FONT -test-tiny
SIZE 8 72 72
FONTBOUNDINGBOX 4 6 0 -1
STARTPROPERTIES 2
FONT_ASCENT 5
FONT_DESCENT 1
ENDPROPERTIES
CHARS 2
STARTCHAR A
ENCODING 65
DWIDTH 5 0
BBX 4 6 0 -1
BITMAP
00
60
90
F0
90
00
ENDCHAR
STARTCHAR space
ENCODING 32
DWIDTH 5 0
BBX 4 6 0 -1
BITMAP
00
00
00
00
00
00
ENDCHAR
ENDFONT
`;

test('BDF: metrics, trimmed bitmaps, baseline-relative tops', () => {
  const f = parseBdf(BDF);
  assert.equal(f.lineHeight, 6);
  assert.equal(f.baseline, 5);
  const a = f.glyphs.find((g) => g.codepoint === 65)!;
  // rows 1–4 lit, columns 0–3: bitmap top = baseline - 5 + 1
  assert.deepEqual(
    [a.width, a.height, a.xOff, a.yOff, a.advance],
    [4, 4, 0, -4, 5],
  );
  assert.deepEqual([...a.levels.subarray(0, 4)], [0, 15, 15, 0]);
  const sp = f.glyphs.find((g) => g.codepoint === 32)!;
  assert.deepEqual([sp.width, sp.height, sp.advance], [0, 0, 5]);
  assert.equal(parseBdf(BDF, { filter: (c) => c !== 32 }).glyphs.length, 1);
});

test('font resource layout: header, sorted table, RAW4 bitmaps', () => {
  const bytes = fontResource(parseBdf(BDF, { level: 9 }));
  const v = new DataView(bytes.buffer, bytes.byteOffset);
  assert.deepEqual([bytes[0], bytes[1], v.getUint16(2, true)], [6, 5, 2]);
  // space (U+0020) sorts first, then 'A' whose bitmap starts at offset 0 (space has none)
  assert.equal(v.getUint32(4, true), 32);
  const a = 4 + 13;
  assert.equal(v.getUint32(a, true), 65);
  assert.deepEqual(
    [
      bytes[a + 4],
      bytes[a + 5],
      v.getInt8(a + 6),
      v.getInt8(a + 7),
      bytes[a + 8],
    ],
    [4, 4, 0, -4, 5],
  );
  assert.equal(v.getUint32(a + 9, true), 0);
  const bits = bytes.subarray(4 + 13 * 2);
  assert.equal(bits.length, 2 * 4);
  assert.deepEqual([...bits.subarray(0, 2)], [0x09, 0x90]);
  assert.throws(
    () => fontResource({ lineHeight: 0, baseline: 0, glyphs: [] }),
    RangeError,
  );
  assert.equal(
    trimGlyph({
      codepoint: 1,
      width: 2,
      height: 2,
      xOff: 0,
      yOff: 0,
      advance: 1,
      levels: new Uint8Array(4),
    }).width,
    0,
  );
});
