/* Wisp core: the glasses-side engine (message dispatcher). MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/codec.h"
#include "wisp/engine.h"
#include "wisp/frame.h"
#include "wisp/text.h"

static inline size_t align8(size_t n) { return (n + 7u) & ~(size_t)7u; }

void wisp_engine_defaults(wisp_engine_config *c) {
    memset(c, 0, sizeof *c);
    c->fw_name = "wisp";
    c->fw_version = "0.1.0";
    c->lens = 1;
    c->canvas_w = 640;
    c->canvas_h = 480;
    c->max_layers = 16;
    c->anim_slots = 4;
    c->tween_slots = 16;
    c->max_res = 128;
    c->res_bytes = 1024u * 1024u;
    c->gfx_bytes = 1024u * 1024u;
    c->strip_rows = 16;
    c->max_frame = WISP_MAX_FRAME_DEFAULT;
    c->rx_window = WISP_RX_WINDOW_DEFAULT;
    c->session_timeout_ms = WISP_SESSION_TIMEOUT_DEFAULT_MS;
    c->swipe_min = 64;
}

static size_t display_part(const wisp_engine_config *c) {
    return align8(wisp_display_mem(c->canvas_w, c->canvas_h, c->max_layers, c->strip_rows));
}

size_t wisp_engine_arena_size(const wisp_engine_config *c) {
    return display_part(c) + align8(sizeof(wisp_res) * c->max_res) + align8(sizeof(wisp_anim) * c->anim_slots) +
           align8(sizeof(wisp_tween) * c->tween_slots) + align8(c->max_frame) + align8(c->res_bytes) +
           align8(c->gfx_bytes) + 8u;
}

static void copy_str16(char out[17], const char *s) {
    memset(out, 0, 17);
    for (unsigned i = 0; s && i < 16 && s[i]; i++) out[i] = s[i];
}

int wisp_engine_init(wisp_engine *e, const wisp_engine_config *c, const wisp_hal *hal, void *arena, size_t size) {
    if (!hal || !hal->send || !c->max_layers || !c->canvas_w || !c->canvas_h || c->max_frame < 64) return WISP_E_ARG;
    if (size < wisp_engine_arena_size(c)) return WISP_E_SPACE;
    memset(e, 0, sizeof *e);
    e->cfg = *c;
    e->hal = *hal;
    uint8_t *p = (uint8_t *)(((uintptr_t)arena + 7u) & ~(uintptr_t)7u);

    uint8_t *dmem = p;
    p += display_part(c);
    wisp_res *tab = (wisp_res *)(void *)p;
    p += align8(sizeof(wisp_res) * c->max_res);
    e->anims = (wisp_anim *)(void *)p;
    p += align8(sizeof(wisp_anim) * c->anim_slots);
    e->tweens = (wisp_tween *)(void *)p;
    p += align8(sizeof(wisp_tween) * c->tween_slots);
    e->out = p;
    e->out_cap = c->max_frame;
    p += align8(c->max_frame);
    uint8_t *res_mem = p;
    p += align8(c->res_bytes);
    uint8_t *gfx_mem = p;

    memset(e->anims, 0, sizeof(wisp_anim) * c->anim_slots);
    memset(e->tweens, 0, sizeof(wisp_tween) * c->tween_slots);
    wisp_pool_init(&e->gfx, gfx_mem, c->gfx_bytes);
    wisp_display_init(&e->display, dmem, c->canvas_w, c->canvas_h, c->max_layers, c->strip_rows, &e->gfx, hal->present,
                      hal->ctx);
    wisp_res_init(&e->res, tab, c->max_res, res_mem, c->res_bytes, hal->storage);
    wisp_input_init(&e->input, c->swipe_min);

    wisp_session_hello_rsp_t *h = &e->hello;
    h->proto_major = WISP_PROTO_MAJOR;
    h->proto_minor = WISP_PROTO_MINOR;
    h->max_frame = c->max_frame;
    h->rx_window = c->rx_window;
    copy_str16(h->fw_name, c->fw_name);
    copy_str16(h->fw_version, c->fw_version);
    h->lens = c->lens;
    h->caps = WISP_CAP_DISPLAY | WISP_CAP_ANIMATION | WISP_CAP_TWEEN | WISP_CAP_TEXT | WISP_CAP_TOUCH_RAW |
              WISP_CAP_GESTURES | WISP_CAP_WEAR | WISP_CAP_RLE4 | WISP_CAP_LZ4 | WISP_CAP_DELTA | c->extra_caps;
    if (hal->storage) h->caps |= WISP_CAP_PERSIST;
    h->canvas_w = e->display.width;
    h->canvas_h = c->canvas_h;
    h->bpp = 4;
    h->max_layers = c->max_layers;
    h->res_bytes = (uint32_t)e->res.pool.size;
    h->persist_bytes = hal->storage ? hal->storage->capacity : 0;
    h->session_timeout_ms = c->session_timeout_ms;
    wisp_session_init(&e->session, &e->hello);

    e->worn = true;
    e->power_on = true;
    e->display_on = true;
    return WISP_OK;
}

/* ---- output ---- */

