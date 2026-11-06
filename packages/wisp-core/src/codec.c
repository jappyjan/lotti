/* Wisp core: pixel codecs. MIT License, Wisp contributors.
 *
 * The LZ4 code is written from the LZ4 block format description
 * (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md). */
#include <string.h>

#include "wisp/codec.h"

/* ---- RLE4 ---- */

int wisp_rle4_encode(const uint8_t *raw4, uint16_t w, uint16_t h, uint8_t *out, size_t cap) {
    size_t stride = (w + 1u) / 2u, n = 0;
    int run = 0, value = -1;
    for (uint16_t y = 0; y < h; y++) {
        for (uint16_t x = 0; x < w; x++) {
            uint8_t b = raw4[y * stride + x / 2u];
            int v = (x & 1) ? b & 0xf : b >> 4;
            if (v == value && run < 16) {
                run++;
                continue;
            }
            if (run) {
                if (n == cap) return WISP_E_SPACE;
                out[n++] = (uint8_t)((run - 1) << 4 | value);
            }
            value = v;
            run = 1;
        }
    }
    if (run) {
        if (n == cap) return WISP_E_SPACE;
        out[n++] = (uint8_t)((run - 1) << 4 | value);
    }
    return (int)n;
}

int wisp_rle4_decode(const uint8_t *in, size_t len, uint16_t w, uint16_t h, uint8_t *raw4, size_t cap) {
    size_t stride = (w + 1u) / 2u, size = stride * h, left = (size_t)w * h;
    uint16_t x = 0, y = 0;
    if (cap < size) return WISP_E_SPACE;
    memset(raw4, 0, size);
    for (size_t i = 0; i < len; i++) {
        unsigned run = (in[i] >> 4) + 1u, v = in[i] & 0xfu;
        if (run > left) return WISP_E_MALFORMED;
        left -= run;
        while (run--) {
            raw4[y * stride + x / 2u] |= (uint8_t)((x & 1) ? v : v << 4);
            if (++x == w) {
                x = 0;
                y++;
            }
        }
    }
    return left ? WISP_E_MALFORMED : (int)size;
}

/* ---- LZ4 block ---- */

int wisp_lz4_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
    size_t ip = 0, op = 0;
    for (;;) {
        if (ip >= len) return WISP_E_MALFORMED;
        uint8_t token = in[ip++];
        size_t lit = token >> 4;
        if (lit == 15) {
            uint8_t b;
            do {
                if (ip >= len) return WISP_E_MALFORMED;
                lit += b = in[ip++];
            } while (b == 255);
        }
        if (lit > len - ip) return WISP_E_MALFORMED;
        if (lit > cap - op) return WISP_E_SPACE;
        memcpy(out + op, in + ip, lit);
        ip += lit;
        op += lit;
        if (ip == len) return (int)op; /* the last sequence has no match */

        if (len - ip < 2) return WISP_E_MALFORMED;
        size_t offset = wisp_get16(in + ip);
        ip += 2;
        if (offset == 0 || offset > op) return WISP_E_MALFORMED;
        size_t match = token & 15u;
        if (match == 15) {
            uint8_t b;
            do {
                if (ip >= len) return WISP_E_MALFORMED;
                match += b = in[ip++];
            } while (b == 255);
        }
        match += 4;
        if (match > cap - op) return WISP_E_SPACE;
        for (size_t i = 0; i < match; i++, op++) out[op] = out[op - offset]; /* may overlap */
    }
}

static size_t put_length(uint8_t *out, size_t n, size_t cap, size_t value) {
    for (; value >= 255; value -= 255) {
        if (n == cap) return 0;
        out[n++] = 255;
    }
    if (n == cap) return 0;
    out[n++] = (uint8_t)value;
    return n;
}

/* One sequence: literals in[anchor, anchor + lit), then (offset, match) unless match == 0. */
static size_t put_sequence(uint8_t *out, size_t n, size_t cap, const uint8_t *lit_src, size_t lit,
                           size_t offset, size_t match) {
    size_t ml = match ? match - 4 : 0;
    if (n == cap) return 0;
    out[n++] = (uint8_t)((lit < 15 ? lit : 15) << 4 | (ml < 15 ? ml : 15));
    if (lit >= 15 && !(n = put_length(out, n, cap, lit - 15))) return 0;
    if (cap - n < lit) return 0;
    memcpy(out + n, lit_src, lit);
    n += lit;
    if (!match) return n;
    if (cap - n < 2) return 0;
    wisp_put16(out + n, (uint16_t)offset);
    n += 2;
    if (ml >= 15 && !(n = put_length(out, n, cap, ml - 15))) return 0;
    return n;
}

static uint32_t read32(const uint8_t *p) { return wisp_get32(p); }
static uint32_t lz4_hash(uint32_t v) { return (v * 2654435761u) >> 20; } /* 12 bits */

int wisp_lz4_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, uint32_t *table) {
    size_t ip = 0, anchor = 0, n = 0;
    /* Block rules: the last 5 bytes are literals, the last match starts >= 12 bytes before the end. */
    if (len > 12) {
        memset(table, 0, WISP_LZ4_TABLE * sizeof *table);
        size_t limit = len - 12;
        while (ip < limit) {
            uint32_t v = read32(in + ip), h = lz4_hash(v);
            size_t cand = table[h]; /* position + 1, 0 = empty */
            table[h] = (uint32_t)(ip + 1);
            if (!cand || ip - (cand - 1) > 0xFFFF || read32(in + cand - 1) != v) {
                ip++;
                continue;
            }
            size_t ref = cand - 1, match = 4, max = len - 5 - ip;
            while (match < max && in[ref + match] == in[ip + match]) match++;
            if (!(n = put_sequence(out, n, cap, in + anchor, ip - anchor, ip - ref, match))) return WISP_E_SPACE;
            ip += match;
            anchor = ip;
        }
    }
    if (!(n = put_sequence(out, n, cap, in + anchor, len - anchor, 0, 0))) return WISP_E_SPACE;
    return (int)n;
}

/* ---- dispatch, delta ---- */

int wisp_pixels_decode(uint8_t codec, const uint8_t *in, size_t len, uint16_t w, uint16_t h,
                       uint8_t *raw4, size_t cap, uint8_t *scratch, size_t scratch_cap) {
    size_t size = wisp_raw4_size(w, h);
    int n;
    switch (codec) {
    case WISP_CODEC_RAW4:
        if (len != size) return WISP_E_MALFORMED;
        if (cap < size) return WISP_E_SPACE;
        memcpy(raw4, in, size);
        return (int)size;
    case WISP_CODEC_RLE4:
        return wisp_rle4_decode(in, len, w, h, raw4, cap);
    case WISP_CODEC_LZ4:
        if (cap < size) return WISP_E_SPACE;
        n = wisp_lz4_decode(in, len, raw4, size);
        return n < 0 ? WISP_E_MALFORMED : (size_t)n == size ? n : WISP_E_MALFORMED;
    case WISP_CODEC_LZ4_RLE:
        n = wisp_lz4_decode(in, len, scratch, scratch_cap);
        return n < 0 ? n : wisp_rle4_decode(scratch, (size_t)n, w, h, raw4, cap);
    default:
        return WISP_E_ARG;
    }
}

void wisp_xor(uint8_t *dst, const uint8_t *src, size_t len) {
    while (len--) *dst++ ^= *src++;
}
