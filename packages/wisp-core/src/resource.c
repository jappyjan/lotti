/* Wisp core: the resource store. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/codec.h"
#include "wisp/resource.h"
#include "wisp/sha256.h"

void wisp_res_init(wisp_resources *r, wisp_res *tab, uint16_t max, void *pool_mem, size_t pool_size,
                   const wisp_storage *storage) {
    memset(r, 0, sizeof *r);
    memset(tab, 0, sizeof *tab * max);
    r->tab = tab;
    r->max = max;
    r->storage = storage;
    wisp_pool_init(&r->pool, pool_mem, pool_size);
}

uint8_t wisp_res_app(wisp_resources *r, const char *app_id) {
    char id[17] = {0};
    for (unsigned i = 0; i < 16 && app_id[i]; i++) id[i] = app_id[i];
    for (uint8_t i = 0; i < WISP_APP_MAX; i++)
        if (r->apps[i][0] && !memcmp(r->apps[i], id, sizeof id)) return i;
    /* a free slot, or one no resource in RAM refers to */
    for (uint8_t i = 0; i < WISP_APP_MAX; i++) {
        bool busy = r->apps[i][0] != 0;
        if (busy) {
            busy = false;
            for (uint16_t k = 0; k < r->max && !busy; k++) busy = r->tab[k].state && r->tab[k].app == i;
        }
        if (!busy) {
            memcpy(r->apps[i], id, sizeof id);
            return i;
        }
    }
    return WISP_APP_MAX - 1; /* every slot busy: share the last one */
}

static wisp_res *find(wisp_resources *r, uint8_t app, uint16_t id) {
    for (uint16_t i = 0; i < r->max; i++)
        if (r->tab[i].state && r->tab[i].app == app && r->tab[i].id == id) return &r->tab[i];
    return NULL;
}

static void drop(wisp_resources *r, wisp_res *e) {
    wisp_pool_free(&r->pool, e->data);
    memset(e, 0, sizeof *e);
}

/* The least recently used cached persisted resource nobody plays. */
static wisp_res *victim(wisp_resources *r) {
    wisp_res *v = NULL;
    for (uint16_t i = 0; i < r->max; i++) {
        wisp_res *e = &r->tab[i];
        if (e->state == WISP_RES_READY && (e->flags & WISP_RES_PERSIST) && r->storage && !e->users &&
            (!v || e->stamp < v->stamp))
            v = e;
    }
    return v;
}

void *wisp_res_alloc(wisp_resources *r, size_t n, void **owner) {
    for (;;) {
        void *p = wisp_pool_alloc(&r->pool, n, owner);
        if (p || wisp_pool_cost(n) > r->pool.size) return p;
        wisp_res *v = victim(r);
        if (!v) return NULL;
        drop(r, v);
        r->evictions++;
    }
}

static wisp_res *slot(wisp_resources *r) {
    for (uint16_t i = 0; i < r->max; i++)
        if (!r->tab[i].state) return &r->tab[i];
    wisp_res *v = victim(r);
    if (v) {
        drop(r, v);
        r->evictions++;
    }
    return v;
}

/* ---- validation and preparation ---- */

bool wisp_font_open(const uint8_t *data, size_t len, wisp_font *f) {
    if (len < 4) return false;
    f->line_h = data[0];
    f->baseline = data[1];
    f->glyphs = wisp_get16(data + 2);
    size_t table = 13u * f->glyphs;
    if (len - 4 < table) return false;
    f->table = data + 4;
    f->bitmaps = data + 4 + table;
    f->bitmaps_len = len - 4 - table;
    return true;
}

static void glyph_at(const wisp_font *f, uint16_t i, uint32_t *cp, wisp_glyph *g) {
    const uint8_t *e = f->table + 13u * i;
    *cp = wisp_get32(e);
    g->w = e[4];
    g->h = e[5];
    g->x_off = (int8_t)e[6];
    g->y_off = (int8_t)e[7];
    g->advance = e[8];
    g->bits = f->bitmaps + wisp_get32(e + 9);
}

