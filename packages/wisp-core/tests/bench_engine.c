/* Compose timings on the host: full frames and small dirty rects.
 * Built with -O2 and no sanitizers by tools/bench.sh. */
#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "wisp/engine.h"

static uint8_t fb[320 * 480];
static void present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px, size_t stride) {
    (void)ctx;
    for (uint16_t r = 0; r < h; r++) memcpy(fb + (size_t)(y + r) * 320 + x / 2, px + r * stride, w / 2u);
}
static void sink(void *ctx, uint8_t svc, const uint8_t *b, size_t n) { (void)ctx, (void)svc, (void)b, (void)n; }

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static uint8_t arena[8u << 20];

static void layer(wisp_display *d, uint8_t id, uint8_t z, uint8_t flags, uint8_t alpha, int16_t x, int16_t y, uint16_t w,
                  uint16_t h) {
    wisp_display_layer_set_req_t m = {id, z, flags, alpha, x, y, w, h, 0, 0, 0, 0};
    wisp_display_layer_set(d, &m);
    for (int32_t r = 0; r < h; r += 7) wisp_display_fill(d, id, (uint8_t)(1 + (r + id) % 15), 0, r, w, 3);
}

static void run(const char *name, wisp_display *d, wisp_rect r, int iters) {
    double best = 1e18;
    for (int k = 0; k < 5; k++) {
        double t0 = now_us();
        for (int i = 0; i < iters; i++) {
            wisp_dirty_add(&d->dirty, r, d->width, d->height);
            wisp_display_commit(d);
        }
        double us = (now_us() - t0) / iters;
        if (us < best) best = us;
    }
    printf("%-44s %8.1f us\n", name, best);
}

int main(void) {
    wisp_engine_config c;
    wisp_engine_defaults(&c);
    c.gfx_bytes = 4u << 20;
    wisp_hal hal = {NULL, present, NULL, sink, NULL, NULL, NULL};
    static wisp_engine e;
    wisp_engine_init(&e, &c, &hal, arena, sizeof arena);
    wisp_display *d = &e.display;
    wisp_rect full = {0, 0, 640, 480}, small = {101, 201, 165, 233};

    layer(d, 0, 0, 1, 15, 0, 0, 640, 480);
    run("full frame, 1 layer (over)", d, full, 200);
    run("64x32 dirty rect, 1 layer", d, small, 5000);
    layer(d, 1, 1, 1, 15, 3, 1, 640, 480); /* odd offset: nibble shifts */
    layer(d, 2, 2, 1 | WISP_BLEND_MAX << 1, 9, 0, 0, 640, 480);
    run("full frame, 3 layers (over odd, max a=9)", d, full, 100);
    run("64x32 dirty rect, 3 layers", d, small, 5000);
    layer(d, 3, 3, 1 | WISP_BLEND_ADD << 1, 15, 0, 100, 640, 200);
    layer(d, 4, 4, 1, 15, 200, 50, 200, 300);
    run("full frame, 5 layers", d, full, 100);
    return 0;
}
