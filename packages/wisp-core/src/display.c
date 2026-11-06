/* Wisp core: layers and the compositor. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/display.h"

static inline int32_t min32(int32_t a, int32_t b) { return a < b ? a : b; }
static inline int32_t max32(int32_t a, int32_t b) { return a > b ? a : b; }
static inline bool rect_empty(wisp_rect r) { return r.x0 >= r.x1 || r.y0 >= r.y1; }
static inline int64_t rect_area(wisp_rect r) { return (int64_t)(r.x1 - r.x0) * (r.y1 - r.y0); }
static inline wisp_rect rect_union(wisp_rect a, wisp_rect b) {
    return (wisp_rect){min32(a.x0, b.x0), min32(a.y0, b.y0), max32(a.x1, b.x1), max32(a.y1, b.y1)};
}
static inline wisp_rect rect_isect(wisp_rect a, wisp_rect b) {
    return (wisp_rect){max32(a.x0, b.x0), max32(a.y0, b.y0), min32(a.x1, b.x1), min32(a.y1, b.y1)};
}
/* Overlapping or edge-adjacent. */
static inline bool rect_touch(wisp_rect a, wisp_rect b) {
    return a.x0 <= b.x1 && b.x0 <= a.x1 && a.y0 <= b.y1 && b.y0 <= a.y1;
}

size_t wisp_display_mem(uint16_t width, uint16_t height, uint8_t max_layers, uint16_t strip_rows) {
    (void)height;
    size_t bw = (width + 1u) / 2u;
    size_t n = sizeof(wisp_layer) * max_layers + max_layers + 256u * max_layers + bw * strip_rows + bw + 16u;
    return (n + 7u) & ~(size_t)7u;
}

void wisp_display_init(wisp_display *d, void *mem, uint16_t width, uint16_t height, uint8_t max_layers,
                       uint16_t strip_rows, wisp_pool *pool, wisp_present_fn present, void *ctx) {
    size_t bw = (width + 1u) / 2u;
    memset(d, 0, sizeof *d);
    memset(mem, 0, wisp_display_mem(width, height, max_layers, strip_rows));
    d->width = (uint16_t)(width & ~1u); /* the compositor works on whole bytes */
    d->height = height;
    d->max_layers = max_layers;
    d->strip_rows = strip_rows ? strip_rows : 1;
    d->layers = mem;
    d->order = (uint8_t *)(d->layers + max_layers);
    d->alut = d->order + max_layers;
    d->strip = d->alut + 256u * max_layers;
    d->tmp = d->strip + bw * d->strip_rows;
    d->pool = pool;
    d->sink = &d->dirty;
    d->present = present;
    d->ctx = ctx;
}

wisp_layer *wisp_display_layer(wisp_display *d, uint8_t id) {
    return id < d->max_layers && d->layers[id].used ? &d->layers[id] : NULL;
}

/* ---- damage ---- */

void wisp_dirty_add(wisp_dirty *dl, wisp_rect r, uint16_t width, uint16_t height) {
    r = rect_isect(r, (wisp_rect){0, 0, width, height});
    if (rect_empty(r)) return;
    r.x0 &= ~1;
    r.x1 = (r.x1 + 1) & ~1;
    for (;;) {
        bool merged = false;
        for (unsigned i = 0; i < dl->n; i++) {
            if (!rect_touch(dl->r[i], r)) continue;
            r = rect_union(r, dl->r[i]);
            dl->r[i] = dl->r[--dl->n];
            merged = true;
            break;
        }
        if (merged) continue;
        if (dl->n < WISP_DIRTY_MAX) break;
        /* full: fold into the rect whose union grows the least */
        unsigned best = 0;
        int64_t grow = INT64_MAX;
        for (unsigned i = 0; i < dl->n; i++) {
            int64_t g = rect_area(rect_union(r, dl->r[i])) - rect_area(dl->r[i]);
            if (g < grow) grow = g, best = i;
        }
        r = rect_union(r, dl->r[best]);
        dl->r[best] = dl->r[--dl->n];
    }
    dl->r[dl->n++] = r;
}