bool wisp_font_glyph(const wisp_font *f, uint32_t cp, wisp_glyph *g) {
    uint16_t lo = 0, hi = f->glyphs;
    while (lo < hi) {
        uint16_t mid = (uint16_t)((lo + hi) / 2u);
        uint32_t c;
        glyph_at(f, mid, &c, g);
        if (c == cp) return true;
        if (c < cp)
            lo = (uint16_t)(mid + 1u);
        else
            hi = mid;
    }
    return false;
}

static bool font_valid(const uint8_t *data, size_t len) {
    wisp_font f;
    if (!wisp_font_open(data, len, &f) || !f.line_h) return false;
    uint32_t prev = 0;
    for (uint16_t i = 0; i < f.glyphs; i++) {
        const uint8_t *e = f.table + 13u * i;
        uint32_t cp = wisp_get32(e), off = wisp_get32(e + 9);
        size_t need = (e[4] + 1u) / 2u * e[5];
        if ((i && cp <= prev) || off > f.bitmaps_len || need > f.bitmaps_len - off) return false;
        prev = cp;
    }
    return true;
}

static bool anim_valid(const uint8_t *data, size_t len, uint16_t *w, uint16_t *h) {
    if (len < WISP_ANIM_HDR) return false;
    *w = wisp_get16(data);
    *h = wisp_get16(data + 2);
    uint16_t frames = wisp_get16(data + 4);
    uint8_t codec = data[6];
    if (!*w || !*h || !frames || codec > WISP_CODEC_LZ4_RLE) return false;
    size_t p = WISP_ANIM_HDR;
    for (uint16_t i = 0; i < frames; i++) {
        if (len - p < WISP_ANIM_FRAME_HDR) return false;
        uint8_t kind = data[p + 2];
        uint32_t size = wisp_get32(data + p + 3);
        if (kind > 1 || (i == 0 && kind) || size > len - p - WISP_ANIM_FRAME_HDR) return false;
        p += WISP_ANIM_FRAME_HDR + size;
    }
    return true;
}

/* Turns verified upload bytes into their ready form; 0 or a WISP_ERR_* code. */
static int prepare(wisp_resources *r, wisp_res *e) {
    switch (e->type) {
    case WISP_RES_IMAGE: {
        if (e->len < 6) return WISP_ERR_BAD_PAYLOAD;
        uint16_t w = wisp_get16(e->data), h = wisp_get16(e->data + 2);
        uint8_t bpp = e->data[4], codec = e->data[5];
        if (bpp != 4 || codec > WISP_CODEC_LZ4_RLE) return WISP_ERR_BAD_PAYLOAD;
        size_t size = wisp_raw4_size(w, h);
        e->users++; /* not evicted while we allocate */
        uint8_t *raw, *scratch = NULL;
        size_t scratch_len = codec == WISP_CODEC_LZ4_RLE ? (size_t)w * h : 0;
        if (!wisp_res_alloc(r, size, (void **)&raw)) {
            e->users--;
            return WISP_ERR_NO_MEMORY;
        }
        if (scratch_len && !wisp_res_alloc(r, scratch_len, (void **)&scratch)) {
            wisp_pool_free(&r->pool, raw);
            e->users--;
            return WISP_ERR_NO_MEMORY;
        }
        e->users--;
        int n = wisp_pixels_decode(codec, e->data + 6, e->len - 6, w, h, raw, size, scratch, scratch_len);
        wisp_pool_free(&r->pool, scratch);
        if (n != (int)size) {
            wisp_pool_free(&r->pool, raw);
            return WISP_ERR_BAD_PAYLOAD;
        }
        wisp_pool_free(&r->pool, e->data);
        wisp_pool_set_owner(&r->pool, raw, (void **)&e->data);
        e->len = (uint32_t)size;
        e->w = w;
        e->h = h;
        return 0;
    }
    case WISP_RES_ANIM: return anim_valid(e->data, e->len, &e->w, &e->h) ? 0 : WISP_ERR_BAD_PAYLOAD;
    case WISP_RES_FONT: return font_valid(e->data, e->len) ? 0 : WISP_ERR_BAD_PAYLOAD;
    default: return 0;
    }
}

