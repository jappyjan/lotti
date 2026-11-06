/* Tests for the display engine: pool, SHA-256, compositor (against a
 * per-pixel reference model and golden frame hashes), resources, text,
 * animation, tweens, input and the dispatcher. */
#include <string.h>

#include "test.h"
#include "wisp/codec.h"
#include "wisp/engine.h"
#include "wisp/sha256.h"
#include "wisp/text.h"

#define W 640
#define H 480
#define STRIDE (W / 2)

/* ---- harness: an engine with a framebuffer HAL and a message log ---- */

typedef struct {
    uint8_t svc;
    size_t len;
    uint8_t body[4200];
} sent_msg;

typedef struct {
    wisp_engine e;
    uint8_t fb[STRIDE * H];
    uint64_t now;
    sent_msg log[64];
    unsigned nlog;
    uint32_t presented_px, frames_done;
    wisp_rect presented[256];
    unsigned npresented;
    bool power;
} harness;

static void h_present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px, size_t stride) {
    harness *t = ctx;
    CHECK(!(x & 1) && !(w & 1) && x + w <= W && y + h <= H);
    for (uint16_t r = 0; r < h; r++) memcpy(t->fb + (size_t)(y + r) * STRIDE + x / 2, px + r * stride, w / 2u);
    t->presented_px += (uint32_t)w * h;
    if (t->npresented < 256) t->presented[t->npresented++] = (wisp_rect){x, y, x + w, y + h};
}
static void h_frame_done(void *ctx, uint32_t frame) {
    (void)frame;
    ((harness *)ctx)->frames_done++;
}
static void h_send(void *ctx, uint8_t svc, const uint8_t *body, size_t len) {
    harness *t = ctx;
    CHECK(len <= sizeof t->log[0].body);
    if (t->nlog == 64) {
        memmove(t->log, t->log + 1, sizeof t->log[0] * 63);
        t->nlog = 63;
    }
    sent_msg *m = &t->log[t->nlog++];
    m->svc = svc;
    m->len = len;
    memcpy(m->body, body, len);
}
static void h_power(void *ctx, bool on) { ((harness *)ctx)->power = on; }

/* in-memory storage */
typedef struct {
    char app[17];
    wisp_list_entry_t meta;
    uint8_t data[4096];
    bool used;
} stored;
static stored store[8];
static int st_write(void *ctx, const char *app, const wisp_list_entry_t *meta, const uint8_t *data, size_t len) {
    (void)ctx;
    if (len > 4096) return -1;
    for (int i = 0; i < 8; i++)
        if (store[i].used && !strcmp(store[i].app, app) && store[i].meta.res == meta->res) store[i].used = false;
    for (int i = 0; i < 8; i++)
        if (!store[i].used) {
            store[i].used = true;
            strcpy(store[i].app, app);
            store[i].meta = *meta;
            memcpy(store[i].data, data, len);
            return 0;
        }
    return -1;
}
static int st_read(void *ctx, const char *app, uint16_t res, wisp_list_entry_t *meta, uint8_t *data, size_t cap) {
    (void)ctx;
    for (int i = 0; i < 8; i++)
        if (store[i].used && !strcmp(store[i].app, app) && store[i].meta.res == res) {
            *meta = store[i].meta;
            if (data) memcpy(data, store[i].data, cap < meta->size ? cap : meta->size);
            return (int)meta->size;
        }
    return -1;
}
static int st_remove(void *ctx, const char *app, uint16_t res) {
    (void)ctx;
    int n = -1;
    for (int i = 0; i < 8; i++)
        if (store[i].used && !strcmp(store[i].app, app) && (res == 0xFFFF || store[i].meta.res == res))
            store[i].used = false, n = 0;
    return n;
}
static int st_list(void *ctx, const char *app, wisp_list_entry_t *out, size_t cap) {
    (void)ctx;
    int n = 0;
    for (int i = 0; i < 8 && (size_t)n < cap; i++)
        if (store[i].used && !strcmp(store[i].app, app)) out[n++] = store[i].meta;
    return n;
}
static const wisp_storage storage = {NULL, 1 << 20, st_write, st_read, st_remove, st_list};

static uint8_t arena[8u << 20];

static void h_init(harness *t, bool with_storage, uint32_t res_bytes) {
    memset(t, 0, sizeof *t);
    wisp_engine_config c;
    wisp_engine_defaults(&c);
    c.res_bytes = res_bytes;
    c.gfx_bytes = 3u << 20;
    c.hw_rev = "test";
    wisp_hal hal = {t, h_present, h_frame_done, h_send, h_power, NULL, with_storage ? &storage : NULL};
    CHECK(wisp_engine_arena_size(&c) <= sizeof arena);
    CHECK(wisp_engine_init(&t->e, &c, &hal, arena, sizeof arena) == WISP_OK);
    t->power = true;
    t->now = 1000;
}

static uint8_t body[70000];

static void rx(harness *t, uint8_t svc, uint8_t op, uint16_t req, const wisp_desc *d, const void *m) {
    wisp_hdr h = {op, 0, req};
    int n = wisp_msg_encode(body, sizeof body, &h, d, m);
    CHECK(n > 0);
    wisp_session_result r;
    wisp_engine_rx(&t->e, svc, body, (size_t)n, t->now, &r);
}

/* The last message sent in answer to req (NULL if none). */
static const sent_msg *rsp(harness *t, uint16_t req) {
    for (unsigned i = t->nlog; i-- > 0;)
        if (wisp_get16(t->log[i].body + 2) == req && (t->log[i].body[1] & WISP_MF_RESPONSE)) return &t->log[i];
    return NULL;
}
static int rsp_error(harness *t, uint16_t req) {
    const sent_msg *m = rsp(t, req);
    if (!m) return -1;
    return (m->body[1] & WISP_MF_ERROR) ? wisp_get16(m->body + 4) : 0;
}

static void hello(harness *t, const char *app) {
    wisp_session_hello_req_t h = {0, 2, 0, 0, {0}, {0}};
    strncpy(h.app_id, app, 16);
    rx(t, WISP_SVC_SESSION, WISP_OP_SESSION_HELLO, 1, &wisp_session_hello_req_desc, &h);
}

static void layer(harness *t, uint8_t id, uint8_t z, uint8_t flags, uint8_t alpha, int16_t x, int16_t y, uint16_t w,
                  uint16_t h, uint16_t cw, uint16_t ch, int16_t sx, int16_t sy) {
    wisp_display_layer_set_req_t m = {id, z, flags, alpha, x, y, w, h, cw, ch, sx, sy};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_LAYER_SET, 0, &wisp_display_layer_set_req_desc, &m);
}
static void fill(harness *t, uint8_t id, uint8_t v, int16_t x, int16_t y, uint16_t w, uint16_t h) {
    wisp_display_fill_req_t m = {id, v, x, y, w, h};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_FILL, 0, &wisp_display_fill_req_desc, &m);
}
static void commit(harness *t, uint16_t req) {
    wisp_display_commit_req_t m = {0};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_COMMIT, req, &wisp_display_commit_req_desc, &m);
}

