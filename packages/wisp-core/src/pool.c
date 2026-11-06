/* Wisp core: compacting block pool. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/pool.h"

/* Block header; a free block has owner == NULL. */
typedef struct {
    size_t size; /* whole block, header included, multiple of 8 */
    void **owner;
} blk;

_Static_assert(sizeof(blk) <= WISP_POOL_HDR, "pool header");

static inline blk *at(const wisp_pool *p, size_t off) { return (blk *)(void *)(p->base + off); }

void wisp_pool_init(wisp_pool *p, void *mem, size_t size) {
    uintptr_t a = (uintptr_t)mem, b = (a + 7u) & ~(uintptr_t)7u;
    size = size > (size_t)(b - a) ? (size - (size_t)(b - a)) & ~(size_t)7u : 0;
    p->base = (uint8_t *)mem + (b - a);
    p->size = size;
    p->compactions = 0;
    wisp_pool_reset(p);
}

void wisp_pool_reset(wisp_pool *p) {
    p->used = 0;
    p->min_free = p->size;
    if (p->size >= WISP_POOL_HDR) *at(p, 0) = (blk){p->size, NULL};
}

static void compact(wisp_pool *p) {
    size_t src = 0, dst = 0;
    while (src < p->size) {
        blk b = *at(p, src);
        if (b.owner) {
            if (dst != src) {
                memmove(p->base + dst, p->base + src, b.size);
                *b.owner = p->base + dst + WISP_POOL_HDR;
            }
            dst += b.size;
        }
        src += b.size;
    }
    if (dst < p->size) *at(p, dst) = (blk){p->size - dst, NULL};
    p->compactions++;
}

static void *take(wisp_pool *p, size_t off, size_t need, void **owner) {
    blk *b = at(p, off);
    if (b->size - need >= WISP_POOL_HDR + 8u) {
        *at(p, off + need) = (blk){b->size - need, NULL};
        b->size = need;
    }
    b->owner = owner;
    p->used += b->size;
    if (p->size - p->used < p->min_free) p->min_free = p->size - p->used;
    *owner = p->base + off + WISP_POOL_HDR;
    return *owner;
}

void *wisp_pool_alloc(wisp_pool *p, size_t n, void **owner) {
    size_t need = wisp_pool_cost(n);
    *owner = NULL;
    if (p->size < WISP_POOL_HDR || need > p->size - p->used) return NULL;
    for (size_t off = 0; off < p->size;) {
        blk *b = at(p, off);
        if (!b->owner) {
            /* coalesce the free run that starts here */
            while (off + b->size < p->size && !at(p, off + b->size)->owner) b->size += at(p, off + b->size)->size;
            if (b->size >= need) return take(p, off, need, owner);
        }
        off += b->size;
    }
    compact(p);
    /* all free space is now one block at the end */
    size_t off = p->used;
    return take(p, off, need, owner);
}

void wisp_pool_free(wisp_pool *p, void *ptr) {
    if (!ptr) return;
    blk *b = (blk *)(void *)((uint8_t *)ptr - WISP_POOL_HDR);
    if (!b->owner) return;
    if (*b->owner == ptr) *b->owner = NULL;
    b->owner = NULL;
    p->used -= b->size;
}

void wisp_pool_set_owner(wisp_pool *p, void *ptr, void **owner) {
    (void)p;
    blk *b = (blk *)(void *)((uint8_t *)ptr - WISP_POOL_HDR);
    b->owner = owner;
    *owner = ptr;
}