static bool hash_ok(const uint8_t *data, size_t len, const uint8_t hash[16]) {
    uint8_t d[32];
    wisp_sha256(data, len, d);
    return !memcmp(d, hash, 16);
}

/* Reads a persisted resource into RAM. */
static wisp_res *load(wisp_resources *r, uint8_t app, uint16_t id) {
    if (!r->storage) return NULL;
    wisp_list_entry_t meta;
    if (r->storage->read(r->storage->ctx, r->apps[app], id, &meta, NULL, 0) < 0) return NULL;
    if (meta.type < WISP_RES_IMAGE || meta.type > WISP_RES_BLOB) return NULL;
    wisp_res *e = slot(r);
    if (!e) return NULL;
    if (!wisp_res_alloc(r, meta.size, (void **)&e->data)) return NULL;
    int n = r->storage->read(r->storage->ctx, r->apps[app], id, &meta, e->data, meta.size);
    e->state = WISP_RES_UPLOADING;
    e->app = app;
    e->id = id;
    e->type = meta.type;
    e->flags = meta.flags | WISP_RES_PERSIST;
    e->size = e->len = e->received = meta.size;
    memcpy(e->hash, meta.hash, 16);
    if (n != (int)meta.size || !hash_ok(e->data, meta.size, meta.hash) || prepare(r, e)) {
        drop(r, e);
        return NULL;
    }
    e->state = WISP_RES_READY;
    e->stamp = ++r->clock;
    r->loads++;
    return e;
}

wisp_res *wisp_res_get(wisp_resources *r, uint8_t app, uint16_t id, uint8_t type) {
    wisp_res *e = find(r, app, id);
    if (e && e->state != WISP_RES_READY) return NULL;
    if (!e) e = load(r, app, id);
    if (!e || (type && e->type != type)) return NULL;
    e->stamp = ++r->clock;
    return e;
}

/* ---- protocol operations ---- */

int wisp_res_put_begin(wisp_resources *r, uint8_t app, const wisp_resource_put_begin_req_t *m, uint8_t *status) {
    *status = WISP_PUT_SEND;
    if (m->res == WISP_RES_ALL || m->type < WISP_RES_IMAGE || m->type > WISP_RES_BLOB) return WISP_ERR_BAD_PAYLOAD;
    if ((m->flags & WISP_RES_PERSIST) && !r->storage) return WISP_ERR_UNSUPPORTED;
    wisp_res *e = find(r, app, m->res);
    if (e && e->state == WISP_RES_READY && e->size == m->size && e->type == m->type && !memcmp(e->hash, m->hash, 16)) {
        /* asked to persist what only lives in RAM: images keep only decoded pixels, so upload again */
        if (!(m->flags & WISP_RES_PERSIST) || (e->flags & WISP_RES_PERSIST)) {
            e->stamp = ++r->clock;
            *status = WISP_PUT_PRESENT;
            return 0;
        }
    }
    if (!e && r->storage) {
        wisp_list_entry_t meta;
        if (r->storage->read(r->storage->ctx, r->apps[app], m->res, &meta, NULL, 0) >= 0 && meta.size == m->size &&
            meta.type == m->type && !memcmp(meta.hash, m->hash, 16)) {
            *status = WISP_PUT_PRESENT; /* loaded into RAM when first used */
            return 0;
        }
    }
    if (e) drop(r, e);
    if (wisp_pool_cost(m->size) > r->pool.size) return WISP_ERR_NO_MEMORY;
    e = slot(r);
    if (!e) return WISP_ERR_NO_MEMORY;
    if (!wisp_res_alloc(r, m->size, (void **)&e->data)) return WISP_ERR_NO_MEMORY;
    e->state = WISP_RES_UPLOADING;
    e->app = app;
    e->id = m->res;
    e->type = m->type;
    e->flags = m->flags & WISP_RES_PERSIST;
    e->size = e->len = m->size;
    e->received = 0;
    memcpy(e->hash, m->hash, 16);
    return 0;
}