static void put(harness *t, uint16_t id, uint8_t type, uint8_t flags, const uint8_t *data, size_t len, uint16_t req) {
    wisp_resource_put_begin_req_t b;
    memset(&b, 0, sizeof b);
    b.res = id;
    b.type = type;
    b.flags = flags;
    b.size = (uint32_t)len;
    uint8_t d[32];
    wisp_sha256(data, len, d);
    memcpy(b.hash, d, 16);
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_BEGIN, req, &wisp_resource_put_begin_req_desc, &b);
    const sent_msg *m = rsp(t, req);
    CHECK(m && !(m->body[1] & WISP_MF_ERROR));
    if (!m || (m->body[1] & WISP_MF_ERROR) || m->body[4] == WISP_PUT_PRESENT) return;
    for (size_t off = 0; off < len; off += 1000) {
        wisp_resource_put_data_req_t pd = {id, (uint32_t)off, {data + off, len - off < 1000 ? len - off : 1000}};
        rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_DATA, 0, &wisp_resource_put_data_req_desc, &pd);
    }
    wisp_resource_put_end_req_t e = {id};
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_END, (uint16_t)(req + 1), &wisp_resource_put_end_req_desc, &e);
}

static void fb_hash(const uint8_t *fb, char out[17]) {
    uint8_t d[32];
    wisp_sha256(fb, STRIDE * H, d);
    for (int i = 0; i < 8; i++) sprintf(out + 2 * i, "%02x", d[i]);
}

/* ---- sha256 ---- */

static void hex32(const uint8_t *d, char *out) {
    for (int i = 0; i < 32; i++) sprintf(out + 2 * i, "%02x", d[i]);
}