static wisp_rect view_rect(const wisp_layer *l) { return (wisp_rect){l->x, l->y, l->x + l->w, l->y + l->h}; }

static void damage_view(wisp_display *d, const wisp_layer *l) {
    if (l->visible) wisp_dirty_add(d->sink, view_rect(l), d->width, d->height);
}

void wisp_display_damage(wisp_display *d, const wisp_layer *l, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!l->visible || w <= 0 || h <= 0) return;
    int32_t ox = l->x - l->sx, oy = l->y - l->sy;
    wisp_rect r = {x + ox, y + oy, x + w + ox, y + h + oy};
    wisp_dirty_add(d->sink, rect_isect(r, view_rect(l)), d->width, d->height);
}

void wisp_display_invalidate(wisp_display *d) {
    wisp_dirty_add(d->sink, (wisp_rect){0, 0, d->width, d->height}, d->width, d->height);
}

/* ---- layers ---- */

int wisp_display_layer_set(wisp_display *d, const wisp_display_layer_set_req_t *m) {
    if (m->layer >= d->max_layers) return WISP_ERR_NO_MEMORY;
    uint8_t blend = (m->flags >> 1) & 3u;
    if (blend > WISP_BLEND_ADD) return WISP_ERR_BAD_PAYLOAD;
    wisp_layer *l = &d->layers[m->layer];
    uint16_t cw = m->content_w ? m->content_w : m->w, ch = m->content_h ? m->content_h : m->h;
    if (l->used) damage_view(d, l);
    if (!l->used || cw != l->cw || ch != l->ch) {
        size_t stride = (cw + 1u) / 2u, size = stride * ch;
        if (l->used) wisp_pool_free(d->pool, l->buf);
        l->used = false;
        if (!wisp_pool_alloc(d->pool, size, (void **)&l->buf)) return WISP_ERR_NO_MEMORY;
        memset(l->buf, 0, size);
        l->cw = cw;
        l->ch = ch;
        l->stride = stride;
        l->used = true;
    }
    l->visible = m->flags & WISP_LAYER_VISIBLE;
    l->z = m->z;
    l->blend = blend;
    l->alpha = m->alpha > 15 ? 15 : m->alpha;
    l->x = m->x;
    l->y = m->y;
    l->w = m->w;
    l->h = m->h;
    l->sx = m->scroll_x;
    l->sy = m->scroll_y;
    damage_view(d, l);
    return 0;
}

int wisp_display_layer_del(wisp_display *d, uint8_t id) {
    wisp_layer *l = wisp_display_layer(d, id);
    if (!l) return WISP_ERR_NO_SUCH_ID;
    damage_view(d, l);
    wisp_pool_free(d->pool, l->buf);
    memset(l, 0, sizeof *l);
    return 0;
}

void wisp_display_clear_all(wisp_display *d) {
    for (uint8_t i = 0; i < d->max_layers; i++)
        if (d->layers[i].used) wisp_display_layer_del(d, i);
}

int32_t wisp_display_prop(const wisp_layer *l, uint8_t prop) {
    switch (prop) {
    case WISP_PROP_X: return l->x;
    case WISP_PROP_Y: return l->y;
    case WISP_PROP_ALPHA: return l->alpha;
    case WISP_PROP_SCROLL_X: return l->sx;
    case WISP_PROP_SCROLL_Y: return l->sy;
    default: return 0;
    }
}

void wisp_display_set_prop(wisp_display *d, wisp_layer *l, uint8_t prop, int32_t v) {
    if (wisp_display_prop(l, prop) == v) return;
    int16_t s = (int16_t)(v < INT16_MIN ? INT16_MIN : v > INT16_MAX ? INT16_MAX : v);
    damage_view(d, l);
    switch (prop) {
    case WISP_PROP_X: l->x = s; break;
    case WISP_PROP_Y: l->y = s; break;
    case WISP_PROP_ALPHA: l->alpha = (uint8_t)(s < 0 ? 0 : s > 15 ? 15 : s); break;
    case WISP_PROP_SCROLL_X: l->sx = s; break;
    case WISP_PROP_SCROLL_Y: l->sy = s; break;
    default: break;
    }
    damage_view(d, l);
}