int wisp_res_put_data(wisp_resources *r, uint8_t app, uint16_t id, uint32_t offset, wisp_bytes data) {
    wisp_res *e = find(r, app, id);
    if (!e || e->state != WISP_RES_UPLOADING) return WISP_ERR_NO_SUCH_ID;
    if (offset > e->size || data.len > e->size - offset) return WISP_ERR_BAD_PAYLOAD;
    memcpy(e->data + offset, data.data, data.len);
    if (offset + data.len > e->received) e->received = (uint32_t)(offset + data.len);
    return 0;
}

int wisp_res_put_end(wisp_resources *r, uint8_t app, uint16_t id) {
    wisp_res *e = find(r, app, id);
    if (!e || e->state != WISP_RES_UPLOADING) return WISP_ERR_NO_SUCH_ID;
    if (e->received != e->size || !hash_ok(e->data, e->size, e->hash)) {
        drop(r, e);
        return WISP_ERR_HASH_MISMATCH;
    }
    if ((e->flags & WISP_RES_PERSIST) && r->storage) {
        wisp_list_entry_t meta = {e->id, e->type, e->flags, e->size, {0}};
        memcpy(meta.hash, e->hash, 16);
        if (r->storage->write(r->storage->ctx, r->apps[app], &meta, e->data, e->size) < 0) {
            drop(r, e);
            return WISP_ERR_NO_MEMORY;
        }
    }
    int err = prepare(r, e);
    if (err) {
        if ((e->flags & WISP_RES_PERSIST) && r->storage) r->storage->remove(r->storage->ctx, r->apps[app], id);
        drop(r, e);
        return err;
    }
    e->state = WISP_RES_READY;
    e->stamp = ++r->clock;
    return 0;
}

int wisp_res_delete(wisp_resources *r, uint8_t app, uint16_t id) {
    bool found = false;
    for (uint16_t i = 0; i < r->max; i++) {
        wisp_res *e = &r->tab[i];
        if (e->state && e->app == app && (id == WISP_RES_ALL || e->id == id)) {
            drop(r, e);
            found = true;
        }
    }
    if (r->storage) found |= r->storage->remove(r->storage->ctx, r->apps[app], id) >= 0;
    return found || id == WISP_RES_ALL ? 0 : WISP_ERR_NO_SUCH_ID;
}

size_t wisp_res_list(wisp_resources *r, uint8_t app, uint8_t *out, size_t cap) {
    size_t item = wisp_list_entry_desc.fixed_size, n = 2;
    uint16_t count = 0;
    if (cap < 2) return 0;
    for (uint16_t i = 0; i < r->max && n + item <= cap; i++) {
        const wisp_res *e = &r->tab[i];
        if (e->state != WISP_RES_READY || e->app != app) continue;
        wisp_list_entry_t le = {e->id, e->type, e->flags, e->size, {0}};
        memcpy(le.hash, e->hash, 16);
        wisp_pack(&wisp_list_entry_desc, &le, out + n, item);
        n += item;
        count++;
    }
    if (r->storage) {
        wisp_list_entry_t st[32];
        int k = r->storage->list(r->storage->ctx, r->apps[app], st, sizeof st / sizeof st[0]);
        for (int i = 0; i < k && n + item <= cap; i++) {
            const wisp_res *e = find(r, app, st[i].res);
            if (e && e->state == WISP_RES_READY) continue;
            st[i].flags |= WISP_RES_PERSIST;
            wisp_pack(&wisp_list_entry_desc, &st[i], out + n, item);
            n += item;
            count++;
        }
    }
    wisp_put16(out, count);
    return n;
}

void wisp_res_end_session(wisp_resources *r, uint8_t app) {
    for (uint16_t i = 0; i < r->max; i++) {
        wisp_res *e = &r->tab[i];
        if (e->state && e->app == app && (e->state != WISP_RES_READY || !(e->flags & WISP_RES_PERSIST))) drop(r, e);
    }
}