static int send(wisp_engine *e, uint8_t svc, size_t len) {
    e->stats.tx_bytes += (uint32_t)len;
    e->hal.send(e->hal.ctx, svc, e->out, len);
    return 0;
}

static int reply(wisp_engine *e, uint8_t svc, const wisp_hdr *h, const wisp_desc *d, const void *msg) {
    if (!h->req) return 0;
    wisp_hdr rh = {h->op, WISP_MF_RESPONSE, h->req};
    int n = wisp_msg_encode(e->out, e->out_cap, &rh, d, msg);
    if (n > 0) send(e, svc, (size_t)n);
    return 0;
}

static int reply_status(wisp_engine *e, uint8_t svc, const wisp_hdr *h, int err) {
    if (err) e->stats.errors++;
    if (!h->req) return 0;
    if (!err) return reply(e, svc, h, NULL, NULL);
    int n = wisp_msg_error(e->out, e->out_cap, h->op, h->req, (uint16_t)err, NULL);
    if (n > 0) send(e, svc, (size_t)n);
    return 0;
}

static void event(wisp_engine *e, uint8_t svc, uint8_t op, const wisp_desc *d, const void *msg) {
    wisp_hdr h = {op, WISP_MF_EVENT, 0};
    int n = wisp_msg_encode(e->out, e->out_cap, &h, d, msg);
    if (n > 0) send(e, svc, (size_t)n);
}

/* ---- display power and wear ---- */

static void update_power(wisp_engine *e) {
    bool on = e->power_on && (e->worn || !e->off_when_unworn);
    if (on == e->display_on) return;
    e->display_on = on;
    if (e->hal.display_power) e->hal.display_power(e->hal.ctx, on);
}

void wisp_engine_set_worn(wisp_engine *e, bool worn, uint64_t now_us) {
    if (worn == e->worn) return;
    e->worn = worn;
    update_power(e);
    if (e->session.active && e->wear_sub) {
        uint8_t sample = worn;
        wisp_sensor_data_evt_t ev = {WISP_SENSOR_WEAR, 1, (uint32_t)now_us, 0, {&sample, 1}};
        event(e, WISP_SVC_SENSOR, WISP_OP_SENSOR_DATA, &wisp_sensor_data_evt_desc, &ev);
    }
}

/* ---- input ---- */

static void on_gesture(void *ctx, uint8_t pad, uint8_t kind, uint64_t t_us) {
    wisp_engine *e = ctx;
    (void)pad;
    wisp_input_gesture_evt_t ev = {e->cfg.lens, kind, (uint32_t)t_us};
    event(e, WISP_SVC_INPUT, WISP_OP_INPUT_GESTURE, &wisp_input_gesture_evt_desc, &ev);
}

