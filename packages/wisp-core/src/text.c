/* Wisp core: text with Wisp bitmap fonts. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/text.h"

uint32_t wisp_utf8_next(const uint8_t *s, size_t len, size_t *pos) {
    size_t i = *pos;
    uint8_t c = s[i];
    unsigned n = c < 0x80 ? 0 : (c & 0xe0) == 0xc0 ? 1 : (c & 0xf0) == 0xe0 ? 2 : (c & 0xf8) == 0xf0 ? 3 : 4;
    static const uint32_t min[4] = {0, 0x80, 0x800, 0x10000};
    *pos = i + 1;
    if (n == 0) return c;
    if (n == 4 || len - i - 1 < n) return 0xFFFD;
    uint32_t cp = c & (0x3fu >> n);
    for (unsigned k = 1; k <= n; k++) {
        if ((s[i + k] & 0xc0) != 0x80) return 0xFFFD;
        cp = cp << 6 | (s[i + k] & 0x3fu);
    }
    *pos = i + 1 + n;
    if (cp < min[n] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0xFFFD;
    return cp;
}

static bool glyph(const wisp_font *f, uint32_t cp, wisp_glyph *g) {
    if (wisp_font_glyph(f, cp, g)) return true;
    if (cp == '\n' || cp == '\r') return false;
    return wisp_font_glyph(f, 0xFFFD, g) || wisp_font_glyph(f, '?', g);
}

typedef struct {
    wisp_display *d;
    wisp_layer *l;
    const wisp_font *f;
    uint8_t scale[16];
    int32_t x, y, lh, pen, line, max_w, maxw, lw;
    wisp_rect box;
} layout;

static void draw_glyph(layout *t, const wisp_glyph *g) {
    wisp_layer *l = t->l;
    int32_t gx = t->x + t->pen + g->x_off, gy = t->y + t->line * t->lh + t->f->baseline + g->y_off;
    size_t stride = (g->w + 1u) / 2u;
    for (int32_t r = 0; r < g->h; r++) {
        int32_t y = gy + r;
        if (y < 0 || y >= l->ch) continue;
        uint8_t *row = l->buf + (size_t)y * l->stride;
        const uint8_t *src = g->bits + (size_t)r * stride;
        for (int32_t c = 0; c < g->w; c++) {
            int32_t x = gx + c;
            uint8_t v = t->scale[wisp_px_get(src, c)];
            if (v && x >= 0 && x < l->cw) wisp_px_set(row, x, v);
        }
    }
    if (g->w && g->h) {
        wisp_rect b = {gx, gy, gx + g->w, gy + g->h};
        if (t->box.x0 >= t->box.x1) t->box = b;
        else {
            if (b.x0 < t->box.x0) t->box.x0 = b.x0;
            if (b.y0 < t->box.y0) t->box.y0 = b.y0;
            if (b.x1 > t->box.x1) t->box.x1 = b.x1;
            if (b.y1 > t->box.y1) t->box.y1 = b.y1;
        }
    }
}

static int32_t advance_of(const wisp_font *f, uint32_t cp) {
    wisp_glyph g;
    return glyph(f, cp, &g) ? g.advance : 0;
}

int wisp_text_draw(wisp_display *d, uint8_t layer, const wisp_font *f, uint8_t value, int32_t x, int32_t y,
                   uint16_t max_w, uint16_t line_h, const uint8_t *s, size_t len, wisp_display_text_rsp_t *out) {
    layout t = {d, wisp_display_layer(d, layer), f, {0}, x, y, line_h ? line_h : f->line_h, 0, 0, max_w, 0, 0, {0, 0, 0, 0}};
    memset(out, 0, sizeof *out);
    if (!t.l) return WISP_ERR_NO_SUCH_ID;
    for (unsigned v = 0; v < 16; v++) t.scale[v] = (uint8_t)((v * (value & 0xfu) + 7u) / 15u);
    size_t pos = 0;
    uint32_t chars = 0;
    bool any = false, wrapped = false, stopped = false;
#define NEWLINE() (t.lw > t.maxw ? t.maxw = t.lw : 0, t.pen = 0, t.lw = 0, t.line++)
    while (pos < len) {
        if (t.y + t.line * t.lh >= t.l->ch) { /* below the content: stop */
            stopped = true;
            break;
        }
        size_t p = pos;
        uint32_t cp = wisp_utf8_next(s, len, &p);
        if (cp == '\n') {
            NEWLINE();
            wrapped = false;
            pos = p;
            chars++;
            continue;
        }
        if (cp == ' ') {
            if (!(wrapped && t.pen == 0)) t.pen += advance_of(f, cp);
            pos = p;
            chars++;
            continue;
        }
        /* a word: measure it */
        int32_t ww = 0;
        for (size_t q = pos; q < len;) {
            size_t q2 = q;
            uint32_t c = wisp_utf8_next(s, len, &q2);
            if (c == ' ' || c == '\n') break;
            ww += advance_of(f, c);
            q = q2;
        }
        if (max_w && t.pen > 0 && t.pen + ww > max_w) {
            NEWLINE();
            wrapped = true;
            continue;
        }
        wrapped = false;
        while (pos < len) {
            if (t.y + t.line * t.lh >= t.l->ch) {
                stopped = true;
                break;
            }
            size_t q = pos;
            uint32_t c = wisp_utf8_next(s, len, &q);
            if (c == ' ' || c == '\n') break;
            wisp_glyph g;
            bool has = glyph(f, c, &g);
            if (has && max_w && t.pen > 0 && t.pen + g.advance > max_w) {
                NEWLINE();
                continue;
            }
            if (has) {
                draw_glyph(&t, &g);
                t.pen += g.advance;
                t.lw = t.pen;
            }
            any = true;
            pos = q;
            chars++;
        }
    }
    if (t.lw > t.maxw) t.maxw = t.lw;
    int32_t lines = stopped ? t.line : t.line + 1;
    out->w = (uint16_t)(t.maxw > 0xffff ? 0xffff : t.maxw);
    out->h = (uint16_t)((any || t.line) ? lines * t.lh : 0);
    out->chars_drawn = (uint16_t)(chars > 0xffff ? 0xffff : chars);
    if (t.box.x0 < t.box.x1)
        wisp_display_damage(d, t.l, t.box.x0, t.box.y0, t.box.x1 - t.box.x0, t.box.y1 - t.box.y0);
    return 0;
#undef NEWLINE
}