/* ---- drawing into content buffers ---- */

/* Clips a w×h rect at (x, y) to the content; false when nothing is left. */
static bool clip(const wisp_layer *l, int32_t *x, int32_t *y, int32_t *w, int32_t *h, int32_t *sx, int32_t *sy) {
    if (*x < 0) *w += *x, *sx -= *x, *x = 0;
    if (*y < 0) *h += *y, *sy -= *y, *y = 0;
    if (*x + *w > l->cw) *w = l->cw - *x;
    if (*y + *h > l->ch) *h = l->ch - *y;
    return *w > 0 && *h > 0;
}

int wisp_display_fill(wisp_display *d, uint8_t layer, uint8_t value, int32_t x, int32_t y, int32_t w, int32_t h) {
    wisp_layer *l = wisp_display_layer(d, layer);
    if (!l) return WISP_ERR_NO_SUCH_ID;
    int32_t sx = 0, sy = 0;
    if (!clip(l, &x, &y, &w, &h, &sx, &sy)) return 0;
    uint8_t v = value & 0xfu, vv = (uint8_t)(v * 0x11u);
    for (int32_t r = 0; r < h; r++) {
        uint8_t *row = l->buf + (size_t)(y + r) * l->stride;
        int32_t a = x, b = x + w;
        if (a & 1) wisp_px_set(row, a++, v);
        if (a < b && (b & 1)) wisp_px_set(row, --b, v);
        if (a < b) memset(row + a / 2, vv, (size_t)(b - a) / 2u);
    }
    wisp_display_damage(d, l, x, y, w, h);
    return 0;
}

/* Mask of the nonzero nibbles of a byte. */
static inline uint8_t nzmask(uint8_t v) { return (uint8_t)(((v & 0xf0u) ? 0xf0u : 0) | ((v & 0x0fu) ? 0x0fu : 0)); }

static void copy_row(uint8_t *dst, int32_t dx, const uint8_t *src, int32_t sx, int32_t n, bool transparent) {
    if ((dx & 1) == (sx & 1)) {
        if (dx & 1) {
            uint8_t v = wisp_px_get(src, sx);
            if (v || !transparent) wisp_px_set(dst, dx, v);
            dx++, sx++, n--;
        }
        int32_t bytes = n / 2;
        uint8_t *o = dst + dx / 2;
        const uint8_t *s = src + sx / 2;
        if (!transparent)
            memcpy(o, s, (size_t)bytes);
        else
            for (int32_t i = 0; i < bytes; i++) {
                uint8_t m = nzmask(s[i]);
                o[i] = (uint8_t)((o[i] & ~m) | (s[i] & m));
            }
        dx += 2 * bytes, sx += 2 * bytes, n -= 2 * bytes;
        if (n) {
            uint8_t v = wisp_px_get(src, sx);
            if (v || !transparent) wisp_px_set(dst, dx, v);
        }
        return;
    }
    for (int32_t i = 0; i < n; i++) {
        uint8_t v = wisp_px_get(src, sx + i);
        if (v || !transparent) wisp_px_set(dst, dx + i, v);
    }
}

int wisp_display_blit(wisp_display *d, uint8_t layer, int32_t x, int32_t y, const uint8_t *src, size_t src_stride,
                      int32_t sx, int32_t sy, int32_t w, int32_t h, bool transparent) {
    wisp_layer *l = wisp_display_layer(d, layer);
    if (!l) return WISP_ERR_NO_SUCH_ID;
    if (!clip(l, &x, &y, &w, &h, &sx, &sy)) return 0;
    for (int32_t r = 0; r < h; r++)
        copy_row(l->buf + (size_t)(y + r) * l->stride, x, src + (size_t)(sy + r) * src_stride, sx, w, transparent);
    wisp_display_damage(d, l, x, y, w, h);
    return 0;
}

