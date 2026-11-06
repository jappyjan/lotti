/* wisp-sim: the Wisp core with a simulator HAL, built for WebAssembly.
 * MIT License, Wisp contributors.
 *
 * Two lenses (one wisp_engine each, left = 1, right = 2) and up to SIM_CONNS
 * links. A link is the byte stream of one temple connection: frames in
 * (wisp_rx), frames out (wisp_tx), CREDIT / RESYNC, the ack timeout. The
 * frame's route byte picks the lens; a link opened with `mirror` treats
 * route 0 as "both lenses", and the other lens then only follows (its
 * responses are dropped so every request gets exactly one, its input events
 * still reach the phone).
 *
 * The host (Node) drives it: sim_link_rx / sim_link_pull move bytes,
 * sim_tick advances time, the framebuffers and their damage are read straight
 * out of linear memory, and storage goes to imported functions. */
#include <string.h>

#include "wisp/engine.h"
#include "wisp/frame.h"

#define SIM_EXPORT(name) __attribute__((export_name(#name))) name
#define SIM_IMPORT(name) __attribute__((import_module("env"), import_name(#name)))

#define SIM_CONNS 4
#define SIM_LENSES 2
#define FB_STRIDE 320
#define FB_H 480
#define MAX_FRAME 4096u
#define TX_RING (64u * 1024u)
#define QUEUE (128u * 1024u)

/* ---- imports: storage and logging live in the host ---- */

SIM_IMPORT(storage_write) int js_storage_write(const char *app, const uint8_t *meta, const uint8_t *data, size_t len);
SIM_IMPORT(storage_read) int js_storage_read(const char *app, uint32_t res, uint8_t *meta, uint8_t *data, size_t cap);
SIM_IMPORT(storage_remove) int js_storage_remove(const char *app, uint32_t res);
SIM_IMPORT(storage_list) int js_storage_list(const char *app, uint8_t *out, size_t cap);
SIM_IMPORT(storage_capacity) uint32_t js_storage_capacity(void);

/* Wasm has no libc: the four functions the core may call. */
void *memcpy(void *d, const void *s, size_t n) {
    __builtin_memcpy(d, s, n);
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    __builtin_memmove(d, s, n);
    return d;
}
void *memset(void *d, int c, size_t n) {
    __builtin_memset(d, c, n);
    return d;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}

/* ---- lenses ---- */

typedef struct {
    int32_t x0, y0, x1, y1; /* damage since the host last looked (empty: x0 >= x1) */
    uint32_t frame;         /* last presented frame */
    uint32_t presents, px;
    uint32_t display_on, brightness;
} lens_out;

typedef struct {
    wisp_engine e;
    uint8_t fb[FB_STRIDE * FB_H];
    lens_out out;
    int owner;     /* link that started its session, -1 none */
    bool follower; /* started through a mirrored route-0 frame from the other lens's link */
} lens;

typedef struct {
    bool used, mirror;
    uint8_t lens; /* 1 or 2: the temple this link is connected to */
    wisp_rx rx;
    wisp_tx tx;
    uint8_t rxbuf[MAX_FRAME + WISP_FRAME_OVERHEAD];
    uint8_t ring[TX_RING];
    /* bodies waiting for window space: {svc, route, len u16, body} */
    uint8_t queue[QUEUE];
    size_t qlen;
    uint32_t unacked; /* frames consumed since our last CREDIT */
    uint32_t rx_bytes, tx_bytes, resyncs;
} link;

#define ARENA_PER_LENS (14u << 20)
static uint8_t arena[SIM_LENSES][ARENA_PER_LENS];
static lens lenses[SIM_LENSES];
static link links[SIM_CONNS];
static uint64_t now_us;
static uint8_t io[256 * 1024]; /* host <-> wasm transfer buffer */

/* dispatch context: which link and lens a reply goes to */
static int cur_link = -1;
static bool cur_reply = true;

static lens *lens_of(uint8_t n) { return &lenses[n == 1 ? 0 : 1]; }

/* ---- storage HAL ---- */