static void test_sha256(void) {
    uint8_t d[32];
    char s[65];
    wisp_sha256("abc", 3, d);
    hex32(d, s);
    CHECK(!strcmp(s, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    wisp_sha256("", 0, d);
    hex32(d, s);
    CHECK(!strcmp(s, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    const char *m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    wisp_sha256(m, strlen(m), d);
    hex32(d, s);
    CHECK(!strcmp(s, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
    /* a million 'a', fed in odd chunks */
    static uint8_t a[1000];
    memset(a, 'a', sizeof a);
    wisp_sha256_ctx c;
    wisp_sha256_init(&c);
    size_t left = 1000000;
    uint32_t seed = 3;
    while (left) {
        size_t n = 1 + rnd(&seed) % 999;
        if (n > left) n = left;
        wisp_sha256_update(&c, a, n);
        left -= n;
    }
    wisp_sha256_final(&c, d);
    hex32(d, s);
    CHECK(!strcmp(s, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
}

/* ---- pool ---- */

static void test_pool(void) {
    static uint8_t mem[64 * 1024];
    wisp_pool p;
    wisp_pool_init(&p, mem + 3, sizeof mem - 3);
    uint8_t *blk[64] = {0};
    size_t sz[64] = {0};
    uint32_t seed = 9;
    for (int it = 0; it < 20000; it++) {
        int i = (int)(rnd(&seed) % 64);
        if (blk[i]) {
            for (size_t k = 0; k < sz[i]; k++) CHECK(blk[i][k] == (uint8_t)(i * 31 + k));
            wisp_pool_free(&p, blk[i]);
            CHECK(blk[i] == NULL);
        } else {
            sz[i] = rnd(&seed) % 3000;
            if (wisp_pool_alloc(&p, sz[i], (void **)&blk[i])) {
                CHECK(((uintptr_t)blk[i] & 7) == 0);
                for (size_t k = 0; k < sz[i]; k++) blk[i][k] = (uint8_t)(i * 31 + k);
            } else {
                CHECK(blk[i] == NULL && wisp_pool_cost(sz[i]) > wisp_pool_free_bytes(&p));
            }
        }
    }
    CHECK(p.compactions > 0);
    for (int i = 0; i < 64; i++) {
        for (size_t k = 0; blk[i] && k < sz[i]; k++) CHECK(blk[i][k] == (uint8_t)(i * 31 + k));
        wisp_pool_free(&p, blk[i]);
    }
    CHECK(p.used == 0);
}

/* ---- compositor against a per-pixel model ---- */

typedef struct {
    bool used, visible;
    uint8_t z, blend, alpha;
    int x, y, w, h, cw, ch, sx, sy;
    uint8_t px[700 * 500]; /* one byte per pixel */
} ref_layer;
static ref_layer ref[16];

static void ref_frame(uint8_t *fb) {
    int order[16], n = 0;
    for (int z = 0; z < 256; z++)
        for (int i = 0; i < 16; i++)
            if (ref[i].used && ref[i].visible && ref[i].z == z) order[n++] = i;
    for (int Y = 0; Y < H; Y++)
        for (int X = 0; X < W; X++) {
            unsigned v = 0;
            for (int k = 0; k < n; k++) {
                const ref_layer *l = &ref[order[k]];
                if (X < l->x || X >= l->x + l->w || Y < l->y || Y >= l->y + l->h) continue;
                int cx = X - l->x + l->sx, cy = Y - l->y + l->sy;
                if (cx < 0 || cy < 0 || cx >= l->cw || cy >= l->ch) continue;
                unsigned s = (l->px[cy * l->cw + cx] * l->alpha + 7u) / 15u;
                if (l->blend == 0 && s) v = s;
                if (l->blend == 1 && s > v) v = s;
                if (l->blend == 2) v = v + s > 15 ? 15 : v + s;
            }
            wisp_px_set(fb + Y * STRIDE, X, (uint8_t)v);
        }
}

static void test_compose_random(uint32_t seed) {
    harness *t = malloc(sizeof *t);
    static uint8_t want[STRIDE * H];
    h_init(t, false, 1 << 20);
    hello(t, "test");
    memset(ref, 0, sizeof ref);
    for (int round = 0; round < 6; round++) {
        for (int k = 0; k < 12; k++) {
            uint8_t id = (uint8_t)(rnd(&seed) % 6);
            ref_layer *l = &ref[id];
            unsigned op = rnd(&seed) % 4;
            if (op == 0 || !l->used) {
                int w = (int)(rnd(&seed) % 300) + 1, h = (int)(rnd(&seed) % 300) + 1;
                int cw = rnd(&seed) % 2 ? w : w + (int)(rnd(&seed) % 50), ch = rnd(&seed) % 2 ? h : h + (int)(rnd(&seed) % 50);
                bool resize = !l->used || cw != l->cw || ch != l->ch;
                l->used = true;
                l->visible = rnd(&seed) % 8 != 0;
                l->z = (uint8_t)(rnd(&seed) % 4);
                l->blend = (uint8_t)(rnd(&seed) % 3);
                l->alpha = (uint8_t)(rnd(&seed) % 3 ? 15 : rnd(&seed) % 16);
                l->x = (int)(rnd(&seed) % 700) - 50;
                l->y = (int)(rnd(&seed) % 540) - 30;
                l->w = w, l->h = h, l->cw = cw, l->ch = ch;
                l->sx = (int)(rnd(&seed) % 60) - 10;
                l->sy = (int)(rnd(&seed) % 60) - 10;
                if (resize) memset(l->px, 0, sizeof l->px);
                layer(t, id, l->z, (uint8_t)(l->visible | l->blend << 1), l->alpha, (int16_t)l->x, (int16_t)l->y,
                      (uint16_t)w, (uint16_t)h, (uint16_t)cw, (uint16_t)ch, (int16_t)l->sx, (int16_t)l->sy);
            } else if (op == 1) {
                int x = (int)(rnd(&seed) % 400) - 40, y = (int)(rnd(&seed) % 400) - 40;
                int w = (int)(rnd(&seed) % 200), h = (int)(rnd(&seed) % 200);
                uint8_t v = (uint8_t)(rnd(&seed) % 16);
                for (int yy = y; yy < y + h; yy++)
                    for (int xx = x; xx < x + w; xx++)
                        if (xx >= 0 && yy >= 0 && xx < l->cw && yy < l->ch) l->px[yy * l->cw + xx] = v;
                fill(t, id, v, (int16_t)x, (int16_t)y, (uint16_t)w, (uint16_t)h);
            } else if (op == 2) {
                /* inline RAW4 image at an odd or even offset, with zeros (opaque copy) */
                int w = (int)(rnd(&seed) % 60) + 1, h = (int)(rnd(&seed) % 40) + 1;
                int x = (int)(rnd(&seed) % 300) - 20, y = (int)(rnd(&seed) % 300) - 20;
                static uint8_t img[30 * 40 + 64];
                size_t st = (size_t)(w + 1) / 2;
                memset(img, 0, sizeof img);
                for (int yy = 0; yy < h; yy++)
                    for (int xx = 0; xx < w; xx++) {
                        uint8_t v = (uint8_t)(rnd(&seed) % 4 ? rnd(&seed) % 16 : 0);
                        wisp_px_set(img + yy * st, xx, v);
                        int X = x + xx, Y = y + yy;
                        if (X >= 0 && Y >= 0 && X < l->cw && Y < l->ch) l->px[Y * l->cw + X] = v;
                    }
                wisp_display_image_req_t m = {id, WISP_CODEC_RAW4, (int16_t)x, (int16_t)y, (uint16_t)w, (uint16_t)h,
                                              {img, st * (size_t)h}};
                rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_IMAGE, 0, &wisp_display_image_req_desc, &m);
            } else {
                /* move / scroll only */
                l->x += (int)(rnd(&seed) % 41) - 20;
                l->sy += (int)(rnd(&seed) % 11) - 5;
                layer(t, id, l->z, (uint8_t)(l->visible | l->blend << 1), l->alpha, (int16_t)l->x, (int16_t)l->y,
                      (uint16_t)l->w, (uint16_t)l->h, (uint16_t)l->cw, (uint16_t)l->ch, (int16_t)l->sx, (int16_t)l->sy);
            }
        }
        commit(t, 0);
        ref_frame(want);
        bool same = !memcmp(t->fb, want, sizeof want);
        CHECK(same);
        if (!same) {
            for (int i = 0; i < STRIDE * H; i++)
                if (t->fb[i] != want[i]) {
                    fprintf(stderr, "seed %u round %d: first diff at x=%d y=%d got %02x want %02x\n", seed, round,
                            (i % STRIDE) * 2, i / STRIDE, t->fb[i], want[i]);
                    break;
                }
            break;
        }
    }
    free(t);
}

/* Dirty regions: a small change presents only its rect; golden hashes of fixed scenes. */
static void test_compose_dirty(void) {
    harness *t = malloc(sizeof *t);
    h_init(t, false, 1 << 20);
    hello(t, "test");
    layer(t, 0, 0, 1, 15, 0, 0, W, H, 0, 0, 0, 0);
    fill(t, 0, 3, 0, 0, W, H);
    layer(t, 1, 1, 1, 15, 101, 51, 200, 100, 0, 0, 0, 0);
    fill(t, 1, 15, 10, 10, 50, 50);
    commit(t, 5);
    const sent_msg *m = rsp(t, 5);
    CHECK(m && m->len == 4 + 12 && wisp_get32(m->body + 4) == 1);
    CHECK(t->presented_px == W * H && t->frames_done == 1);
    char hash[17];
    fb_hash(t->fb, hash);
    CHECK(!strcmp(hash, "27451d0a511d6d83"));
    if (strcmp(hash, "27451d0a511d6d83")) fprintf(stderr, "scene A hash %s\n", hash);

    /* 7×5 change at an odd x: presents one rect of even bounds around it */
    t->presented_px = 0;
    t->npresented = 0;
    fill(t, 1, 9, 0, 0, 7, 5);
    commit(t, 0);
    CHECK(t->npresented == 1 && t->presented[0].x0 == 100 && t->presented[0].x1 == 108 &&
          t->presented[0].y0 == 51 && t->presented[0].y1 == 56);
    /* nothing pending: nothing presented */
    t->npresented = 0;
    commit(t, 0);
    CHECK(t->npresented == 0);
    /* moving a layer damages its old and new places only */
    layer(t, 1, 1, 1, 15, 121, 51, 200, 100, 0, 0, 0, 0);
    commit(t, 0);
    bool span = t->npresented == 7 && t->presented[0].y0 == 51 && t->presented[6].y1 == 151;
    for (unsigned i = 0; i < t->npresented; i++) span &= t->presented[i].x0 == 100 && t->presented[i].x1 == 322;
    CHECK(span);
    /* translucent max layer + additive layer */
    layer(t, 2, 2, 1 | WISP_BLEND_MAX << 1, 8, 0, 300, 640, 100, 0, 0, 0, 0);
    fill(t, 2, 15, 0, 0, 640, 100);
    layer(t, 3, 3, 1 | WISP_BLEND_ADD << 1, 15, 300, 0, 40, 480, 0, 0, 0, 0);
    fill(t, 3, 7, 0, 0, 40, 480);
    commit(t, 0);
    fb_hash(t->fb, hash);
    CHECK(!strcmp(hash, "c7f60842295a749f"));
    if (strcmp(hash, "c7f60842295a749f")) fprintf(stderr, "scene B hash %s\n", hash);
    uint8_t px = wisp_px_get(t->fb + 350 * STRIDE, 10); /* max(3, 15*8/15=8) */
    CHECK(px == 8);
    px = wisp_px_get(t->fb + 350 * STRIDE, 310); /* 8 + 7 = 15 */
    CHECK(px == 15);
    px = wisp_px_get(t->fb + 10 * STRIDE, 310); /* 3 + 7 */
    CHECK(px == 10);
    free(t);
}

static void test_scroll(void) {
    harness *t = malloc(sizeof *t);
    h_init(t, false, 1 << 20);
    hello(t, "test");
    for (int dx = -3; dx <= 3; dx++)
        for (int dy = -2; dy <= 2; dy++) {
            uint16_t cw = (uint16_t)(dx & 1 ? 31 : 30), ch = 9;
            layer(t, 0, 0, 1, 15, 0, 0, cw, ch, 0, 0, 0, 0);
            uint8_t want[40][40];
            static uint8_t img[16 * 9];
            for (int y = 0; y < ch; y++)
                for (int x = 0; x < cw; x++) {
                    uint8_t v = (uint8_t)((x * 3 + y * 5) % 15 + 1);
                    wisp_px_set(img + y * ((cw + 1) / 2), x, v);
                }
            wisp_display_image_req_t im = {0, WISP_CODEC_RAW4, 0, 0, cw, ch, {img, (size_t)(cw + 1) / 2 * ch}};
            rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_IMAGE, 0, &wisp_display_image_req_desc, &im);
            for (int y = 0; y < ch; y++)
                for (int x = 0; x < cw; x++) {
                    int fx = x - dx, fy = y - dy;
                    want[y][x] = fx >= 0 && fy >= 0 && fx < cw && fy < ch ? wisp_px_get(img + fy * ((cw + 1) / 2), fx) : 2;
                }
            wisp_display_scroll_req_t s = {0, (int16_t)dx, (int16_t)dy, 2};
            rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_SCROLL, 0, &wisp_display_scroll_req_desc, &s);
            const wisp_layer *l = wisp_display_layer(&t->e.display, 0);
            bool ok = true;
            for (int y = 0; y < ch; y++)
                for (int x = 0; x < cw; x++) ok &= wisp_px_get(l->buf + y * l->stride, x) == want[y][x];
            if (cw & 1)
                for (int y = 0; y < ch; y++) ok &= (l->buf[y * l->stride + l->stride - 1] & 0xf) == 0;
            CHECK(ok);
            if (!ok) fprintf(stderr, "scroll dx=%d dy=%d wrong\n", dx, dy);
        }
    free(t);
}

/* ---- resources ---- */

static size_t image_res(uint8_t *out, uint16_t w, uint16_t h, uint8_t codec, uint8_t seed) {
    static uint8_t raw[STRIDE * H];
    size_t st = (w + 1u) / 2u;
    memset(raw, 0, st * h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) wisp_px_set(raw + y * st, x, (uint8_t)(((x / 4 + y / 3) ^ seed) & 15));
    wisp_put16(out, w);
    wisp_put16(out + 2, h);
    out[4] = 4;
    out[5] = codec;
    int n;
    static uint8_t rle[W * H];
    static uint32_t table[WISP_LZ4_TABLE];
    switch (codec) {
    case WISP_CODEC_RLE4: n = wisp_rle4_encode(raw, w, h, out + 6, 200000); break;
    case WISP_CODEC_LZ4: n = wisp_lz4_encode(raw, st * h, out + 6, 200000, table); break;
    case WISP_CODEC_LZ4_RLE:
        n = wisp_rle4_encode(raw, w, h, rle, sizeof rle);
        n = wisp_lz4_encode(rle, (size_t)n, out + 6, 200000, table);
        break;
    default: memcpy(out + 6, raw, st * h); n = (int)(st * h);
    }
    return 6 + (size_t)n;
}

static void test_resources(void) {
    harness *t = malloc(sizeof *t);
    static uint8_t res[200000];
    memset(store, 0, sizeof store);
    h_init(t, true, 256 * 1024);
    hello(t, "app.one");

    /* every codec decodes to the same pixels: blit them side by side and compare */
    layer(t, 0, 0, 1, 15, 0, 0, W, H, 0, 0, 0, 0);
    for (uint8_t codec = 0; codec < 4; codec++) {
        size_t n = image_res(res, 33, 21, codec, 5);
        put(t, (uint16_t)(10 + codec), WISP_RES_IMAGE, 0, res, n, (uint16_t)(100 + 2 * codec));
        CHECK(rsp_error(t, (uint16_t)(101 + 2 * codec)) == 0);
        wisp_display_blit_req_t b = {0, 0, (int16_t)(codec * 40 + 1), 7, (uint16_t)(10 + codec), 0, 0, 0, 0};
        rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_BLIT, 0, &wisp_display_blit_req_desc, &b);
    }
    const wisp_layer *l = wisp_display_layer(&t->e.display, 0);
    bool same = true;
    for (int y = 0; y < 21; y++)
        for (int x = 0; x < 33; x++)
            for (int c = 1; c < 4; c++)
                same &= wisp_px_get(l->buf + (7 + y) * l->stride, 1 + x) ==
                        wisp_px_get(l->buf + (7 + y) * l->stride, c * 40 + 1 + x);
    CHECK(same && wisp_px_get(l->buf + 7 * l->stride, 1) == 5);

    /* sub-rect blit, transparent */
    fill(t, 0, 9, 200, 200, 10, 10);
    wisp_display_blit_req_t b = {0, 1, 200, 200, 10, 0, 0, 10, 10};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_BLIT, 0, &wisp_display_blit_req_desc, &b);
    /* pixel (0,0) of the image has value 5, (4..7,3..5) has (1^5)=4; zeros keep the 9 */
    CHECK(wisp_px_get(l->buf + 200 * l->stride, 200) == 5);

    /* already present: same id + hash skips; different hash re-uploads */
    size_t n = image_res(res, 33, 21, WISP_CODEC_RLE4, 5);
    put(t, 11, WISP_RES_IMAGE, 0, res, n, 120);
    CHECK(rsp(t, 120)->body[4] == WISP_PUT_PRESENT);
    n = image_res(res, 33, 21, WISP_CODEC_RLE4, 6);
    put(t, 11, WISP_RES_IMAGE, 0, res, n, 122);
    CHECK(rsp(t, 122)->body[4] == WISP_PUT_SEND && rsp_error(t, 123) == 0);

    /* hash mismatch */
    wisp_resource_put_begin_req_t pb;
    memset(&pb, 0, sizeof pb);
    pb.res = 20;
    pb.type = WISP_RES_BLOB;
    pb.size = 4;
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_BEGIN, 130, &wisp_resource_put_begin_req_desc, &pb);
    wisp_resource_put_data_req_t pd = {20, 0, {(const uint8_t *)"abcd", 4}};
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_DATA, 0, &wisp_resource_put_data_req_desc, &pd);
    wisp_resource_put_end_req_t pe = {20};
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_END, 131, &wisp_resource_put_end_req_desc, &pe);
    CHECK(rsp_error(t, 131) == WISP_ERR_HASH_MISMATCH);
    /* too big for the pool */
    pb.size = 300000;
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_PUT_BEGIN, 132, &wisp_resource_put_begin_req_desc, &pb);
    CHECK(rsp_error(t, 132) == WISP_ERR_NO_MEMORY);
    /* a corrupt image (RLE4 that covers too few pixels) is refused at PUT_END */
    uint8_t bad[8] = {4, 0, 4, 0, 4, WISP_CODEC_RLE4, 0x30, 0x30};
    put(t, 21, WISP_RES_IMAGE, 0, bad, sizeof bad, 134);
    CHECK(rsp_error(t, 135) == WISP_ERR_BAD_PAYLOAD);

    /* persisted blob: written to storage, listed, survives the session, loaded on demand */
    put(t, 30, WISP_RES_BLOB, WISP_RES_PERSIST, (const uint8_t *)"persist me", 10, 140);
    CHECK(rsp_error(t, 141) == 0 && store[0].used && !strcmp(store[0].app, "app.one"));
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_LIST, 150, NULL, NULL);
    const sent_msg *m = rsp(t, 150);
    CHECK(m && wisp_get16(m->body + 4) == 5 && m->len == 4 + 2 + 5 * 24);

    /* another app sees nothing of app.one */
    hello(t, "app.two");
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_LIST, 151, NULL, NULL);
    CHECK(wisp_get16(rsp(t, 151)->body + 4) == 0);
    layer(t, 0, 0, 1, 15, 0, 0, W, H, 0, 0, 0, 0);
    b.res = 10;
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_BLIT, 152, &wisp_display_blit_req_desc, &b);
    CHECK(rsp_error(t, 152) == WISP_ERR_NO_SUCH_ID);

    /* back to app.one: RAM resources of the old session are gone, the persisted one is there */
    hello(t, "app.one");
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_LIST, 153, NULL, NULL);
    m = rsp(t, 153);
    CHECK(wisp_get16(m->body + 4) == 1 && wisp_get16(m->body + 6) == 30);
    /* drop the RAM copy behind the engine's back: PUT_BEGIN still finds it in storage */
    for (uint16_t i = 0; i < t->e.res.max; i++)
        if (t->e.res.tab[i].state) {
            wisp_pool_free(&t->e.res.pool, t->e.res.tab[i].data);
            memset(&t->e.res.tab[i], 0, sizeof t->e.res.tab[i]);
        }
    put(t, 30, WISP_RES_BLOB, WISP_RES_PERSIST, (const uint8_t *)"persist me", 10, 154);
    CHECK(rsp(t, 154)->body[4] == WISP_PUT_PRESENT);
    CHECK(wisp_res_get(&t->e.res, t->e.app, 30, WISP_RES_BLOB) != NULL && t->e.res.loads == 1);
    /* delete removes it from storage too */
    wisp_resource_delete_req_t del = {30};
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_DELETE, 155, &wisp_resource_delete_req_desc, &del);
    CHECK(rsp_error(t, 155) == 0 && !store[0].used);
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_DELETE, 156, &wisp_resource_delete_req_desc, &del);
    CHECK(rsp_error(t, 156) == WISP_ERR_NO_SUCH_ID);

    /* eviction: cached persisted resources make room, and come back from storage on use */
    wisp_resource_delete_req_t all = {WISP_RES_ALL};
    rx(t, WISP_SVC_RESOURCE, WISP_OP_RESOURCE_DELETE, 159, &wisp_resource_delete_req_desc, &all);
    CHECK(t->e.res.pool.used == 0);
    static uint8_t blob[63000];
    for (uint16_t i = 0; i < 7; i++) {
        memset(blob, (int)i, sizeof blob);
        bool small = i < 3;
        put(t, (uint16_t)(40 + i), WISP_RES_BLOB, small ? WISP_RES_PERSIST : 0, blob, small ? 4000 : sizeof blob,
            (uint16_t)(160 + 2 * i));
        CHECK(rsp_error(t, (uint16_t)(161 + 2 * i)) == 0);
    }
    CHECK(t->e.res.evictions >= 1);
    const wisp_res *back = wisp_res_get(&t->e.res, t->e.app, 40, WISP_RES_BLOB);
    CHECK(back && back->len == 4000 && back->data[3999] == 0 && t->e.res.loads >= 2);
    free(t);
}