int wisp_display_scroll(wisp_display *d, uint8_t layer, int32_t dx, int32_t dy, uint8_t fill) {
    wisp_layer *l = wisp_display_layer(d, layer);
    if (!l) return WISP_ERR_NO_SUCH_ID;
    int32_t cw = l->cw, ch = l->ch;
    uint8_t v = fill & 0xfu;
    size_t stride = l->stride;
    if (dy >= ch || -dy >= ch || dx >= cw || -dx >= cw) {
        wisp_display_fill(d, layer, v, 0, 0, cw, ch);
        return 0;
    }
    if (dy > 0)
        memmove(l->buf + (size_t)dy * stride, l->buf, (size_t)(ch - dy) * stride);
    else if (dy < 0)
        memmove(l->buf, l->buf + (size_t)-dy * stride, (size_t)(ch + dy) * stride);
    if (dx) {
        int32_t y0 = dy > 0 ? dy : 0, y1 = dy < 0 ? ch + dy : ch;
        for (int32_t y = y0; y < y1; y++) {
            uint8_t *row = l->buf + (size_t)y * stride;
            if (!(dx & 1)) {
                size_t k = (size_t)(dx > 0 ? dx : -dx) / 2u;
                if (dx > 0)
                    memmove(row + k, row, stride - k);
                else
                    memmove(row, row + k, stride - k);
                if (cw & 1) row[stride - 1] &= 0xf0u; /* keep the padding nibble 0 */
            } else if (dx > 0) {
                for (int32_t x = cw - 1; x >= dx; x--) wisp_px_set(row, x, wisp_px_get(row, x - dx));
            } else {
                for (int32_t x = 0; x < cw + dx; x++) wisp_px_set(row, x, wisp_px_get(row, x - dx));
            }
        }
    }
    /* uncovered bands */
    struct wisp_display_band {
        int32_t x, y, w, h;
    } bands[2] = {
        {0, dy > 0 ? 0 : ch + dy, cw, dy > 0 ? dy : -dy},
        {dx > 0 ? 0 : cw + dx, 0, dx > 0 ? dx : -dx, ch},
    };
    for (unsigned i = 0; i < 2; i++)
        if (bands[i].w > 0 && bands[i].h > 0) wisp_display_fill(d, layer, v, bands[i].x, bands[i].y, bands[i].w, bands[i].h);
    wisp_display_damage(d, l, 0, 0, cw, ch);
    return 0;
}

/* ---- composition ---- */

static inline uint64_t load_be64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
#if defined(__GNUC__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(v);
#elif defined(__GNUC__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    return v;
#else
    return (uint64_t)p[0] << 56 | (uint64_t)p[1] << 48 | (uint64_t)p[2] << 40 | (uint64_t)p[3] << 32 |
           (uint64_t)p[4] << 24 | (uint64_t)p[5] << 16 | (uint64_t)p[6] << 8 | p[7];
#endif
}
static inline void store_be64(uint8_t *p, uint64_t v) {
#if defined(__GNUC__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    v = __builtin_bswap64(v);
    memcpy(p, &v, 8);
#elif defined(__GNUC__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    memcpy(p, &v, 8);
#else
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (56 - 8 * i));
#endif
}

/* Content pixels of l for canvas pixels [a, b) of content row `row`, packed as canvas
 * bytes starting at a & ~1; nibbles outside [a, b) are 0. off = content x - canvas x. */