void wisp_engine_touch(wisp_engine *e, uint8_t pad, uint8_t phase, uint16_t pos, uint64_t now_us) {
    e->now_us = now_us;
    if (!e->session.active) return;
    if (e->input.mask & WISP_INPUT_RAW) {
        wisp_input_touch_evt_t ev = {e->cfg.lens, pad, phase, pos, (uint32_t)now_us};
        event(e, WISP_SVC_INPUT, WISP_OP_INPUT_TOUCH, &wisp_input_touch_evt_desc, &ev);
    }
    wisp_input_touch(&e->input, pad, phase, pos, now_us, on_gesture, e);
}

void wisp_engine_gesture(wisp_engine *e, uint8_t pad, uint8_t kind, uint64_t now_us) {
    if (e->session.active && (e->input.mask & WISP_INPUT_GESTURES)) on_gesture(e, pad, kind, now_us);
}

/* ---- session ---- */

static void stop_all(wisp_engine *e) {
    for (uint8_t i = 0; i < e->cfg.anim_slots; i++) wisp_anim_stop(&e->anims[i], &e->res, &e->display);
    memset(e->tweens, 0, sizeof(wisp_tween) * e->cfg.tween_slots);
}

static void end_session(wisp_engine *e) {
    stop_all(e);
    wisp_input_config_req_t off = {0, 0, 0, 0};
    wisp_input_config(&e->input, &off);
    e->wear_sub = false;
    wisp_res_end_session(&e->res, e->app);
}

/* ---- auto-commit (animations, tweens) ---- */

static void auto_begin(wisp_engine *e) { e->display.sink = &e->auto_dirty; }

static void auto_end(wisp_engine *e) {
    e->display.sink = &e->display.dirty;
    if (!e->auto_dirty.n) return;
    uint32_t frame = wisp_display_present(&e->display, &e->auto_dirty);
    e->stats.auto_frames++;
    if (e->hal.frame_done) e->hal.frame_done(e->hal.ctx, frame);
}

/* Stops players drawing into a layer that goes away. */
static void layer_gone(wisp_engine *e, uint8_t layer) {
    for (uint8_t i = 0; i < e->cfg.anim_slots; i++)
        if (e->anims[i].active && e->anims[i].layer == layer) wisp_anim_stop(&e->anims[i], &e->res, &e->display);
    for (uint8_t i = 0; i < e->cfg.tween_slots; i++)
        if (e->tweens[i].layer == layer) e->tweens[i].active = false;
}

/* ---- services ---- */

typedef union {
    wisp_display_layer_set_req_t layer_set;
    wisp_display_layer_del_req_t layer_del;
    wisp_display_fill_req_t fill;
    wisp_display_blit_req_t blit;
    wisp_display_image_req_t image;
    wisp_display_text_req_t text;
    wisp_display_scroll_req_t scroll;
    wisp_display_commit_req_t commit;
    wisp_display_anim_play_req_t anim_play;
    wisp_display_anim_stop_req_t anim_stop;
    wisp_display_tween_req_t tween;
    wisp_resource_put_begin_req_t put_begin;
    wisp_resource_put_data_req_t put_data;
    wisp_resource_put_end_req_t put_end;
    wisp_resource_delete_req_t del;
    wisp_input_config_req_t input_config;
    wisp_sensor_subscribe_req_t subscribe;
    wisp_sensor_unsubscribe_req_t unsubscribe;
    wisp_sensor_read_req_t read;
    wisp_system_brightness_req_t brightness;
    wisp_system_display_power_req_t display_power;
} any_req;