/* ---- text ---- */

/* A 3×5 font with 'A', 'B', ' ', '?' and 'é'. */
static size_t make_font(uint8_t *out) {
    static const char *glyphs[] = {
        " # "
        "# #"
        "###"
        "# #"
        "# #",
        "## "
        "###"
        "## "
        "# #"
        "## ",
        "###"
        "  #"
        " # "
        "   "
        " # ",
        " # "
        "###"
        "#  "
        "## "
        "###",
    };
    const uint32_t cps[] = {' ', '?', 'A', 'B', 0xE9};
    size_t n = 4 + 13 * 5, off = 0;
    out[0] = 7; /* line_h */
    out[1] = 6; /* baseline */
    wisp_put16(out + 2, 5);
    uint8_t *bm = out + 4 + 13 * 5;
    for (int g = 0; g < 5; g++) {
        uint8_t *e = out + 4 + 13 * g;
        wisp_put32(e, cps[g]);
        bool space = g == 0;
        e[4] = space ? 0 : 3;
        e[5] = space ? 0 : 5;
        e[6] = 0;
        e[7] = (uint8_t)(int8_t)-5;
        e[8] = 4;
        wisp_put32(e + 9, (uint32_t)off);
        if (space) continue;
        const char *s = glyphs[g == 1 ? 2 : g == 2 ? 0 : g == 3 ? 1 : 3];
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 3; x++) wisp_px_set(bm + off + (size_t)y * 2, x, s[y * 3 + x] == '#' ? 15 : 0);
        off += 10;
    }
    return n + off;
}