static int st_write(void *ctx, const char *app, const wisp_list_entry_t *meta, const uint8_t *data, size_t len) {
    (void)ctx;
    uint8_t m[24];
    wisp_pack(&wisp_list_entry_desc, meta, m, sizeof m);
    return js_storage_write(app, m, data, len);
}
static int st_read(void *ctx, const char *app, uint16_t res, wisp_list_entry_t *meta, uint8_t *data, size_t cap) {
    (void)ctx;
    uint8_t m[24];
    int n = js_storage_read(app, res, m, data, data ? cap : 0);
    if (n >= 0) wisp_unpack(&wisp_list_entry_desc, m, sizeof m, meta);
    return n;
}
static int st_remove(void *ctx, const char *app, uint16_t res) {
    (void)ctx;
    return js_storage_remove(app, res);
}
static int st_list(void *ctx, const char *app, wisp_list_entry_t *out, size_t cap) {
    (void)ctx;
    static uint8_t buf[24 * 64];
    if (cap > 64) cap = 64;
    int n = js_storage_list(app, buf, cap);
    for (int i = 0; i < n; i++) wisp_unpack(&wisp_list_entry_desc, buf + 24 * i, 24, &out[i]);
    return n;
}
static wisp_storage storage = {NULL, 0, st_write, st_read, st_remove, st_list};

/* ---- display HAL ---- */

static void present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px, size_t stride) {
    lens *l = ctx;
    for (uint16_t r = 0; r < h; r++) memcpy(l->fb + (size_t)(y + r) * FB_STRIDE + x / 2u, px + r * stride, w / 2u);
    lens_out *o = &l->out;
    if (o->x0 >= o->x1) {
        o->x0 = x, o->y0 = y, o->x1 = x + w, o->y1 = y + h;
    } else {
        if (x < o->x0) o->x0 = x;
        if (y < o->y0) o->y0 = y;
        if (x + w > o->x1) o->x1 = x + w;
        if (y + h > o->y1) o->y1 = y + h;
    }
    o->presents++;
    o->px += (uint32_t)w * h;
}
static void frame_done(void *ctx, uint32_t frame) { ((lens *)ctx)->out.frame = frame; }
static void display_power(void *ctx, bool on) { ((lens *)ctx)->out.display_on = on; }
static void brightness(void *ctx, uint8_t mode, uint8_t level) {
    ((lens *)ctx)->out.brightness = mode ? 0x100u : level;
}

/* ---- links ---- */

static void link_send(link *k, uint8_t svc, uint8_t route, const uint8_t *body, size_t len) {
    if (!k->qlen) {
        int r = wisp_tx_send(&k->tx, svc, route, body, len);
        if (r >= 0) return;
        if (r != WISP_E_WINDOW) return; /* too big: drop */
    }
    if (k->qlen + 4 + len > QUEUE) return; /* the phone isn't reading: drop */
    uint8_t *q = k->queue + k->qlen;
    q[0] = svc;
    q[1] = route;
    wisp_put16(q + 2, (uint16_t)len);
    memcpy(q + 4, body, len);
    k->qlen += 4 + len;
}

static void link_flush_queue(link *k) {
    size_t off = 0;
    while (off < k->qlen) {
        uint8_t *q = k->queue + off;
        size_t len = wisp_get16(q + 2);
        if (wisp_tx_send(&k->tx, q[0], q[1], q + 4, len) == WISP_E_WINDOW) break;
        off += 4 + len;
    }
    memmove(k->queue, k->queue + off, k->qlen - off);
    k->qlen -= off;
}

/* hal->send for a lens: to the link that owns its session */
static void lens_send(void *ctx, uint8_t svc, const uint8_t *body, size_t len) {
    lens *l = ctx;
    int owner = cur_link >= 0 ? cur_link : l->owner;
    if (owner < 0 || !links[owner].used) return;
    bool event = len >= 2 && (body[1] & WISP_MF_EVENT);
    if (cur_link >= 0 && !cur_reply) return; /* a follower in a mirrored dispatch */
    if (cur_link < 0 && l->follower && !(event && (svc == WISP_SVC_INPUT || svc == WISP_SVC_SENSOR))) return;
    uint8_t src = (uint8_t)(l->e.cfg.lens << 2);
    link_send(&links[owner], svc, src, body, len);
}

static void deliver(int id, const wisp_frame *f) {
    link *k = &links[id];
    uint8_t dest = f->route & 3u;
    bool both = dest == 3 || (dest == 0 && k->mirror);
    uint8_t first = dest == 1 || dest == 2 ? dest : k->lens;
    uint8_t targets[2] = {first, (uint8_t)(3 - first)};
    unsigned n = both ? 2 : 1;
    k->unacked++;
    for (unsigned i = 0; i < n; i++) {
        lens *l = lens_of(targets[i]);
        wisp_session_result r;
        cur_link = id;
        cur_reply = i == 0;
        wisp_engine_rx(&l->e, f->svc, f->body, f->len, now_us, &r);
        cur_link = -1;
        cur_reply = true;
        if (r.event == WISP_SESSION_STARTED) {
            l->owner = id;
            l->follower = i > 0;
            if (i == 0) wisp_tx_set_peer(&k->tx, l->e.session.max_frame, l->e.session.peer_window);
        }
    }
}

