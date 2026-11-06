/* Wisp core: the resource store. MIT License, Wisp contributors.
 *
 * Resources are keyed by (app, res id): every app_id gets its own namespace.
 * Uploads (PUT_BEGIN / PUT_DATA / PUT_END) land in a wisp_pool, are checked
 * against the first 16 bytes of their SHA-256, and are then prepared for
 * use: images are decoded to RAW4 once, fonts and animations are validated.
 * Persisted resources are also written to a HAL storage backend, read back on
 * demand (PUT_BEGIN, BLIT, …) and kept in RAM as a cache that may be evicted
 * when memory runs short. */
#ifndef WISP_RESOURCE_H
#define WISP_RESOURCE_H

#include "msgs.h"
#include "pool.h"

enum { WISP_RES_IMAGE = 1, WISP_RES_ANIM = 2, WISP_RES_FONT = 3, WISP_RES_BLOB = 4 };
enum { WISP_RES_PERSIST = 1 };
enum { WISP_PUT_SEND = 0, WISP_PUT_PRESENT = 1 };
#define WISP_RES_ALL 0xFFFFu
#define WISP_APP_MAX 8u

/* Persistent storage, e.g. littlefs on NOR (native) or a directory (sim).
 * `app` is the app_id (NUL-terminated, ≤ 16 bytes). Return codes: ≥ 0 ok, < 0 failure. */
typedef struct {
    void *ctx;
    uint32_t capacity; /* persist_bytes in HELLO */
    /* Stores the resource as uploaded (meta + bytes), replacing any old one; evicts as it needs. */
    int (*write)(void *ctx, const char *app, const wisp_list_entry_t *meta, const uint8_t *data, size_t len);
    /* Reads meta and, if data != NULL, up to cap bytes. Returns the size, or < 0 if absent. */
    int (*read)(void *ctx, const char *app, uint16_t res, wisp_list_entry_t *meta, uint8_t *data, size_t cap);
    /* res = WISP_RES_ALL removes every resource of the app. */
    int (*remove)(void *ctx, const char *app, uint16_t res);
    /* Up to cap entries of the app; returns how many. */
    int (*list)(void *ctx, const char *app, wisp_list_entry_t *out, size_t cap);
} wisp_storage;

enum { WISP_RES_FREE = 0, WISP_RES_UPLOADING, WISP_RES_READY };

typedef struct {
    uint8_t state, app, type, flags;
    uint16_t id;
    uint16_t users;  /* animations playing it: not evicted, not replaced underneath */
    uint32_t size;   /* as uploaded */
    uint32_t received;
    uint8_t hash[16];
    uint16_t w, h;   /* images and animations */
    uint32_t len;    /* bytes at data */
    uint32_t stamp;  /* last use, for eviction */
    uint8_t *data;   /* pool block: RAW4 pixels for images, the uploaded bytes otherwise */
} wisp_res;

typedef struct {
    wisp_res *tab;
    uint16_t max;
    wisp_pool pool;
    const wisp_storage *storage;
    char apps[WISP_APP_MAX][17];
    uint32_t clock;
    uint32_t evictions, loads;
} wisp_resources;

void wisp_res_init(wisp_resources *r, wisp_res *tab, uint16_t max, void *pool_mem, size_t pool_size,
                   const wisp_storage *storage);
/* The namespace index of an app_id (allocated on first use, reusing empty slots). */
uint8_t wisp_res_app(wisp_resources *r, const char *app_id);

/* Protocol operations; return 0 or a WISP_ERR_* code. */
int wisp_res_put_begin(wisp_resources *r, uint8_t app, const wisp_resource_put_begin_req_t *m, uint8_t *status);
int wisp_res_put_data(wisp_resources *r, uint8_t app, uint16_t id, uint32_t offset, wisp_bytes data);
int wisp_res_put_end(wisp_resources *r, uint8_t app, uint16_t id);
int wisp_res_delete(wisp_resources *r, uint8_t app, uint16_t id);
/* LIST entries (RAM and storage) into out (count u16 + items) for at most cap bytes. Returns the length. */
size_t wisp_res_list(wisp_resources *r, uint8_t app, uint8_t *out, size_t cap);

/* A ready resource, loaded from storage if needed; NULL if absent or of another type.
 * The pointer stays valid until the next allocation in the pool. */
wisp_res *wisp_res_get(wisp_resources *r, uint8_t app, uint16_t id, uint8_t type);
/* Allocates from the resource pool, evicting cached persisted resources if needed. */
void *wisp_res_alloc(wisp_resources *r, size_t n, void **owner);
/* Session end: drops the app's resources that weren't persisted. */
void wisp_res_end_session(wisp_resources *r, uint8_t app);

/* Font access (type 3, validated at upload). */
typedef struct {
    uint8_t line_h, baseline;
    uint16_t glyphs;
    const uint8_t *table, *bitmaps;
    size_t bitmaps_len;
} wisp_font;
typedef struct {
    uint8_t w, h, advance;
    int8_t x_off, y_off;
    const uint8_t *bits; /* RAW4, stride (w + 1) / 2 */
} wisp_glyph;
bool wisp_font_open(const uint8_t *data, size_t len, wisp_font *f);
bool wisp_font_glyph(const wisp_font *f, uint32_t cp, wisp_glyph *g);

/* Animation access (type 2, validated at upload). */
typedef struct {
    uint16_t w, h, frames;
    uint8_t codec;
} wisp_anim_hdr;
#define WISP_ANIM_HDR 7u
#define WISP_ANIM_FRAME_HDR 7u

#endif