static void text(harness *t, uint16_t req, int16_t x, int16_t y, uint16_t max_w, const char *s) {
    wisp_display_text_req_t m = {0, 15, x, y, 1, max_w, 0, {(const uint8_t *)s, strlen(s)}};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TEXT, req, &wisp_display_text_req_desc, &m);
}

static void test_text(void) {
    harness *t = malloc(sizeof *t);
    static uint8_t font[400];
    h_init(t, false, 1 << 20);
    hello(t, "test");
    size_t n = make_font(font);
    put(t, 1, WISP_RES_FONT, 0, font, n, 10);
    CHECK(rsp_error(t, 11) == 0);
    layer(t, 0, 0, 1, 15, 0, 0, 64, 21, 0, 0, 0, 0);
    text(t, 20, 1, 0, 0, "AB");
    const sent_msg *m = rsp(t, 20);
    CHECK(m && wisp_get16(m->body + 4) == 8 && wisp_get16(m->body + 6) == 7 && wisp_get16(m->body + 8) == 2);
    const wisp_layer *l = wisp_display_layer(&t->e.display, 0);
    /* 'A' top row " # " at baseline 6 - 5 = 1 */
    CHECK(wisp_px_get(l->buf + 1 * l->stride, 2) == 15 && wisp_px_get(l->buf + 1 * l->stride, 1) == 0);
    /* 'B' starts at x = 1 + 4 */
    CHECK(wisp_px_get(l->buf + 1 * l->stride, 5) == 15);

    /* wrapping at spaces: "AB AB AB" at max_w 20 → "AB AB" (20 px) / "AB" */
    text(t, 21, 0, 0, 20, "AB AB AB");
    m = rsp(t, 21);
    CHECK(wisp_get16(m->body + 4) == 20 && wisp_get16(m->body + 6) == 14 && wisp_get16(m->body + 8) == 8);
    /* a word wider than max_w breaks between characters; unknown chars draw as '?' */
    text(t, 22, 0, 0, 8, "ABAZ");
    m = rsp(t, 22);
    CHECK(wisp_get16(m->body + 4) == 8 && wisp_get16(m->body + 6) == 14 && wisp_get16(m->body + 8) == 4);
    /* UTF-8 and '\n'; content is 21 px high: the 4th line doesn't start, chars_drawn tells */
    text(t, 23, 0, 0, 0, "\xC3\xA9\nA\nB\nAB");
    m = rsp(t, 23);
    CHECK(wisp_get16(m->body + 6) == 21 && wisp_get16(m->body + 8) == 6);
    /* bad font id */
    wisp_display_text_req_t bad = {0, 15, 0, 0, 9, 0, 0, {(const uint8_t *)"A", 1}};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TEXT, 24, &wisp_display_text_req_desc, &bad);
    CHECK(rsp_error(t, 24) == WISP_ERR_NO_SUCH_ID);
    /* invalid fonts are refused */
    font[4 + 13 + 9] = 200; /* glyph 1's offset past the bitmaps */
    put(t, 2, WISP_RES_FONT, 0, font, n, 30);
    CHECK(rsp_error(t, 31) == WISP_ERR_BAD_PAYLOAD);

    size_t pos = 0;
    CHECK(wisp_utf8_next((const uint8_t *)"\xE2\x82\xAC", 3, &pos) == 0x20AC && pos == 3);
    pos = 0;
    CHECK(wisp_utf8_next((const uint8_t *)"\xC0\xAF", 2, &pos) == 0xFFFD); /* overlong */
    pos = 0;
    CHECK(wisp_utf8_next((const uint8_t *)"\xE2\x82", 2, &pos) == 0xFFFD && pos == 1);
    free(t);
}

