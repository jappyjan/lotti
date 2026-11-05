/* Wisp core: pixel codecs. MIT License, Wisp contributors.
 *
 * Pixels are 4 bpp, rows top to bottom, high nibble = left pixel, stride
 * ceil(w/2) (RAW4). Decoders bounds-check everything and return the output
 * length or a negative WISP_E_* code. */
#ifndef WISP_CODEC_H
#define WISP_CODEC_H

#include "common.h"

enum { WISP_CODEC_RAW4 = 0, WISP_CODEC_RLE4 = 1, WISP_CODEC_LZ4 = 2, WISP_CODEC_LZ4_RLE = 3 };

static inline size_t wisp_raw4_size(uint16_t w, uint16_t h) { return (size_t)(w + 1u) / 2u * h; }

/* RLE4: one byte per run, high nibble = run length - 1, low nibble = value.
 * Runs cross rows; the encoder emits greedy maximal runs (at most w*h bytes). */
int wisp_rle4_encode(const uint8_t *raw4, uint16_t w, uint16_t h, uint8_t *out, size_t cap);
/* Must cover exactly w*h pixels with no bytes left over. Padding nibbles come out 0. */
int wisp_rle4_decode(const uint8_t *in, size_t len, uint16_t w, uint16_t h, uint8_t *raw4, size_t cap);

/* LZ4 block format (no frame header, no checksum). */
int wisp_lz4_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap);

/* A small greedy LZ4 block encoder. `table` is scratch of WISP_LZ4_TABLE entries. */
#define WISP_LZ4_TABLE 4096u
static inline size_t wisp_lz4_bound(size_t len) { return len + len / 255u + 16u; }
int wisp_lz4_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, uint32_t *table);

/* Any codec to RAW4 (exactly wisp_raw4_size(w, h) bytes). LZ4_RLE needs
 * scratch for the RLE4 stream (at most w*h bytes); other codecs ignore it. */
int wisp_pixels_decode(uint8_t codec, const uint8_t *in, size_t len, uint16_t w, uint16_t h,
                       uint8_t *raw4, size_t cap, uint8_t *scratch, size_t scratch_cap);

/* Delta frames: dst ^= src. */
void wisp_xor(uint8_t *dst, const uint8_t *src, size_t len);

#endif
