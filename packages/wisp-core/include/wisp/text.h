/* Wisp core: text with Wisp bitmap fonts. MIT License, Wisp contributors.
 *
 * Layout: (x, y) is the top-left of the first line; lines are line_h apart
 * (0 = the font's line_h). A glyph's bitmap goes at
 * (pen_x + x_off, line_top + baseline + y_off), then the pen moves by
 * `advance`. Glyph pixels are coverage 0–15, drawn as value * coverage / 15
 * with "over" (coverage 0 leaves the layer as it is). With max_w, lines wrap
 * at spaces, and words wider than max_w break between characters; '\n'
 * always breaks. Layout stops at the first line that starts below the
 * layer's content, so chars_drawn tells how much fit (paging). */
#ifndef WISP_TEXT_H
#define WISP_TEXT_H

#include "display.h"
#include "resource.h"

/* Next code point of UTF-8 text at *pos (invalid bytes give U+FFFD). */
uint32_t wisp_utf8_next(const uint8_t *s, size_t len, size_t *pos);

/* Returns 0 or a WISP_ERR_* code; fills out (w, h, chars_drawn). */
int wisp_text_draw(wisp_display *d, uint8_t layer, const wisp_font *f, uint8_t value, int32_t x, int32_t y,
                   uint16_t max_w, uint16_t line_h, const uint8_t *text, size_t len, wisp_display_text_rsp_t *out);

#endif