/* ---- animation and tweens ---- */

static uint8_t frames_raw[5][8 * 6];

static size_t make_anim(uint8_t *out, uint8_t codec) {
    const uint16_t w = 15, h = 6; /* odd width */
    const size_t st = (w + 1u) / 2u, size = st * h;
    static uint32_t table[WISP_LZ4_TABLE];
    wisp_put16(out, w);
    wisp_put16(out + 2, h);
    wisp_put16(out + 4, 5);
    out[6] = codec;
    size_t n = 7;
    for (int f = 0; f < 5; f++) {
        memset(frames_raw[f], 0, size);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) wisp_px_set(frames_raw[f] + y * st, x, (uint8_t)(x == f * 3 || y == f ? 15 : 1));
        uint8_t px[64];
        memcpy(px, frames_raw[f], size);
        uint8_t kind = f % 2; /* key, delta, key, delta, key */
        if (kind) wisp_xor(px, frames_raw[f - 1], size);
        int k;
        if (codec == WISP_CODEC_RAW4) {
            memcpy(out + n + 7, px, size);
            k = (int)size;
        } else if (codec == WISP_CODEC_RLE4) {
            k = wisp_rle4_encode(px, w, h, out + n + 7, 1000);
        } else {
            k = wisp_lz4_encode(px, size, out + n + 7, 1000, table);
        }
        wisp_put16(out + n, (uint16_t)(10 * (f + 1)));
        out[n + 2] = kind;
        wisp_put32(out + n + 3, (uint32_t)k);
        n += 7 + (size_t)k;
    }
    return n;
}

static bool layer_shows(harness *t, int f, int16_t x, int16_t y) {
    const wisp_layer *l = wisp_display_layer(&t->e.display, 0);
    bool ok = true;
    for (int yy = 0; yy < 6; yy++)
        for (int xx = 0; xx < 15; xx++)
            ok &= wisp_px_get(l->buf + (y + yy) * l->stride, x + xx) == wisp_px_get(frames_raw[f] + yy * 8, xx);
    /* and on the panel (auto-commit) */
    for (int yy = 0; yy < 6; yy++)
        for (int xx = 0; xx < 15; xx++)
            ok &= wisp_px_get(t->fb + (y + yy) * STRIDE, x + xx) == wisp_px_get(frames_raw[f] + yy * 8, xx);
    return ok;
}

static void test_anim(void) {
    harness *t = malloc(sizeof *t);
    static uint8_t a[4000];
    for (uint8_t codec = 0; codec < 3; codec++) {
        h_init(t, false, 1 << 20);
        hello(t, "test");
        size_t n = make_anim(a, codec);
        put(t, 5, WISP_RES_ANIM, 0, a, n, 10);
        CHECK(rsp_error(t, 11) == 0);
        layer(t, 0, 0, 1, 15, 0, 0, 100, 50, 0, 0, 0, 0);
        wisp_display_anim_play_req_t p = {1, 0, 3, 2, 5, 2, 0};
        uint32_t frames0 = t->e.display.frame;
        rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_ANIM_PLAY, 12, &wisp_display_anim_play_req_desc, &p);
        CHECK(rsp_error(t, 12) == 0 && layer_shows(t, 0, 3, 2) && t->e.display.frame == frames0 + 1);
        /* frame k is due after durations 10, 20, … ms */
        uint64_t t0 = t->now;
        wisp_engine_tick(&t->e, t0 + 9999);
        CHECK(layer_shows(t, 0, 3, 2));
        wisp_engine_tick(&t->e, t0 + 10000);
        CHECK(layer_shows(t, 1, 3, 2));
        wisp_engine_tick(&t->e, t0 + 60000); /* skips frame 2, applies its key + delta 3 */
        CHECK(layer_shows(t, 3, 3, 2));
        wisp_engine_tick(&t->e, t0 + 100000);
        CHECK(layer_shows(t, 4, 3, 2));
        wisp_engine_tick(&t->e, t0 + 150000); /* loop 2, frame 0 */
        CHECK(layer_shows(t, 0, 3, 2) && wisp_engine_busy(&t->e));
        wisp_engine_tick(&t->e, t0 + 300000); /* past the end of loop 2 */
        CHECK(!t->e.anims[1].active && layer_shows(t, 4, 3, 2));
        const sent_msg *m = &t->log[t->nlog - 1];
        CHECK(m->svc == WISP_SVC_DISPLAY && m->body[0] == WISP_OP_DISPLAY_ANIM_DONE && m->body[1] == WISP_MF_EVENT &&
              m->body[4] == 1);
        CHECK(!wisp_engine_busy(&t->e));
        /* the player's buffer went back to the pool, and so does the layer's after CLEAR_ALL */
        rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_CLEAR_ALL, 0, NULL, NULL);
        CHECK(t->e.gfx.used == 0);
    }
    /* a malformed animation (first frame a delta) is refused */
    size_t n = make_anim(a, WISP_CODEC_RAW4);
    a[7 + 2] = 1;
    put(t, 6, WISP_RES_ANIM, 0, a, n, 20);
    CHECK(rsp_error(t, 21) == WISP_ERR_BAD_PAYLOAD);
    free(t);
}