static int do_image(wisp_engine *e, const wisp_display_image_req_t *m) {
    if (!wisp_display_layer(&e->display, m->layer)) return WISP_ERR_NO_SUCH_ID;
    if (m->codec > WISP_CODEC_LZ4_RLE) return WISP_ERR_BAD_PAYLOAD;
    size_t size = wisp_raw4_size(m->w, m->h), stride = (m->w + 1u) / 2u;
    if (m->codec == WISP_CODEC_RAW4) {
        if (m->data.len != size) return WISP_ERR_BAD_PAYLOAD;
        return wisp_display_blit(&e->display, m->layer, m->x, m->y, m->data.data, stride, 0, 0, m->w, m->h, false);
    }
    uint8_t *raw, *scratch = NULL;
    size_t scratch_len = m->codec == WISP_CODEC_LZ4_RLE ? (size_t)m->w * m->h : 0;
    if (!wisp_pool_alloc(&e->gfx, size, (void **)&raw)) return WISP_ERR_NO_MEMORY;
    if (scratch_len && !wisp_pool_alloc(&e->gfx, scratch_len, (void **)&scratch)) {
        wisp_pool_free(&e->gfx, raw);
        return WISP_ERR_NO_MEMORY;
    }
    int n = wisp_pixels_decode(m->codec, m->data.data, m->data.len, m->w, m->h, raw, size, scratch, scratch_len);
    wisp_pool_free(&e->gfx, scratch);
    int err = n == (int)size ? wisp_display_blit(&e->display, m->layer, m->x, m->y, raw, stride, 0, 0, m->w, m->h, false)
                             : WISP_ERR_BAD_PAYLOAD;
    wisp_pool_free(&e->gfx, raw);
    return err;
}

static int do_blit(wisp_engine *e, const wisp_display_blit_req_t *m) {
    if (!wisp_display_layer(&e->display, m->layer)) return WISP_ERR_NO_SUCH_ID;
    const wisp_res *img = wisp_res_get(&e->res, e->app, m->res, WISP_RES_IMAGE);
    if (!img) return WISP_ERR_NO_SUCH_ID;
    if (m->src_x >= img->w || m->src_y >= img->h) return 0;
    int32_t w = m->w ? m->w : img->w, h = m->h ? m->h : img->h;
    if (w > img->w - m->src_x) w = img->w - m->src_x;
    if (h > img->h - m->src_y) h = img->h - m->src_y;
    return wisp_display_blit(&e->display, m->layer, m->x, m->y, img->data, (img->w + 1u) / 2u, m->src_x, m->src_y, w,
                             h, m->flags & 1u);
}

