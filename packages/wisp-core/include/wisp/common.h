/* Wisp core: shared definitions. MIT License, Wisp contributors. */
#ifndef WISP_COMMON_H
#define WISP_COMMON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Return codes: >= 0 is success (often a length), < 0 a failure. */
enum {
    WISP_OK = 0,
    WISP_E_SPACE = -1,     /* output buffer too small */
    WISP_E_MALFORMED = -2, /* input doesn't parse */
    WISP_E_WINDOW = -3,    /* peer window or send ring full: wait for CREDIT */
    WISP_E_TOO_BIG = -4,   /* larger than max_frame or the peer window */
    WISP_E_ARG = -5,       /* invalid argument */
};

/* A borrowed byte range (tail fields point into the decoded input). */
typedef struct {
    const uint8_t *data;
    size_t len;
} wisp_bytes;

static inline uint16_t wisp_get16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t wisp_get32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t wisp_get64(const uint8_t *p) { return wisp_get32(p) | (uint64_t)wisp_get32(p + 4) << 32; }
static inline void wisp_put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}
static inline void wisp_put32(uint8_t *p, uint32_t v) {
    wisp_put16(p, (uint16_t)v);
    wisp_put16(p + 2, (uint16_t)(v >> 16));
}
static inline void wisp_put64(uint8_t *p, uint64_t v) {
    wisp_put32(p, (uint32_t)v);
    wisp_put32(p + 4, (uint32_t)(v >> 32));
}

#endif