static void gather(uint8_t *tmp, const uint8_t *row, int32_t a, int32_t b, int32_t off) {
    int32_t x0 = a & ~1, nb = (((b + 1) & ~1) - x0) >> 1;
    for (int32_t i = 0; i < nb; i += (nb > 1 ? nb - 1 : 1)) {
        int32_t X = x0 + 2 * i;
        uint8_t hi = X >= a && X < b ? wisp_px_get(row, X + off) : 0;
        uint8_t lo = X + 1 >= a && X + 1 < b ? wisp_px_get(row, X + 1 + off) : 0;
        tmp[i] = (uint8_t)(hi << 4 | lo);
    }
    if (nb <= 2) return;
    if (!(off & 1)) {
        memcpy(tmp + 1, row + ((x0 + 2 + off) >> 1), (size_t)(nb - 2));
    } else {
        const uint8_t *s = row + ((x0 + 2 + off) >> 1);
        int32_t i = 1;
        /* eight bytes at a time: the byte stream as a big-endian word, shifted by a nibble */
        for (; i + 8 < nb - 1; i += 8, s += 8) {
            uint64_t v = load_be64(s) << 4 | s[8] >> 4;
            store_be64(tmp + i, v);
        }
        for (; i < nb - 1; i++, s++) tmp[i] = (uint8_t)(s[0] << 4 | s[1] >> 4);
    }
}

static void blend_over(uint8_t *o, const uint8_t *s, size_t n) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t v, d;
        memcpy(&v, s + i, 8);
        if (!v) continue;
        memcpy(&d, o + i, 8);
        uint64_t t = v | v >> 1 | v >> 2 | v >> 3;
        uint64_t m = (t & 0x1111111111111111ull) * 0xfu;
        d = (d & ~m) | (v & m);
        memcpy(o + i, &d, 8);
    }
    for (; i < n; i++) {
        uint8_t m = nzmask(s[i]);
        o[i] = (uint8_t)((o[i] & ~m) | (s[i] & m));
    }
}

#define LANES 0x0f0f0f0f0f0f0f0full
#define HIGH 0x8080808080808080ull

/* Per byte lane (values 0–15): x >= y ? 0xff : 0. */
static inline uint64_t ge_mask(uint64_t x, uint64_t y) { return (((x | HIGH) - y) >> 7 & 0x0101010101010101ull) * 0xffu; }

static inline uint64_t max_lanes(uint64_t x, uint64_t y) {
    uint64_t m = ge_mask(x, y);
    return (x & m) | (y & ~m);
}
static inline uint64_t add_lanes(uint64_t x, uint64_t y) {
    uint64_t s = x + y, m = (((s + 0x7070707070707070ull) & HIGH) >> 7) * 0xffu; /* s >= 16 */
    return (s & ~m) | (LANES & m);
}

static void blend_max(uint8_t *o, const uint8_t *s, size_t n) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t a, b;
        memcpy(&a, o + i, 8);
        memcpy(&b, s + i, 8);
        a = max_lanes(a & LANES, b & LANES) | max_lanes(a >> 4 & LANES, b >> 4 & LANES) << 4;
        memcpy(o + i, &a, 8);
    }
    for (; i < n; i++) {
        uint8_t a = o[i], b = s[i];
        uint8_t hi = (a & 0xf0u) > (b & 0xf0u) ? a & 0xf0u : b & 0xf0u;
        uint8_t lo = (a & 0x0fu) > (b & 0x0fu) ? a & 0x0fu : b & 0x0fu;
        o[i] = (uint8_t)(hi | lo);
    }
}

static void blend_add(uint8_t *o, const uint8_t *s, size_t n) {
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t a, b;
        memcpy(&a, o + i, 8);
        memcpy(&b, s + i, 8);
        a = add_lanes(a & LANES, b & LANES) | add_lanes(a >> 4 & LANES, b >> 4 & LANES) << 4;
        memcpy(o + i, &a, 8);
    }
    for (; i < n; i++) {
        unsigned hi = (o[i] & 0xf0u) + (s[i] & 0xf0u), lo = (o[i] & 0x0fu) + (s[i] & 0x0fu);
        o[i] = (uint8_t)((hi > 0xf0u ? 0xf0u : hi) | (lo > 0x0fu ? 0x0fu : lo));
    }
}

/* Per translucent layer: a table that scales both pixels of a byte by alpha. */
static void build_alut(wisp_display *d, unsigned nl) {
    for (unsigned k = 0; k < nl; k++) {
        const wisp_layer *l = &d->layers[d->order[k]];
        if (l->alpha >= 15) continue;
        uint8_t sc[16], *lut = d->alut + 256u * d->order[k];
        for (unsigned v = 0; v < 16; v++) sc[v] = (uint8_t)((v * l->alpha + 7u) / 15u);
        for (unsigned b = 0; b < 256; b++) lut[b] = (uint8_t)(sc[b >> 4] << 4 | sc[b & 0xfu]);
    }
}