/* CREDIT / RESYNC from the phone: the link applies it; the lens' session only notes the traffic. */
static void control(int id, const wisp_frame *f) {
    link *k = &links[id];
    wisp_tx_control(&k->tx, f);
    wisp_session_result r;
    cur_link = id;
    wisp_engine_rx(&lens_of(k->lens)->e, f->svc, f->body, f->len, now_us, &r);
    cur_link = -1;
}

/* ---- exports ---- */

uint8_t *SIM_EXPORT(sim_io)(void) { return io; }
size_t SIM_EXPORT(sim_io_size)(void) { return sizeof io; }

int SIM_EXPORT(sim_init)(void) {
    storage.capacity = js_storage_capacity();
    for (uint8_t i = 0; i < SIM_LENSES; i++) {
        lens *l = &lenses[i];
        memset(l, 0, sizeof *l);
        l->owner = -1;
        l->out.display_on = 1;
        l->out.brightness = 0x100;
        wisp_engine_config c;
        wisp_engine_defaults(&c);
        c.fw_name = "wisp-sim";
        c.fw_version = "0.1.0";
        c.hw_rev = "sim";
        c.serial = i ? "SIM-R" : "SIM-L";
        c.lens = (uint8_t)(i + 1);
        c.max_layers = 16;
        c.max_res = 256;
        c.anim_slots = 8;
        c.tween_slots = 32;
        c.res_bytes = 6u << 20;
        c.gfx_bytes = 7u << 20;
        c.strip_rows = 32;
        c.max_frame = MAX_FRAME;
        c.swipe_min = 64;
        c.extra_caps = WISP_CAP_FORWARD;
        wisp_hal hal = {l, present, frame_done, lens_send, display_power, brightness, &storage};
        int r = wisp_engine_init(&l->e, &c, &hal, arena[i], sizeof arena[i]);
        if (r) return r;
    }
    return 0;
}

int SIM_EXPORT(sim_link_open)(uint32_t lens_no, uint32_t mirror) {
    for (int i = 0; i < SIM_CONNS; i++) {
        link *k = &links[i];
        if (k->used) continue;
        memset(k, 0, sizeof *k);
        k->used = true;
        k->lens = lens_no == 1 ? 1 : 2;
        k->mirror = mirror != 0;
        wisp_rx_init(&k->rx, k->rxbuf, sizeof k->rxbuf);
        wisp_tx_init(&k->tx, k->ring, sizeof k->ring);
        k->tx.ctrl_route = (uint8_t)(k->lens << 2); /* source lens */
        return i;
    }
    return -1;
}

/* The connection dropped: the sessions it owns end now (as on a BLE disconnect). */
void SIM_EXPORT(sim_link_close)(int id) {
    if (id < 0 || id >= SIM_CONNS || !links[id].used) return;
    links[id].used = false;
    for (unsigned i = 0; i < SIM_LENSES; i++) {
        lens *l = &lenses[i];
        if (l->owner != id) continue;
        uint8_t bye[4] = {WISP_OP_SESSION_BYE, 0, 0, 0};
        wisp_session_result r;
        wisp_engine_rx(&l->e, WISP_SVC_SESSION, bye, sizeof bye, now_us, &r);
        l->owner = -1;
        l->follower = false;
    }
}

/* Bytes from the phone in io[0, len). */
void SIM_EXPORT(sim_link_rx)(int id, size_t len) {
    if (id < 0 || id >= SIM_CONNS || !links[id].used) return;
    link *k = &links[id];
    k->rx_bytes += (uint32_t)len;
    const uint8_t *p = io;
    wisp_rx_event ev;
    wisp_frame f;
    do {
        size_t n = wisp_rx_feed(&k->rx, p, len, &ev, &f);
        p += n;
        len -= n;
        if (ev == WISP_RX_FRAME) deliver(id, &f);
        if (ev == WISP_RX_CONTROL) control(id, &f);
        if (ev == WISP_RX_DUPLICATE) wisp_tx_queue_credit(&k->tx, k->rx.last_good_seq);
        if (ev == WISP_RX_RESYNC) {
            wisp_tx_queue_resync(&k->tx, k->rx.last_good_seq);
            k->resyncs++;
        }
    } while (ev != WISP_RX_NONE);
    /* one coalesced CREDIT per chunk the host hands us */
    if (k->unacked) {
        wisp_tx_queue_credit(&k->tx, k->rx.last_good_seq);
        k->unacked = 0;
    }
}