static void test_tween(void) {
    CHECK(wisp_ease(WISP_EASE_LINEAR, 16384) == 16384);
    CHECK(wisp_ease(WISP_EASE_IN, 32768) == 16384);
    CHECK(wisp_ease(WISP_EASE_OUT, 32768) == 49152);
    CHECK(wisp_ease(WISP_EASE_IN_OUT, 16384) == 8192 && wisp_ease(WISP_EASE_IN_OUT, 49152) == 57344);
    CHECK(wisp_ease(WISP_EASE_IN_OUT, 65536) == 65536 && wisp_ease(WISP_EASE_OUT, 0) == 0);

    harness *t = malloc(sizeof *t);
    h_init(t, false, 1 << 20);
    hello(t, "test");
    layer(t, 0, 0, 1, 15, 10, 10, 20, 20, 0, 0, 0, 0);
    fill(t, 0, 15, 0, 0, 20, 20);
    commit(t, 0);
    wisp_display_tween_req_t tw = {0, WISP_PROP_X, WISP_EASE_LINEAR, 110, 100};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TWEEN, 1, &wisp_display_tween_req_desc, &tw);
    CHECK(rsp_error(t, 1) == 0);
    uint64_t t0 = t->now;
    t->npresented = 0;
    wisp_engine_tick(&t->e, t0 + 50000);
    const wisp_layer *l = wisp_display_layer(&t->e.display, 0);
    CHECK(l->x == 60 && t->npresented >= 1);
    CHECK(wisp_px_get(t->fb + 15 * STRIDE, 60) == 15 && wisp_px_get(t->fb + 15 * STRIDE, 59) == 0);
    /* a second tween on the same prop replaces the first; alpha runs alongside */
    tw.to = 0;
    tw.easing = WISP_EASE_IN_OUT;
    t->now = t0 + 50000;
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TWEEN, 0, &wisp_display_tween_req_desc, &tw);
    wisp_display_tween_req_t ta = {0, WISP_PROP_ALPHA, WISP_EASE_LINEAR, 0, 100};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TWEEN, 0, &wisp_display_tween_req_desc, &ta);
    wisp_engine_tick(&t->e, t0 + 100000);
    CHECK(l->x == 30 && l->alpha == 8);
    wisp_engine_tick(&t->e, t0 + 200000);
    CHECK(l->x == 0 && l->alpha == 0 && !wisp_engine_busy(&t->e));
    CHECK(wisp_px_get(t->fb + 15 * STRIDE, 5) == 0);
    /* zero duration jumps right away */
    wisp_display_tween_req_t ty = {0, WISP_PROP_Y, WISP_EASE_OUT, -5, 0};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TWEEN, 0, &wisp_display_tween_req_desc, &ty);
    CHECK(l->y == -5);
    /* bad prop */
    ty.prop = 9;
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_TWEEN, 3, &wisp_display_tween_req_desc, &ty);
    CHECK(rsp_error(t, 3) == WISP_ERR_BAD_PAYLOAD);
    free(t);
}

/* ---- input ---- */

static uint8_t gestures[16];
static unsigned ngestures;
static void on_g(void *ctx, uint8_t pad, uint8_t kind, uint64_t t_us) {
    (void)ctx, (void)pad, (void)t_us;
    if (ngestures < 16) gestures[ngestures++] = kind;
}

static void test_input(void) {
    wisp_input in;
    wisp_input_init(&in, 100);
    wisp_input_config_req_t c = {WISP_INPUT_GESTURES, 0, 0, 0};
    wisp_input_config(&in, &c);
    uint64_t t = 1000000;
#define TOUCH(ph, pos, dt) (t += (dt) * 1000u, wisp_input_touch(&in, 0, ph, pos, t, on_g, NULL))
#define TICK(dt) (t += (dt) * 1000u, wisp_input_tick(&in, t, on_g, NULL))
    ngestures = 0;
    TOUCH(WISP_TOUCH_DOWN, 500, 0);
    TOUCH(WISP_TOUCH_UP, 505, 80);
    TICK(100);
    CHECK(ngestures == 0); /* waiting for a second tap */
    TICK(200);
    CHECK(ngestures == 1 && gestures[0] == WISP_GESTURE_TAP);
    /* double tap */
    ngestures = 0;
    TOUCH(WISP_TOUCH_DOWN, 500, 0);
    TOUCH(WISP_TOUCH_UP, 500, 50);
    TOUCH(WISP_TOUCH_DOWN, 500, 100);
    TOUCH(WISP_TOUCH_UP, 500, 50);
    TICK(1000);
    CHECK(ngestures == 1 && gestures[0] == WISP_GESTURE_DOUBLE_TAP);
    /* long press */
    ngestures = 0;
    TOUCH(WISP_TOUCH_DOWN, 500, 0);
    TICK(300);
    CHECK(ngestures == 0);
    TICK(400);
    TOUCH(WISP_TOUCH_UP, 500, 500);
    CHECK(ngestures == 2 && gestures[0] == WISP_GESTURE_LONG_START && gestures[1] == WISP_GESTURE_LONG_END);
    /* swipes */
    ngestures = 0;
    TOUCH(WISP_TOUCH_DOWN, 500, 0);
    TOUCH(WISP_TOUCH_MOVE, 560, 50);
    TOUCH(WISP_TOUCH_UP, 650, 50);
    TOUCH(WISP_TOUCH_DOWN, 500, 400);
    TOUCH(WISP_TOUCH_UP, 300, 100);
    CHECK(ngestures == 2 && gestures[0] == WISP_GESTURE_SWIPE_FORWARD && gestures[1] == WISP_GESTURE_SWIPE_BACK);
    /* nothing when gestures are off */
    c.mask = WISP_INPUT_RAW;
    wisp_input_config(&in, &c);
    ngestures = 0;
    TOUCH(WISP_TOUCH_DOWN, 500, 0);
    TOUCH(WISP_TOUCH_UP, 500, 50);
    TICK(1000);
    CHECK(ngestures == 0);
#undef TOUCH
#undef TICK

    /* through the engine: events only after CONFIG, raw touch and gestures */
    harness *h = malloc(sizeof *h);
    h_init(h, false, 1 << 20);
    hello(h, "test");
    wisp_engine_touch(&h->e, 0, WISP_TOUCH_DOWN, 10, 2000);
    CHECK(h->nlog == 1); /* only the HELLO response */
    wisp_input_config_req_t ec = {WISP_INPUT_RAW | WISP_INPUT_GESTURES, 0, 0, 0};
    rx(h, WISP_SVC_INPUT, WISP_OP_INPUT_CONFIG, 2, &wisp_input_config_req_desc, &ec);
    wisp_engine_touch(&h->e, 0, WISP_TOUCH_DOWN, 10, 3000);
    wisp_engine_touch(&h->e, 0, WISP_TOUCH_UP, 10, 50000);
    wisp_engine_tick(&h->e, 400000);
    const sent_msg *m = &h->log[h->nlog - 1];
    CHECK(m->svc == WISP_SVC_INPUT && m->body[0] == WISP_OP_INPUT_GESTURE && m->body[1] == WISP_MF_EVENT &&
          m->body[5] == WISP_GESTURE_TAP && m->body[4] == 1);
    CHECK(h->log[h->nlog - 2].body[0] == WISP_OP_INPUT_TOUCH && h->log[h->nlog - 2].body[6] == WISP_TOUCH_UP);
    /* wear: subscribe, change, READ; display power follows off_when_unworn */
    wisp_sensor_subscribe_req_t sub = {WISP_SENSOR_WEAR, 0, 0};
    rx(h, WISP_SVC_SENSOR, WISP_OP_SENSOR_SUBSCRIBE, 3, &wisp_sensor_subscribe_req_desc, &sub);
    wisp_system_display_power_req_t dp = {1, 1, 0};
    rx(h, WISP_SVC_SYSTEM, WISP_OP_SYSTEM_DISPLAY_POWER, 4, &wisp_system_display_power_req_desc, &dp);
    wisp_engine_set_worn(&h->e, false, 500000);
    m = &h->log[h->nlog - 1];
    CHECK(m->svc == WISP_SVC_SENSOR && m->body[0] == WISP_OP_SENSOR_DATA && m->body[4] == WISP_SENSOR_WEAR &&
          m->body[5] == 1 && m->body[14] == 0 && !h->power);
    wisp_sensor_read_req_t rd = {WISP_SENSOR_WEAR};
    rx(h, WISP_SVC_SENSOR, WISP_OP_SENSOR_READ, 5, &wisp_sensor_read_req_desc, &rd);
    CHECK(rsp(h, 5)->len == 5 && rsp(h, 5)->body[4] == 0);
    wisp_engine_set_worn(&h->e, true, 600000);
    CHECK(h->power);
    sub.sensor = 1;
    rx(h, WISP_SVC_SENSOR, WISP_OP_SENSOR_SUBSCRIBE, 6, &wisp_sensor_subscribe_req_desc, &sub);
    CHECK(rsp_error(h, 6) == WISP_ERR_UNSUPPORTED);
    free(h);
}

