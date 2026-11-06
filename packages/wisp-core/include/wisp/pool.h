/* Wisp core: a compacting block pool inside caller-provided memory.
 * MIT License, Wisp contributors.
 *
 * First fit with coalescing. Every block records its owner: the address of
 * the one pointer that refers to it. When an allocation doesn't fit, the pool
 * slides all live blocks down and rewrites their owners, so fragmentation
 * never fails an allocation that the free byte count allows.
 *
 * Rule for callers: any pointer into the pool may move during
 * wisp_pool_alloc. Read it again through its owner after allocating. */
#ifndef WISP_POOL_H
#define WISP_POOL_H

#include "common.h"

typedef struct {
    uint8_t *base;
    size_t size;      /* usable bytes, header overhead included */
    size_t used;      /* bytes in live blocks, headers included */
    size_t min_free;  /* low-water mark of size - used */
    uint32_t compactions;
} wisp_pool;

#define WISP_POOL_HDR 16u

void wisp_pool_init(wisp_pool *p, void *mem, size_t size);
/* Stores the result in *owner as well. NULL (and *owner = NULL) when it doesn't fit. */
void *wisp_pool_alloc(wisp_pool *p, size_t n, void **owner);
/* Frees the block at ptr (NULL is fine) and clears its owner. */
void wisp_pool_free(wisp_pool *p, void *ptr);
/* Hands the block at ptr to a new owner (and stores ptr there). */
void wisp_pool_set_owner(wisp_pool *p, void *ptr, void **owner);
/* Frees every block. */
void wisp_pool_reset(wisp_pool *p);
static inline size_t wisp_pool_free_bytes(const wisp_pool *p) { return p->size - p->used; }
/* Bytes a block of n costs (header and alignment included). */
static inline size_t wisp_pool_cost(size_t n) { return ((n + 7u) & ~(size_t)7u) + WISP_POOL_HDR; }

#endif