static int display_svc(wisp_engine *e, const wisp_hdr *h, any_req *m) {
    wisp_display *d = &e->display;
    const uint8_t svc = WISP_SVC_DISPLAY;
    switch (h->op) {
    case WISP_OP_DISPLAY_LAYER_SET: return reply_status(e, svc, h, wisp_display_layer_set(d, &m->layer_set));
    case WISP_OP_DISPLAY_LAYER_DEL: {
        layer_gone(e, m->layer_del.layer);
        return reply_status(e, svc, h, wisp_display_layer_del(d, m->layer_del.layer));
    }
    case WISP_OP_DISPLAY_FILL: {
        const wisp_display_fill_req_t *f = &m->fill;
        return reply_status(e, svc, h, wisp_display_fill(d, f->layer, f->value, f->x, f->y, f->w, f->h));
    }
    case WISP_OP_DISPLAY_BLIT: return reply_status(e, svc, h, do_blit(e, &m->blit));
    case WISP_OP_DISPLAY_IMAGE: return reply_status(e, svc, h, do_image(e, &m->image));
    case WISP_OP_DISPLAY_TEXT: {
        const wisp_display_text_req_t *t = &m->text;
        const wisp_res *fr = wisp_res_get(&e->res, e->app, t->font, WISP_RES_FONT);
        wisp_font f;
        wisp_display_text_rsp_t rsp;
        if (!fr || !wisp_font_open(fr->data, fr->len, &f)) return reply_status(e, svc, h, WISP_ERR_NO_SUCH_ID);
        int err = wisp_text_draw(d, t->layer, &f, t->value, t->x, t->y, t->max_w, t->line_h, t->utf8.data, t->utf8.len,
                                 &rsp);
        if (err) return reply_status(e, svc, h, err);
        return reply(e, svc, h, &wisp_display_text_rsp_desc, &rsp);
    }
    case WISP_OP_DISPLAY_SCROLL: {
        const wisp_display_scroll_req_t *s = &m->scroll;
        return reply_status(e, svc, h, wisp_display_scroll(d, s->layer, s->dx, s->dy, s->fill));
    }
    case WISP_OP_DISPLAY_COMMIT: {
        wisp_display_commit_rsp_t rsp = {wisp_display_commit(d), e->now_us};
        if (e->hal.frame_done) e->hal.frame_done(e->hal.ctx, rsp.frame);
        return reply(e, svc, h, &wisp_display_commit_rsp_desc, &rsp);
    }
    case WISP_OP_DISPLAY_ANIM_PLAY: {
        if (m->anim_play.slot >= e->cfg.anim_slots) return reply_status(e, svc, h, WISP_ERR_NO_MEMORY);
        auto_begin(e);
        int err = wisp_anim_play(&e->anims[m->anim_play.slot], &e->res, d, e->app, &m->anim_play, e->now_us);
        auto_end(e);
        return reply_status(e, svc, h, err);
    }
    case WISP_OP_DISPLAY_ANIM_STOP: {
        if (m->anim_stop.slot >= e->cfg.anim_slots) return reply_status(e, svc, h, WISP_ERR_NO_SUCH_ID);
        wisp_anim_stop(&e->anims[m->anim_stop.slot], &e->res, d);
        return reply_status(e, svc, h, 0);
    }
    case WISP_OP_DISPLAY_TWEEN: {
        const wisp_display_tween_req_t *t = &m->tween;
        wisp_layer *l = wisp_display_layer(d, t->layer);
        if (!l) return reply_status(e, svc, h, WISP_ERR_NO_SUCH_ID);
        if (t->prop > WISP_PROP_SCROLL_Y || t->easing > WISP_EASE_IN_OUT)
            return reply_status(e, svc, h, WISP_ERR_BAD_PAYLOAD);
        wisp_tween *slot = NULL;
        for (uint8_t i = 0; i < e->cfg.tween_slots; i++) {
            wisp_tween *tw = &e->tweens[i];
            if (tw->active && tw->layer == t->layer && tw->prop == t->prop) slot = tw;
            else if (!tw->active && !slot) slot = tw;
        }
        if (!slot) return reply_status(e, svc, h, WISP_ERR_NO_MEMORY);
        wisp_tween_start(slot, l, t, e->now_us);
        if (!t->duration_ms) {
            auto_begin(e);
            wisp_tween_tick(slot, d, e->now_us);
            auto_end(e);
        }
        return reply_status(e, svc, h, 0);
    }
    case WISP_OP_DISPLAY_CLEAR_ALL:
        stop_all(e);
        wisp_display_clear_all(d);
        return reply_status(e, svc, h, 0);
    default: return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
    }
}