/* Bytes for the phone into io; returns the count. */
size_t SIM_EXPORT(sim_link_pull)(int id) {
    if (id < 0 || id >= SIM_CONNS || !links[id].used) return 0;
    link *k = &links[id];
    link_flush_queue(k);
    size_t n = wisp_tx_pull(&k->tx, io, sizeof io);
    k->tx_bytes += (uint32_t)n;
    return n;
}

/* Advances time; returns a bit mask of lenses whose session timed out. */
uint32_t SIM_EXPORT(sim_tick)(double now) {
    now_us = (uint64_t)now;
    uint32_t ended = 0;
    for (unsigned i = 0; i < SIM_LENSES; i++)
        if (wisp_engine_tick(&lenses[i].e, now_us)) {
            ended |= 1u << i;
            lenses[i].owner = -1;
        }
    for (int i = 0; i < SIM_CONNS; i++) {
        link *k = &links[i];
        if (!k->used) continue;
        wisp_tx_tick(&k->tx, (uint32_t)(now_us / 1000u)); /* ack timeout */
    }
    return ended;
}

void SIM_EXPORT(sim_touch)(uint32_t lens_no, uint32_t phase, uint32_t pos) {
    wisp_engine_touch(&lens_of((uint8_t)lens_no)->e, 0, (uint8_t)phase, (uint16_t)pos, now_us);
}
void SIM_EXPORT(sim_gesture)(uint32_t lens_no, uint32_t kind) {
    wisp_engine_gesture(&lens_of((uint8_t)lens_no)->e, 0, (uint8_t)kind, now_us);
}
void SIM_EXPORT(sim_wear)(uint32_t worn) {
    for (unsigned i = 0; i < SIM_LENSES; i++) wisp_engine_set_worn(&lenses[i].e, worn != 0, now_us);
}

uint8_t *SIM_EXPORT(sim_fb)(uint32_t lens_no) { return lens_of((uint8_t)lens_no)->fb; }
lens_out *SIM_EXPORT(sim_out)(uint32_t lens_no) { return &lens_of((uint8_t)lens_no)->out; }
void SIM_EXPORT(sim_out_clear)(uint32_t lens_no) {
    lens_out *o = &lens_of((uint8_t)lens_no)->out;
    o->x0 = o->y0 = o->x1 = o->y1 = 0;
}

/* Stats as u32s into io: see STATS_FIELDS in the host. */
size_t SIM_EXPORT(sim_stats)(uint32_t lens_no) {
    lens *l = lens_of((uint8_t)lens_no);
    wisp_engine *e = &l->e;
    uint32_t layers = 0, res = 0, res_bytes = 0, anims = 0, tweens = 0;
    for (uint8_t i = 0; i < e->display.max_layers; i++) layers += e->display.layers[i].used;
    for (uint16_t i = 0; i < e->res.max; i++)
        if (e->res.tab[i].state == WISP_RES_READY) res++, res_bytes += e->res.tab[i].len;
    for (uint8_t i = 0; i < e->cfg.anim_slots; i++) anims += e->anims[i].active;
    for (uint8_t i = 0; i < e->cfg.tween_slots; i++) tweens += e->tweens[i].active;
    link *k = l->owner >= 0 ? &links[l->owner] : NULL;
    uint32_t v[] = {
        e->session.active,
        e->display.frame,
        layers,
        res,
        res_bytes,
        (uint32_t)wisp_pool_free_bytes(&e->res.pool),
        (uint32_t)wisp_pool_free_bytes(&e->gfx),
        anims,
        tweens,
        e->stats.msgs,
        e->stats.errors,
        k ? k->rx_bytes : 0,
        k ? k->tx_bytes : 0,
        k ? k->resyncs : 0,
        k ? k->tx.resends : 0,
        k ? k->tx.timeouts : 0,
        l->out.display_on,
        e->worn,
        e->input.mask,
        l->follower,
        (uint32_t)(e->display.px_composed / 1000u),
        e->stats.auto_frames,
    };
    memcpy(io, v, sizeof v);
    memcpy(io + sizeof v, e->session.peer.app_id, 17);
    return sizeof v / 4;
}