/* Visible layers back to front (z, then id); returns the count. */
static unsigned sort_layers(wisp_display *d) {
    unsigned n = 0;
    for (uint8_t i = 0; i < d->max_layers; i++) {
        const wisp_layer *l = &d->layers[i];
        if (!l->used || !l->visible || !l->alpha || !l->w || !l->h) continue;
        unsigned k = n++;
        while (k && d->layers[d->order[k - 1]].z > l->z) d->order[k] = d->order[k - 1], k--;
        d->order[k] = i;
    }
    return n;
}

static void compose_rows(wisp_display *d, unsigned nl, wisp_rect r, uint8_t *out, size_t stride) {
    size_t bw = (size_t)(r.x1 - r.x0) / 2u;
    for (int32_t y = r.y0; y < r.y1; y++, out += stride) {
        memset(out, 0, bw);
        for (unsigned k = 0; k < nl; k++) {
            const wisp_layer *l = &d->layers[d->order[k]];
            if (y < l->y || y >= l->y + l->h) continue;
            int32_t cy = y - l->y + l->sy;
            if (cy < 0 || cy >= l->ch) continue;
            int32_t off = l->sx - l->x;
            int32_t a = max32(max32(r.x0, l->x), -off), b = min32(min32(r.x1, l->x + l->w), l->cw - off);
            if (a >= b) continue;
            uint8_t *t = d->tmp;
            size_t nb = (size_t)((((b + 1) & ~1) - (a & ~1)) >> 1);
            gather(t, l->buf + (size_t)cy * l->stride, a, b, off);
            if (l->alpha < 15) {
                const uint8_t *lut = d->alut + 256u * d->order[k];
                for (size_t i = 0; i < nb; i++) t[i] = lut[t[i]];
            }
            uint8_t *o = out + ((a & ~1) - r.x0) / 2;
            switch (l->blend) {
            case WISP_BLEND_MAX: blend_max(o, t, nb); break;
            case WISP_BLEND_ADD: blend_add(o, t, nb); break;
            default: blend_over(o, t, nb); break;
            }
        }
    }
    d->px_composed += (uint64_t)(r.x1 - r.x0) * (uint64_t)(r.y1 - r.y0);
}

static wisp_rect canvas_clip(const wisp_display *d, wisp_rect r) {
    r = rect_isect(r, (wisp_rect){0, 0, d->width, d->height});
    r.x0 &= ~1;
    r.x1 = (r.x1 + 1) & ~1;
    return r;
}

void wisp_display_compose(wisp_display *d, wisp_rect r, uint8_t *out, size_t stride) {
    r = canvas_clip(d, r);
    if (rect_empty(r)) return;
    unsigned nl = sort_layers(d);
    build_alut(d, nl);
    compose_rows(d, nl, r, out, stride);
}

uint32_t wisp_display_present(wisp_display *d, wisp_dirty *dl) {
    unsigned nl = sort_layers(d);
    if (dl->n) build_alut(d, nl);
    for (unsigned i = 0; i < dl->n; i++) {
        wisp_rect r = dl->r[i];
        for (int32_t y = r.y0; y < r.y1; y += d->strip_rows) {
            wisp_rect s = {r.x0, y, r.x1, min32(r.y1, y + d->strip_rows)};
            size_t stride = (size_t)(s.x1 - s.x0) / 2u;
            compose_rows(d, nl, s, d->strip, stride);
            if (d->present)
                d->present(d->ctx, (uint16_t)s.x0, (uint16_t)s.y0, (uint16_t)(s.x1 - s.x0), (uint16_t)(s.y1 - s.y0),
                           d->strip, stride);
        }
    }
    dl->n = 0;
    return ++d->frame;
}