static int resource_svc(wisp_engine *e, const wisp_hdr *h, any_req *m) {
    wisp_resources *r = &e->res;
    const uint8_t svc = WISP_SVC_RESOURCE;
    switch (h->op) {
    case WISP_OP_RESOURCE_PUT_BEGIN: {
        wisp_resource_put_begin_rsp_t rsp = {0};
        /* replacing a resource stops its players */
        for (uint8_t i = 0; i < e->cfg.anim_slots; i++)
            if (e->anims[i].active && e->anims[i].app == e->app && e->anims[i].res == m->put_begin.res)
                wisp_anim_stop(&e->anims[i], r, &e->display);
        int err = wisp_res_put_begin(r, e->app, &m->put_begin, &rsp.status);
        if (err) return reply_status(e, svc, h, err);
        return reply(e, svc, h, &wisp_resource_put_begin_rsp_desc, &rsp);
    }
    case WISP_OP_RESOURCE_PUT_DATA: {
        const wisp_resource_put_data_req_t *p = &m->put_data;
        return reply_status(e, svc, h, wisp_res_put_data(r, e->app, p->res, p->offset, p->data));
    }
    case WISP_OP_RESOURCE_PUT_END: return reply_status(e, svc, h, wisp_res_put_end(r, e->app, m->put_end.res));
    case WISP_OP_RESOURCE_DELETE:
        for (uint8_t i = 0; i < e->cfg.anim_slots; i++)
            if (e->anims[i].active && (m->del.res == WISP_RES_ALL || e->anims[i].res == m->del.res))
                wisp_anim_stop(&e->anims[i], r, &e->display);
        return reply_status(e, svc, h, wisp_res_delete(r, e->app, m->del.res));
    case WISP_OP_RESOURCE_LIST: {
        if (!h->req) return 0;
        size_t cap = (e->session.max_frame < e->out_cap ? e->session.max_frame : e->out_cap) - WISP_MSG_HDR;
        wisp_hdr rh = {h->op, WISP_MF_RESPONSE, h->req};
        size_t n = wisp_res_list(r, e->app, e->out + WISP_MSG_HDR, cap);
        wisp_hdr_encode(e->out, &rh);
        return send(e, svc, WISP_MSG_HDR + n);
    }
    default: return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
    }
}

static int sensor_svc(wisp_engine *e, const wisp_hdr *h, any_req *m) {
    const uint8_t svc = WISP_SVC_SENSOR;
    switch (h->op) {
    case WISP_OP_SENSOR_SUBSCRIBE:
        if (m->subscribe.sensor != WISP_SENSOR_WEAR) return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
        e->wear_sub = true;
        return reply_status(e, svc, h, 0);
    case WISP_OP_SENSOR_UNSUBSCRIBE:
        if (m->unsubscribe.sensor == WISP_SENSOR_WEAR) e->wear_sub = false;
        return reply_status(e, svc, h, 0);
    case WISP_OP_SENSOR_READ: {
        if (m->read.sensor != WISP_SENSOR_WEAR) return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
        uint8_t worn = e->worn;
        wisp_sensor_read_rsp_t rsp = {{&worn, 1}};
        return reply(e, svc, h, &wisp_sensor_read_rsp_desc, &rsp);
    }
    default: return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
    }
}

static int system_svc(wisp_engine *e, const wisp_hdr *h, any_req *m) {
    const uint8_t svc = WISP_SVC_SYSTEM;
    switch (h->op) {
    case WISP_OP_SYSTEM_INFO: {
        wisp_system_info_rsp_t rsp;
        memset(&rsp, 0, sizeof rsp);
        copy_str16(rsp.hw_rev, e->cfg.hw_rev);
        copy_str16(rsp.serial, e->cfg.serial);
        copy_str16(rsp.build, e->cfg.fw_version);
        rsp.lens = e->cfg.lens;
        rsp.uptime_ms = (uint32_t)(e->now_us / 1000u);
        return reply(e, svc, h, &wisp_system_info_rsp_desc, &rsp);
    }
    case WISP_OP_SYSTEM_STATS: {
        wisp_system_stats_rsp_t rsp = {
            (uint32_t)(wisp_pool_free_bytes(&e->res.pool) + wisp_pool_free_bytes(&e->gfx)),
            (uint32_t)(e->res.pool.min_free + e->gfx.min_free),
            0,
            e->display.frame,
            e->stats.rx_bytes,
            e->stats.tx_bytes,
            0,
        };
        return reply(e, svc, h, &wisp_system_stats_rsp_desc, &rsp);
    }
    case WISP_OP_SYSTEM_BRIGHTNESS:
        if (e->hal.brightness) e->hal.brightness(e->hal.ctx, m->brightness.mode, m->brightness.level);
        return reply_status(e, svc, h, 0);
    case WISP_OP_SYSTEM_DISPLAY_POWER:
        e->power_on = m->display_power.on;
        e->off_when_unworn = m->display_power.off_when_unworn;
        update_power(e);
        return reply_status(e, svc, h, 0);
    case WISP_OP_SYSTEM_LINK_PROFILE:
    case WISP_OP_SYSTEM_LOG_CONFIG: return reply_status(e, svc, h, 0);
    default: return reply_status(e, svc, h, WISP_ERR_UNSUPPORTED);
    }
}