/* ---- dispatcher and session ---- */

static void test_engine(void) {
    harness *t = malloc(sizeof *t);
    h_init(t, true, 1 << 20);
    /* before HELLO: error 7 */
    commit(t, 3);
    CHECK(rsp_error(t, 3) == WISP_ERR_NOT_ALLOWED);
    hello(t, "test");
    const sent_msg *m = rsp(t, 1);
    wisp_session_hello_rsp_t hr;
    CHECK(m && wisp_unpack(&wisp_session_hello_rsp_desc, m->body + 4, m->len - 4, &hr) == WISP_OK);
    CHECK(hr.max_layers == 16 && hr.canvas_w == W && hr.canvas_h == H && hr.bpp == 4 && hr.proto_major == 0);
    CHECK(hr.res_bytes > 1000000 && hr.res_bytes <= 1 << 20 && hr.persist_bytes == 1 << 20);
    CHECK((hr.caps & (WISP_CAP_DISPLAY | WISP_CAP_ANIMATION | WISP_CAP_TWEEN | WISP_CAP_TEXT | WISP_CAP_PERSIST |
                      WISP_CAP_GESTURES | WISP_CAP_RLE4 | WISP_CAP_LZ4 | WISP_CAP_DELTA)) ==
          (WISP_CAP_DISPLAY | WISP_CAP_ANIMATION | WISP_CAP_TWEEN | WISP_CAP_TEXT | WISP_CAP_PERSIST |
           WISP_CAP_GESTURES | WISP_CAP_RLE4 | WISP_CAP_LZ4 | WISP_CAP_DELTA));
    /* unknown op, unknown service, bad payload, no such layer, layer limit */
    rx(t, WISP_SVC_DISPLAY, 99, 4, NULL, NULL);
    CHECK(rsp_error(t, 4) == WISP_ERR_UNSUPPORTED);
    rx(t, WISP_SVC_AUDIO, 1, 5, NULL, NULL);
    CHECK(rsp_error(t, 5) == WISP_ERR_UNSUPPORTED);
    uint8_t cut[] = {WISP_OP_DISPLAY_FILL, 0, 6, 0, 0, 1, 2};
    wisp_session_result r;
    wisp_engine_rx(&t->e, WISP_SVC_DISPLAY, cut, sizeof cut, t->now, &r);
    CHECK(rsp_error(t, 6) == WISP_ERR_BAD_PAYLOAD);
    wisp_display_fill_req_t f = {3, 1, 0, 0, 1, 1};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_FILL, 7, &wisp_display_fill_req_desc, &f);
    CHECK(rsp_error(t, 7) == WISP_ERR_NO_SUCH_ID);
    wisp_display_layer_set_req_t ls = {16, 0, 1, 15, 0, 0, 10, 10, 0, 0, 0, 0};
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_LAYER_SET, 8, &wisp_display_layer_set_req_desc, &ls);
    CHECK(rsp_error(t, 8) == WISP_ERR_NO_MEMORY);
    ls.layer = 0;
    ls.content_w = 60000;
    ls.content_h = 60000;
    rx(t, WISP_SVC_DISPLAY, WISP_OP_DISPLAY_LAYER_SET, 9, &wisp_display_layer_set_req_desc, &ls);
    CHECK(rsp_error(t, 9) == WISP_ERR_NO_MEMORY);
    /* requests with req 0 get no response, errors included */
    unsigned before = t->nlog;
    rx(t, WISP_SVC_DISPLAY, 99, 0, NULL, NULL);
    CHECK(t->nlog == before);
    /* INFO, STATS */
    rx(t, WISP_SVC_SYSTEM, WISP_OP_SYSTEM_INFO, 10, NULL, NULL);
    m = rsp(t, 10);
    CHECK(m && !memcmp(m->body + 4, "test", 4));
    layer(t, 0, 0, 1, 15, 0, 0, W, H, 0, 0, 0, 0);
    commit(t, 0);
    rx(t, WISP_SVC_SYSTEM, WISP_OP_SYSTEM_STATS, 11, NULL, NULL);
    m = rsp(t, 11);
    wisp_system_stats_rsp_t st;
    CHECK(m && wisp_unpack(&wisp_system_stats_rsp_desc, m->body + 4, m->len - 4, &st) == WISP_OK);
    CHECK(st.frames == t->e.display.frame && st.heap_free < (3u << 20) + (1u << 20) && st.heap_free > (3u << 20));
    /* session timeout ends it: players stop, RAM resources go, the panel keeps its picture */
    put(t, 1, WISP_RES_BLOB, 0, (const uint8_t *)"x", 1, 20);
    CHECK(wisp_engine_tick(&t->e, t->now + 10000001) && !t->e.session.active);
    CHECK(t->e.res.pool.used == 0 && wisp_display_layer(&t->e.display, 0) != NULL);
    commit(t, 30);
    CHECK(rsp_error(t, 30) == WISP_ERR_NOT_ALLOWED);
    free(t);
}

int main(void) {
    test_sha256();
    test_pool();
    for (uint32_t seed = 1; seed <= 12; seed++) test_compose_random(seed * 2654435761u);
    test_compose_dirty();
    test_scroll();
    test_resources();
    test_text();
    test_anim();
    test_tween();
    test_input();
    test_engine();
    printf("engine: %s\n", test_failures ? "FAILED" : "ok");
    return test_failures != 0;
}
