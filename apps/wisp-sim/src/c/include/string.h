/* The libc subset wisp-core uses, for the freestanding wasm build (sim.c defines them). */
#ifndef WISP_SIM_STRING_H
#define WISP_SIM_STRING_H
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
#endif