void wisp_engine_rx(wisp_engine *e, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
                    wisp_session_result *r) {
    e->now_us = now_us;
    e->stats.rx_bytes += (uint32_t)len;
    bool was_active = e->session.active;
    wisp_session_rx(&e->session, svc, body, len, now_us, e->out, e->out_cap, r);
    if (r->reply_len) send(e, svc, r->reply_len);
    if (r->event == WISP_SESSION_STARTED) {
        if (was_active) end_session(e);
        stop_all(e);
        wisp_display_clear_all(&e->display);
        e->app = wisp_res_app(&e->res, e->session.peer.app_id);
        return;
    }
    if (r->event == WISP_SESSION_ENDED) {
        end_session(e);
        return;
    }
    if (r->event != WISP_SESSION_DISPATCH) return;

    wisp_hdr h;
    wisp_hdr_decode(body, len, &h);
    e->stats.msgs++;
    if (h.mflags & (WISP_MF_RESPONSE | WISP_MF_ERROR | WISP_MF_EVENT)) return; /* nothing we asked for */
    const wisp_desc *d = wisp_desc_find(svc, h.op, 0);
    any_req m;
    memset(&m, 0, sizeof m);
    if (d && wisp_unpack(d, body + WISP_MSG_HDR, len - WISP_MSG_HDR, &m) < 0) {
        reply_status(e, svc, &h, WISP_ERR_BAD_PAYLOAD);
        return;
    }
    switch (svc) {
    case WISP_SVC_DISPLAY: display_svc(e, &h, &m); break;
    case WISP_SVC_RESOURCE: resource_svc(e, &h, &m); break;
    case WISP_SVC_INPUT:
        if (h.op != WISP_OP_INPUT_CONFIG) {
            reply_status(e, svc, &h, WISP_ERR_UNSUPPORTED);
            break;
        }
        wisp_input_config(&e->input, &m.input_config);
        reply_status(e, svc, &h, 0);
        break;
    case WISP_SVC_SENSOR: sensor_svc(e, &h, &m); break;
    case WISP_SVC_SYSTEM: system_svc(e, &h, &m); break;
    default: reply_status(e, svc, &h, WISP_ERR_UNSUPPORTED); break;
    }
}

bool wisp_engine_busy(const wisp_engine *e) {
    for (uint8_t i = 0; i < e->cfg.anim_slots; i++)
        if (e->anims[i].active) return true;
    for (uint8_t i = 0; i < e->cfg.tween_slots; i++)
        if (e->tweens[i].active) return true;
    for (unsigned i = 0; i < WISP_INPUT_PADS; i++)
        if (e->input.pads[i].down || e->input.pads[i].tap_pending) return true;
    return false;
}

bool wisp_engine_tick(wisp_engine *e, uint64_t now_us) {
    e->now_us = now_us;
    auto_begin(e);
    for (uint8_t i = 0; i < e->cfg.anim_slots; i++) {
        bool done;
        wisp_anim_tick(&e->anims[i], &e->res, &e->display, now_us, &done);
        if (done) {
            wisp_display_anim_done_evt_t ev = {i};
            event(e, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_ANIM_DONE, &wisp_display_anim_done_evt_desc, &ev);
        }
    }
    for (uint8_t i = 0; i < e->cfg.tween_slots; i++) wisp_tween_tick(&e->tweens[i], &e->display, now_us);
    auto_end(e);
    wisp_input_tick(&e->input, now_us, on_gesture, e);
    if (wisp_session_tick(&e->session, now_us) == WISP_SESSION_ENDED) {
        end_session(e);
        return true;
    }
    return false;
}
