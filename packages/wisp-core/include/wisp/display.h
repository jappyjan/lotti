/* Wisp core: layers and the compositor. MIT License, Wisp contributors.
 *
 * Each layer owns a 4 bpp content buffer (from a wisp_pool) and shows the
 * part of it at (scroll_x, scroll_y) in its view rect on the canvas. Draw
 * operations write into content buffers and record damage in canvas
 * coordinates; COMMIT composes only the damaged rects, back to front by z,
 * in strips of whole rows, and hands each strip to present(). Composition
 * works on packed bytes (two pixels each), with 64-bit SWAR for the common
 * "over" blend. Value 0 is transparent and the identity of every blend. */
#ifndef WISP_DISPLAY_H
#define WISP_DISPLAY_H

#include "msgs.h"
#include "pool.h"

#define WISP_DIRTY_MAX 16u

enum { WISP_BLEND_OVER = 0, WISP_BLEND_MAX = 1, WISP_BLEND_ADD = 2 };
enum { WISP_LAYER_VISIBLE = 1 };
enum { WISP_PROP_X, WISP_PROP_Y, WISP_PROP_ALPHA, WISP_PROP_SCROLL_X, WISP_PROP_SCROLL_Y };

/* Half-open: [x0, x1) × [y0, y1). */
typedef struct {
    int32_t x0, y0, x1, y1;
} wisp_rect;

typedef struct {
    wisp_rect r[WISP_DIRTY_MAX];
    uint8_t n;
} wisp_dirty;

typedef struct {
    bool used, visible;
    uint8_t z, blend, alpha;
    int16_t x, y, sx, sy;
    uint16_t w, h, cw, ch;
    size_t stride;
    uint8_t *buf; /* pool block, stride * ch bytes */
} wisp_layer;

/* A strip of composed rows: x and w are even, px holds h rows of w/2 bytes at `stride`. */
typedef void (*wisp_present_fn)(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px,
                                size_t stride);

typedef struct {
    uint16_t width, height;
    uint8_t max_layers;
    uint16_t strip_rows;
    wisp_layer *layers;
    uint8_t *order, *alut, *strip, *tmp;
    wisp_pool *pool;
    wisp_dirty dirty; /* pending until COMMIT */
    wisp_dirty *sink; /* where damage goes: &dirty, or an auto-commit list */
    wisp_present_fn present;
    void *ctx;
    uint32_t frame;
    uint64_t px_composed;
} wisp_display;

/* Memory wisp_display_init needs for its tables and buffers. */
size_t wisp_display_mem(uint16_t width, uint16_t height, uint8_t max_layers, uint16_t strip_rows);
void wisp_display_init(wisp_display *d, void *mem, uint16_t width, uint16_t height, uint8_t max_layers,
                       uint16_t strip_rows, wisp_pool *pool, wisp_present_fn present, void *ctx);

/* Operations return 0 or a protocol error code (WISP_ERR_*). */
wisp_layer *wisp_display_layer(wisp_display *d, uint8_t id);
int wisp_display_layer_set(wisp_display *d, const wisp_display_layer_set_req_t *m);
int wisp_display_layer_del(wisp_display *d, uint8_t id);
void wisp_display_clear_all(wisp_display *d);
int wisp_display_fill(wisp_display *d, uint8_t layer, uint8_t value, int32_t x, int32_t y, int32_t w, int32_t h);
/* Copies w×h pixels of a 4 bpp image (row stride src_stride) from (sx, sy) to content (x, y).
 * transparent: source 0 leaves the content as it is. */
int wisp_display_blit(wisp_display *d, uint8_t layer, int32_t x, int32_t y, const uint8_t *src, size_t src_stride,
                      int32_t sx, int32_t sy, int32_t w, int32_t h, bool transparent);
int wisp_display_scroll(wisp_display *d, uint8_t layer, int32_t dx, int32_t dy, uint8_t fill);
/* Tween targets. */
int32_t wisp_display_prop(const wisp_layer *l, uint8_t prop);
void wisp_display_set_prop(wisp_display *d, wisp_layer *l, uint8_t prop, int32_t v);

/* Damage, in content coordinates of a layer, or in canvas coordinates. */
void wisp_display_damage(wisp_display *d, const wisp_layer *l, int32_t x, int32_t y, int32_t w, int32_t h);
void wisp_dirty_add(wisp_dirty *dl, wisp_rect r, uint16_t width, uint16_t height);
void wisp_display_invalidate(wisp_display *d);

/* Composes and presents every rect in dl, then empties it; returns the new frame number. */
uint32_t wisp_display_present(wisp_display *d, wisp_dirty *dl);
static inline uint32_t wisp_display_commit(wisp_display *d) { return wisp_display_present(d, &d->dirty); }
/* Composes one canvas rect into out (rows of w/2 bytes at stride; x and w even), without presenting. */
void wisp_display_compose(wisp_display *d, wisp_rect r, uint8_t *out, size_t stride);

/* 4 bpp pixel access, high nibble = left pixel. */
static inline uint8_t wisp_px_get(const uint8_t *row, int32_t x) {
    uint8_t b = row[x >> 1];
    return (x & 1) ? b & 0xfu : b >> 4;
}
static inline void wisp_px_set(uint8_t *row, int32_t x, uint8_t v) {
    uint8_t *b = &row[x >> 1];
    *b = (x & 1) ? (uint8_t)((*b & 0xf0u) | (v & 0xfu)) : (uint8_t)((*b & 0x0fu) | ((unsigned)v << 4));
}

#endif
