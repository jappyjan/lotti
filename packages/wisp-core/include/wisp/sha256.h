/* Wisp core: SHA-256 (FIPS 180-4). MIT License, Wisp contributors.
 *
 * Written from the FIPS 180-4 description; no code copied. Resources are
 * addressed by the first 16 bytes of the digest (hash16). */
#ifndef WISP_SHA256_H
#define WISP_SHA256_H

#include "common.h"

typedef struct {
    uint32_t h[8];
    uint64_t len; /* bytes hashed so far */
    uint8_t buf[64];
    size_t fill;
} wisp_sha256_ctx;

void wisp_sha256_init(wisp_sha256_ctx *s);
void wisp_sha256_update(wisp_sha256_ctx *s, const void *data, size_t len);
void wisp_sha256_final(wisp_sha256_ctx *s, uint8_t out[32]);
/* One shot. */
void wisp_sha256(const void *data, size_t len, uint8_t out[32]);

#endif
