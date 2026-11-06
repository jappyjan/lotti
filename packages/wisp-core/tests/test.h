/* Tiny test helpers shared by the test programs. */
#ifndef WISP_TEST_H
#define WISP_TEST_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int test_failures;

#define CHECK(cond)                                                                \
    do {                                                                           \
        if (!(cond)) {                                                             \
            test_failures++;                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                          \
    } while (0)

/* xorshift32: reproducible randomness. */
static inline uint32_t rnd(uint32_t *s) {
    *s ^= *s << 13;
    *s ^= *s >> 17;
    *s ^= *s << 5;
    return *s;
}

static inline size_t from_hex(const char *s, uint8_t *out, size_t cap) {
    size_t n = 0;
    for (; s[0] && s[1]; s += 2) {
        if (n == cap) {
            fprintf(stderr, "hex too long\n");
            exit(2);
        }
        unsigned v;
        sscanf(s, "%2x", &v);
        out[n++] = (uint8_t)v;
    }
    return n;
}

#endif
