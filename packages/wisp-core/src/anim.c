/* Wisp core: animation players and tweens. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/anim.h"
#include "wisp/codec.h"

/* Applies the frame at a->pos to a->state; returns its duration (ms), or < 0 on error. */
static int step(wisp_anim *a, wisp_resources *r, wisp_display *d) {
    wisp_res *e = wisp_res_get(r, a->app, a->res, WISP_RES_ANIM);
    if (!e || e->w != a->w || e->h != a->h) return -1;
    uint16_t frames = wisp_get16(e->data + 4);
    uint8_t codec = e->data[6];
    size_t size = wisp_raw4_size(a->w, a->h);
    if (a->pos + WISP_ANIM_FRAME_HDR > e->len) return -1;
    const uint8_t *f = e->data + a->pos;
    uint16_t dur = wisp_get16(f);
    uint8_t kind = f[2];
    uint32_t n = wisp_get32(f + 3);
    const uint8_t *data = f + WISP_ANIM_FRAME_HDR;

    uint8_t *tmp = NULL, *scratch = NULL;
    size_t scratch_len = codec == WISP_CODEC_LZ4_RLE ? (size_t)a->w * a->h : 0;
    bool need_tmp = kind == 1 && codec != WISP_CODEC_RAW4;
    /* temporaries come from the display pool: they may move layer buffers and a->state, not e */
    if (need_tmp && !wisp_pool_alloc(d->pool, size, (void **)&tmp)) return -1;
    if (scratch_len && !wisp_pool_alloc(d->pool, scratch_len, (void **)&scratch)) {
        wisp_pool_free(d->pool, tmp);
        return -1;
    }
    int ok;
    if (kind == 0) {
        ok = wisp_pixels_decode(codec, data, n, a->w, a->h, a->state, size, scratch, scratch_len) == (int)size;
    } else if (codec == WISP_CODEC_RAW4) {
        ok = n == size;
        if (ok) wisp_xor(a->state, data, size);
    } else {
        ok = wisp_pixels_decode(codec, data, n, a->w, a->h, tmp, size, scratch, scratch_len) == (int)size;
        if (ok) wisp_xor(a->state, tmp, size);
    }
    wisp_pool_free(d->pool, scratch);
    wisp_pool_free(d->pool, tmp);
    if (!ok) return -1;
    a->pos += WISP_ANIM_FRAME_HDR + n;
    if (++a->frame == frames) {
        a->frame = 0;
        a->pos = WISP_ANIM_HDR;
        a->loop++;
    }
    return dur ? dur : 1;
}

static void show(wisp_anim *a, wisp_display *d) {
    wisp_display_blit(d, a->layer, a->x, a->y, a->state, (a->w + 1u) / 2u, 0, 0, a->w, a->h, false);
}

void wisp_anim_stop(wisp_anim *a, wisp_resources *r, wisp_display *d) {
    if (!a->active) return;
    for (uint16_t i = 0; i < r->max; i++) {
        wisp_res *e = &r->tab[i];
        if (e->state && e->app == a->app && e->id == a->res && e->users) e->users--;
    }
    wisp_pool_free(d->pool, a->state);
    memset(a, 0, sizeof *a);
}

int wisp_anim_play(wisp_anim *a, wisp_resources *r, wisp_display *d, uint8_t app,
                   const wisp_display_anim_play_req_t *m, uint64_t now_us) {
    wisp_anim_stop(a, r, d);
    if (!wisp_display_layer(d, m->layer)) return WISP_ERR_NO_SUCH_ID;
    wisp_res *e = wisp_res_get(r, app, m->res, WISP_RES_ANIM);
    if (!e) return WISP_ERR_NO_SUCH_ID;
    a->w = e->w;
    a->h = e->h;
    if (!wisp_pool_alloc(d->pool, wisp_raw4_size(a->w, a->h), (void **)&a->state)) return WISP_ERR_NO_MEMORY;
    memset(a->state, 0, wisp_raw4_size(a->w, a->h));
    e->users++;
    a->active = true;
    a->app = app;
    a->layer = m->layer;
    a->x = m->x;
    a->y = m->y;
    a->res = m->res;
    a->loops = m->loops;
    a->pos = WISP_ANIM_HDR;
    int dur = step(a, r, d);
    if (dur < 0) {
        wisp_anim_stop(a, r, d);
        return WISP_ERR_BAD_PAYLOAD;
    }
    a->next_us = now_us + (uint64_t)dur * 1000u;
    show(a, d);
    return 0;
}

bool wisp_anim_tick(wisp_anim *a, wisp_resources *r, wisp_display *d, uint64_t now_us, bool *done) {
    *done = false;
    if (!a->active || now_us < a->next_us) return false;
    if (now_us - a->next_us > 1000000u) a->next_us = now_us; /* far behind (a stall): don't race */
    bool drew = false;
    while (now_us >= a->next_us) {
        if (a->loops && a->loop >= a->loops) {
            if (drew) show(a, d);
            *done = true;
            wisp_anim_stop(a, r, d);
            return drew;
        }
        int dur = step(a, r, d);
        if (dur < 0) {
            *done = true;
            wisp_anim_stop(a, r, d);
            return drew;
        }
        a->next_us += (uint64_t)dur * 1000u;
        drew = true;
    }
    if (drew) show(a, d);
    return drew;
}

uint32_t wisp_ease(uint8_t easing, uint32_t t) {
    uint64_t x = t > 65536u ? 65536u : t, u = 65536u - x;
    switch (easing) {
    case WISP_EASE_IN: return (uint32_t)(x * x >> 16);
    case WISP_EASE_OUT: return (uint32_t)(65536u - (u * u >> 16));
    case WISP_EASE_IN_OUT: return x < 32768u ? (uint32_t)(x * x >> 15) : (uint32_t)(65536u - (u * u >> 15));
    default: return (uint32_t)x;
    }
}

void wisp_tween_start(wisp_tween *t, const wisp_layer *l, const wisp_display_tween_req_t *m, uint64_t now_us) {
    t->active = true;
    t->layer = m->layer;
    t->prop = m->prop;
    t->easing = m->easing;
    t->from = wisp_display_prop(l, m->prop);
    t->to = m->to;
    t->t0_us = now_us;
    t->dur_us = (uint32_t)m->duration_ms * 1000u;
}

bool wisp_tween_tick(wisp_tween *t, wisp_display *d, uint64_t now_us) {
    if (!t->active) return false;
    wisp_layer *l = wisp_display_layer(d, t->layer);
    if (!l) {
        t->active = false;
        return false;
    }
    uint64_t el = now_us > t->t0_us ? now_us - t->t0_us : 0;
    uint32_t p = !t->dur_us || el >= t->dur_us ? 65536u : (uint32_t)((el << 16) / t->dur_us);
    int64_t v = t->from + ((((int64_t)t->to - t->from) * wisp_ease(t->easing, p) + 32768) >> 16);
    wisp_display_set_prop(d, l, t->prop, (int32_t)v);
    if (p >= 65536u) t->active = false;
    return t->active;
}
