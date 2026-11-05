/* Unit and randomized tests for the C core. */
#include <stdalign.h>
#include <string.h>

#include "test.h"
#include "wisp/codec.h"
#include "wisp/crc.h"
#include "wisp/frame.h"
#include "wisp/session.h"

/* ---- crc ---- */

static void test_crc(void) {
    const char *check = "123456789";
    CHECK(wisp_crc16(WISP_CRC16_INIT, check, 9) == 0x29B1);
    CHECK(wisp_crc32c_msb(WISP_CRC32C_MSB_INIT, check, 9) == 0xC052A8C8);
    CHECK(wisp_crc32(0, check, 9) == 0xCBF43926);
    /* incremental == one shot */
    CHECK(wisp_crc16(wisp_crc16(WISP_CRC16_INIT, check, 4), check + 4, 5) == 0x29B1);
    CHECK(wisp_crc32c_msb(wisp_crc32c_msb(0, check, 2), check + 2, 7) == 0xC052A8C8);
    CHECK(wisp_crc32(wisp_crc32(0, check, 5), check + 5, 4) == 0xCBF43926);
}

/* ---- frames ---- */

/* Body of message i: its index, then a pattern, so a receiver can verify it. */
static size_t make_body(uint32_t i, size_t len, uint8_t *out) {
    if (len < 4) len = 4;
    wisp_put32(out, i);
    for (size_t k = 4; k < len; k++) out[k] = (uint8_t)(i * 7 + k);
    return len;
}

static bool body_ok(const wisp_frame *f, uint32_t i) {
    uint8_t want[1024];
    return f->len >= 4 && wisp_get32(f->body) == i && f->len == make_body(i, f->len, want) &&
           !memcmp(f->body, want, f->len);
}

static void test_frame_basics(void) {
    uint8_t out[32], buf[64];
    CHECK(wisp_frame_encode(out, 12, 0, 0, 0, (const uint8_t *)"abc", 3) == WISP_E_SPACE);
    CHECK(wisp_frame_encode(out, sizeof out, 1, 2, 3, (const uint8_t *)"abc", 3) == 13);

    /* seq wraps through 0xFFFF */
    wisp_rx rx;
    wisp_rx_event ev;
    wisp_frame f;
    wisp_rx_init(&rx, buf, sizeof buf);
    rx.last_good_seq = 0xFFFE;
    for (uint32_t s = 0xFFFF; s <= 0x10001; s++) {
        int n = wisp_frame_encode(out, sizeof out, 0, 0, (uint16_t)s, NULL, 0);
        CHECK(wisp_rx_feed(&rx, out, (size_t)n, &ev, &f) == (size_t)n && ev == WISP_RX_FRAME && f.seq == (uint16_t)s);
    }

    /* Up to 0x7FFF past the expected seq is a gap (RESYNC); anything else a duplicate (silent). */
    wisp_rx_init(&rx, buf, sizeof buf);
    rx.last_good_seq = 0; /* expects 1 */
    int k = wisp_frame_encode(out, sizeof out, 0, 0, 0x8001, NULL, 0);
    CHECK(wisp_rx_feed(&rx, out, (size_t)k, &ev, &f) == (size_t)k && ev == WISP_RX_NONE && rx.dups == 1);
    k = wisp_frame_encode(out, sizeof out, 0, 0, 0x8000, NULL, 0);
    CHECK(wisp_rx_feed(&rx, out, (size_t)k, &ev, &f) == (size_t)k && ev == WISP_RX_RESYNC && rx.gaps == 1);

    /* a frame longer than the receive buffer is discarded and asks for RESYNC */
    uint8_t big[100], zeros[60] = {0};
    wisp_rx_init(&rx, buf, sizeof buf);
    int n = wisp_frame_encode(big, sizeof big, 0, 0, 0, zeros, sizeof zeros);
    size_t used = wisp_rx_feed(&rx, big, (size_t)n, &ev, &f);
    CHECK(ev == WISP_RX_RESYNC && rx.last_good_seq == 0xFFFF);
    while (used < (size_t)n) {
        used += wisp_rx_feed(&rx, big + used, (size_t)n - used, &ev, &f);
        CHECK(ev != WISP_RX_FRAME);
    }
}

/* Random frames, random chunking, no corruption: everything arrives in order. */
static void test_rx_chunking(uint32_t seed) {
    static uint8_t stream[200000], buf[1024 + WISP_FRAME_OVERHEAD];
    size_t len = 0;
    uint32_t count = 0;
    while (len < sizeof stream - 1100) {
        uint8_t body[1024];
        size_t n = make_body(count, rnd(&seed) % 1024, body);
        len += (size_t)wisp_frame_encode(stream + len, sizeof stream - len, 0, 0, (uint16_t)count, body, n);
        count++;
    }
    wisp_rx rx;
    wisp_rx_init(&rx, buf, sizeof buf);
    uint32_t got = 0;
    for (size_t off = 0; off < len;) {
        size_t chunk = 1 + rnd(&seed) % 300;
        if (chunk > len - off) chunk = len - off;
        const uint8_t *p = stream + off;
        size_t left = chunk;
        wisp_rx_event ev;
        wisp_frame f;
        do {
            size_t used = wisp_rx_feed(&rx, p, left, &ev, &f);
            p += used;
            left -= used;
            CHECK(ev != WISP_RX_RESYNC);
            if (ev == WISP_RX_FRAME) CHECK(body_ok(&f, got++));
        } while (ev != WISP_RX_NONE);
        off += chunk;
    }
    CHECK(got == count && rx.bad_bytes == 0);
}

/* Sender and receiver over a link that corrupts, truncates and drops chunks;
 * CREDIT and RESYNC travel back on an ideal channel. Every message must
 * arrive exactly once, in order. */
static void test_lossy_link(uint32_t seed, uint32_t count, unsigned max_body, unsigned corrupt_pm, unsigned drop_pm) {
    static uint8_t ring[8192], buf[1024 + WISP_FRAME_OVERHEAD];
    wisp_tx tx;
    wisp_rx rx;
    wisp_tx_init(&tx, ring, sizeof ring);
    wisp_tx_set_peer(&tx, 1024, 6000);
    wisp_rx_init(&rx, buf, sizeof buf);
    uint32_t sent = 0, got = 0, idle = 0;
    for (long iter = 0; got < count && iter < 50L * count + 100000; iter++) {
        while (sent < count) {
            uint8_t body[1024];
            size_t n = make_body(sent, rnd(&seed) % max_body, body);
            int r = wisp_tx_send(&tx, 0, 0, body, n);
            if (r == WISP_E_WINDOW) break;
            CHECK(r == (uint16_t)sent);
            sent++;
        }
        uint8_t chunk[256];
        size_t n = wisp_tx_pull(&tx, chunk, 1 + rnd(&seed) % sizeof chunk);
        if (n) {
            idle = 0;
        } else if (++idle > 2) {
            wisp_tx_resend_all(&tx); /* ack timeout */
            idle = 0;
        }
        if (n && rnd(&seed) % 1000 < drop_pm) n = rnd(&seed) % 2 ? 0 : rnd(&seed) % n; /* lost or cut short */
        if (n && rnd(&seed) % 1000 < corrupt_pm) chunk[rnd(&seed) % n] ^= (uint8_t)(1u << rnd(&seed) % 8);

        const uint8_t *p = chunk;
        wisp_rx_event ev;
        wisp_frame f;
        do {
            size_t used = wisp_rx_feed(&rx, p, n, &ev, &f);
            p += used;
            n -= used;
            if (ev == WISP_RX_FRAME) {
                if (!body_ok(&f, got)) {
                    CHECK(!"wrong frame delivered");
                    return;
                }
                got++;
            } else if (ev == WISP_RX_RESYNC) {
                wisp_tx_resync(&tx, rx.last_good_seq);
            }
        } while (ev != WISP_RX_NONE);
        if (rnd(&seed) % 3 == 0) wisp_tx_ack(&tx, rx.last_good_seq); /* coalesced CREDIT */
    }
    CHECK(got == count);
    if (got != count) fprintf(stderr, "lossy link seed %u: %u of %u delivered\n", seed, got, count);
}

static void test_tx_window(void) {
    uint8_t ring[256], out[512], body[100] = {0};
    wisp_tx tx;
    wisp_tx_init(&tx, ring, sizeof ring);
    wisp_tx_set_peer(&tx, 64, 150);
    CHECK(wisp_tx_send(&tx, 0, 0, body, 65) == WISP_E_TOO_BIG); /* > max_frame */
    CHECK(wisp_tx_send(&tx, 0, 0, body, 50) == 0);
    CHECK(wisp_tx_send(&tx, 0, 0, body, 50) == 1);
    CHECK(wisp_tx_send(&tx, 0, 0, body, 50) == WISP_E_WINDOW); /* 180 > 150 */
    CHECK(wisp_tx_pull(&tx, out, sizeof out) == 120 && wisp_tx_pending(&tx) == 0);
    wisp_tx_ack(&tx, 5);      /* not sent yet: ignored */
    wisp_tx_ack(&tx, 0xFFF0); /* stale: ignored */
    CHECK(tx.nframes == 2);
    wisp_tx_ack(&tx, 0);
    CHECK(tx.nframes == 1 && wisp_tx_send(&tx, 0, 0, body, 50) == 2);

    /* RESYNC rewinds to the frame after last_good_seq; resend_all to the oldest */
    wisp_tx_resync(&tx, 1);
    CHECK(wisp_tx_pending(&tx) == 60);
    wisp_tx_resend_all(&tx);
    CHECK(wisp_tx_pending(&tx) == 120);

    /* A RESYNC mid-frame waits for the frame boundary: the link never carries half a frame. */
    CHECK(wisp_tx_pull(&tx, out, 25) == 25);
    wisp_tx_resync(&tx, 0);
    size_t n = wisp_tx_pull(&tx, out + 25, sizeof out - 25);
    CHECK(n == 35 + 120);
    CHECK(wisp_get16(out + 6) == 1 && wisp_get16(out + 60 + 6) == 1 && wisp_get16(out + 120 + 6) == 2);

    /* Same for a CREDIT that covers the frame being resent: it's finished first. */
    wisp_tx_resend_all(&tx);
    CHECK(wisp_tx_pull(&tx, out, 25) == 25);
    wisp_tx_ack(&tx, 1);
    n = wisp_tx_pull(&tx, out + 25, sizeof out - 25);
    CHECK(n == 35 + 60 && wisp_get16(out + 6) == 1 && wisp_get16(out + 60 + 6) == 2);
    CHECK(wisp_crc16(WISP_CRC16_INIT, out, 58) == wisp_get16(out + 58));
}

/* ---- messages ---- */

static size_t wire_size(uint8_t t) {
    static const uint8_t sizes[] = {1, 1, 2, 2, 4, 4, 8, 16, 16, 32};
    return t < sizeof sizes ? sizes[t] : 0;
}

/* Random values for every field of a layout; tails point into `pool`. */
static void randomize(const wisp_desc *d, uint8_t *s, uint32_t *seed, uint8_t *pool) {
    memset(s, 0, d->struct_size);
    for (unsigned i = 0; i < d->nfields; i++) {
        const wisp_field *f = &d->fields[i];
        uint8_t *v = s + f->offset;
        if (f->type == WISP_T_STR16) {
            unsigned n = rnd(seed) % 17;
            for (unsigned k = 0; k < n; k++) v[k] = (uint8_t)('a' + rnd(seed) % 26);
        } else if (wire_size(f->type)) {
            for (size_t k = 0; k < wire_size(f->type); k++) v[k] = (uint8_t)rnd(seed);
        } else {
            size_t unit = f->type == WISP_T_ITEMS ? f->item->fixed_size : 1;
            wisp_bytes b = {pool, unit * (rnd(seed) % 5)};
            for (size_t k = 0; k < b.len; k++) pool[k] = (uint8_t)rnd(seed);
            memcpy(v, &b, sizeof b);
        }
    }
}

static void test_msg_table(void) {
    uint32_t seed = 0x1234;
    uint8_t pool[256], a[512], b[600];
    alignas(16) uint8_t s[1024], t[1024];
    CHECK(wisp_msg_table_len > 50);
    for (size_t i = 0; i < wisp_msg_table_len; i++) {
        const wisp_desc *d = wisp_msg_table[i];
        uint8_t mflags = d->kind == WISP_KIND_RSP ? WISP_MF_RESPONSE : d->kind == WISP_KIND_EVT ? WISP_MF_EVENT : 0;
        CHECK(wisp_desc_find(d->svc, d->op, mflags) == d);
        CHECK(wisp_desc_find(d->svc, d->op, mflags | WISP_MF_ERROR) == &wisp_error_desc);
        for (int round = 0; round < 20; round++) {
            randomize(d, s, &seed, pool);
            int n = wisp_pack(d, s, a, sizeof a);
            CHECK(n >= d->fixed_size);
            if (n > 0) CHECK(wisp_pack(d, s, a, (size_t)n - 1) == WISP_E_SPACE);
            CHECK(wisp_unpack(d, a, (size_t)n, t) == WISP_OK);
            CHECK(wisp_pack(d, t, b, sizeof b) == n && !memcmp(a, b, (size_t)n));
        }
        /* Cuts: whole fields missing are fine (defaults), half a field isn't. */
        size_t boundary = 0;
        unsigned next = 0;
        for (size_t cut = 0; cut < d->fixed_size; cut++) {
            while (next < d->nfields && boundary < cut) boundary += wire_size(d->fields[next++].type);
            CHECK((wisp_unpack(d, a, cut, t) == WISP_OK) == (boundary == cut));
        }
    }
    /* unknown trailing bytes are ignored */
    wisp_session_ping_req_t ping;
    const uint8_t extra[] = {4, 3, 2, 1, 9, 9, 9};
    CHECK(wisp_unpack(&wisp_session_ping_req_desc, extra, sizeof extra, &ping) == WISP_OK && ping.token == 0x01020304);
    /* a 16-byte str16 comes back NUL-terminated */
    wisp_system_info_rsp_t info;
    memset(a, 'x', 44);
    CHECK(wisp_unpack(&wisp_system_info_rsp_desc, a, 44, &info) == WISP_OK && strlen(info.serial) == 16);
    CHECK(wisp_desc_find(0, 99, 0) == NULL);
    CHECK(wisp_hdr_decode(a, 3, &(wisp_hdr){0}) == WISP_E_MALFORMED);
    const uint8_t busy[] = {5, WISP_MF_RESPONSE | WISP_MF_ERROR, 77, 0, WISP_ERR_BUSY, 0, 'b', 'u', 's', 'y'};
    CHECK(wisp_msg_error(a, sizeof a, 5, 77, WISP_ERR_BUSY, "busy") == 10 && !memcmp(a, busy, 10));
}

/* ---- codecs ---- */

static void test_codecs(void) {
    static uint8_t px[4096], enc[8192], dec[8192], rle[8192], scratch[8192];
    static uint32_t table[WISP_LZ4_TABLE];
    uint32_t seed = 99;
    for (int round = 0; round < 300; round++) {
        uint16_t w = (uint16_t)(1 + rnd(&seed) % 90), h = (uint16_t)(1 + rnd(&seed) % 40);
        size_t size = wisp_raw4_size(w, h);
        unsigned levels = 1 + rnd(&seed) % 16, runny = rnd(&seed) % 8;
        uint8_t v = 0;
        memset(px, 0, size);
        for (uint16_t y = 0; y < h; y++)
            for (uint16_t x = 0; x < w; x++) {
                if (rnd(&seed) % 8 >= runny) v = (uint8_t)(rnd(&seed) % levels);
                px[y * ((w + 1) / 2) + x / 2] |= (uint8_t)((x & 1) ? v : v << 4);
            }
        int r = wisp_rle4_encode(px, w, h, rle, sizeof rle);
        CHECK(r > 0 && (size_t)r <= (size_t)w * h);
        CHECK(wisp_pixels_decode(WISP_CODEC_RLE4, rle, (size_t)r, w, h, dec, sizeof dec, NULL, 0) == (int)size &&
              !memcmp(dec, px, size));
        int z = wisp_lz4_encode(px, size, enc, wisp_lz4_bound(size), table);
        CHECK(z > 0 && wisp_pixels_decode(WISP_CODEC_LZ4, enc, (size_t)z, w, h, dec, sizeof dec, NULL, 0) == (int)size &&
              !memcmp(dec, px, size));
        z = wisp_lz4_encode(rle, (size_t)r, enc, sizeof enc, table);
        CHECK(z > 0 && wisp_pixels_decode(WISP_CODEC_LZ4_RLE, enc, (size_t)z, w, h, dec, sizeof dec, scratch,
                                          sizeof scratch) == (int)size &&
              !memcmp(dec, px, size));
        if (r > 1) /* one run short */
            CHECK(wisp_rle4_decode(rle, (size_t)r - 1, w, h, dec, sizeof dec) == WISP_E_MALFORMED);
        rle[r] = 0x00; /* one pixel too many */
        CHECK(wisp_rle4_decode(rle, (size_t)r + 1, w, h, dec, sizeof dec) == WISP_E_MALFORMED);
        CHECK(wisp_rle4_decode(rle, (size_t)r, w, h, dec, size - 1) == WISP_E_SPACE);
    }

    /* LZ4: compressible data gets smaller; truncated or random input never overruns (ASan watches). */
    for (size_t i = 0; i < 4000; i++) px[i] = (uint8_t)(i % 37 < 20 ? 0 : i % 37);
    int z = wisp_lz4_encode(px, 4000, enc, sizeof enc, table);
    CHECK(z > 0 && z < 1000 && wisp_lz4_decode(enc, (size_t)z, dec, 4000) == 4000 && !memcmp(dec, px, 4000));
    CHECK(wisp_lz4_decode(enc, (size_t)z, dec, 3999) == WISP_E_SPACE);
    CHECK(wisp_lz4_encode(px, 4000, enc, (size_t)z - 1, table) == WISP_E_SPACE);
    for (int cut = 0; cut < z; cut++) CHECK(wisp_lz4_decode(enc, (size_t)cut, dec, 4000) < 4000); /* may end early, validly */
    for (int round = 0; round < 2000; round++) {
        size_t n = rnd(&seed) % 64;
        for (size_t i = 0; i < n; i++) enc[i] = (uint8_t)rnd(&seed);
        int m = wisp_lz4_decode(enc, n, dec, 256);
        CHECK(m <= 256);
    }
    const uint8_t zero_offset[] = {0x10, 0xAA, 0x00, 0x00}, far_offset[] = {0x10, 0xAA, 0x02, 0x00};
    CHECK(wisp_lz4_decode(zero_offset, 4, dec, 64) == WISP_E_MALFORMED);
    CHECK(wisp_lz4_decode(far_offset, 4, dec, 64) == WISP_E_MALFORMED);
    CHECK(wisp_lz4_encode(px, 0, enc, sizeof enc, table) == 1 && wisp_lz4_decode(enc, 1, dec, 0) == 0);
    CHECK(wisp_pixels_decode(9, enc, 1, 1, 1, dec, 1, NULL, 0) == WISP_E_ARG);

    uint8_t a[] = {0x0F, 0xF0, 0x55}, b[] = {0xFF, 0xF0, 0x05};
    wisp_xor(a, b, 3);
    CHECK(a[0] == 0xF0 && a[1] == 0 && a[2] == 0x50);
}

/* ---- session ---- */

static size_t msg(uint8_t *out, uint8_t op, uint16_t req, const wisp_desc *d, const void *m) {
    wisp_hdr h = {op, 0, req};
    return (size_t)wisp_msg_encode(out, 256, &h, d, m);
}

static void test_session(void) {
    wisp_session_hello_rsp_t info = {.proto_minor = 1, .max_frame = 2048, .rx_window = 8192, .fw_name = "wisp",
                                     .session_timeout_ms = 5000};
    wisp_session s;
    wisp_session_result r;
    uint8_t in[256], out[256];
    wisp_hdr h;
    wisp_session_init(&s, &info);

    /* before HELLO: error 7, and silence for req 0 */
    wisp_display_fill_req_t fill = {.layer = 1};
    size_t n = msg(in, WISP_OP_DISPLAY_FILL, 33, &wisp_display_fill_req_desc, &fill);
    CHECK(wisp_session_rx(&s, WISP_SVC_DISPLAY, in, n, 0, out, sizeof out, &r) == WISP_OK);
    CHECK(r.reply_len == 6 && wisp_hdr_decode(out, r.reply_len, &h) > 0 && h.op == WISP_OP_DISPLAY_FILL &&
          h.mflags == (WISP_MF_RESPONSE | WISP_MF_ERROR) && h.req == 33 && wisp_get16(out + 4) == WISP_ERR_NOT_ALLOWED);
    n = msg(in, WISP_OP_DISPLAY_FILL, 0, &wisp_display_fill_req_desc, &fill);
    wisp_session_rx(&s, WISP_SVC_DISPLAY, in, n, 0, out, sizeof out, &r);
    CHECK(r.reply_len == 0 && r.event == WISP_SESSION_NONE);
    wisp_session_ping_req_t ping = {0xCAFE};
    n = msg(in, WISP_OP_SESSION_PING, 2, &wisp_session_ping_req_desc, &ping);
    wisp_session_rx(&s, 0, in, n, 0, out, sizeof out, &r);
    CHECK(r.reply_len == 6 && wisp_get16(out + 4) == WISP_ERR_NOT_ALLOWED);
    CHECK(wisp_session_tick(&s, 60000000) == WISP_SESSION_NONE); /* nothing to time out */

    /* a HELLO cut inside a field is a bad payload */
    wisp_session_hello_req_t hello = {0, 1, 1024, 4000, "app", "test"};
    n = msg(in, WISP_OP_SESSION_HELLO, 3, &wisp_session_hello_req_desc, &hello);
    wisp_session_rx(&s, 0, in, 7, 0, out, sizeof out, &r);
    CHECK(!s.active && r.reply_len == 6 && wisp_get16(out + 4) == WISP_ERR_BAD_PAYLOAD);

    /* HELLO */
    CHECK(wisp_session_rx(&s, 0, in, n, 1000, out, 20, &r) == WISP_E_SPACE);
    wisp_session_rx(&s, 0, in, n, 1000, out, sizeof out, &r);
    wisp_session_hello_rsp_t rsp;
    CHECK(r.event == WISP_SESSION_STARTED && s.active && s.max_frame == 1024 && s.peer_window == 4000);
    CHECK(!strcmp(s.peer.app_id, "app"));
    CHECK(wisp_hdr_decode(out, r.reply_len, &h) > 0 && h.mflags == WISP_MF_RESPONSE && h.req == 3);
    CHECK(wisp_unpack(&wisp_session_hello_rsp_desc, out + 4, r.reply_len - 4, &rsp) == WISP_OK &&
          !strcmp(rsp.fw_name, "wisp") && rsp.max_frame == 2048 && rsp.session_timeout_ms == 5000);

    /* PING, TIME_SYNC, CREDIT, RESYNC, unknown op, other services */
    n = msg(in, WISP_OP_SESSION_PING, 4, &wisp_session_ping_req_desc, &ping);
    wisp_session_rx(&s, 0, in, n, 2000, out, sizeof out, &r);
    CHECK(r.reply_len == 8 && out[1] == WISP_MF_RESPONSE && wisp_get32(out + 4) == 0xCAFE);
    wisp_session_time_sync_req_t ts = {1762300800123ull};
    n = msg(in, WISP_OP_SESSION_TIME_SYNC, 5, &wisp_session_time_sync_req_desc, &ts);
    wisp_session_rx(&s, 0, in, n, 123456789ull, out, sizeof out, &r);
    CHECK(r.reply_len == 20 && wisp_get64(out + 4) == 1762300800123ull && wisp_get64(out + 12) == 123456789ull);
    wisp_session_credit_req_t credit = {0x1234};
    n = msg(in, WISP_OP_SESSION_CREDIT, 0, &wisp_session_credit_req_desc, &credit);
    wisp_session_rx(&s, 0, in, n, 3000, out, sizeof out, &r);
    CHECK(r.event == WISP_SESSION_CREDIT && r.seq == 0x1234 && r.reply_len == 0);
    wisp_session_resync_req_t resync = {41};
    n = msg(in, WISP_OP_SESSION_RESYNC, 0, &wisp_session_resync_req_desc, &resync);
    wisp_session_rx(&s, 0, in, n, 3000, out, sizeof out, &r);
    CHECK(r.event == WISP_SESSION_RESYNC && r.seq == 41);
    n = msg(in, 0x42, 6, NULL, NULL);
    wisp_session_rx(&s, 0, in, n, 3000, out, sizeof out, &r);
    CHECK(r.reply_len == 6 && wisp_get16(out + 4) == WISP_ERR_UNSUPPORTED);
    n = msg(in, WISP_OP_DISPLAY_FILL, 7, &wisp_display_fill_req_desc, &fill);
    wisp_session_rx(&s, WISP_SVC_DISPLAY, in, n, 4000, out, sizeof out, &r);
    CHECK(r.event == WISP_SESSION_DISPATCH && r.reply_len == 0);

    /* timeout counts from the last frame; fires once */
    CHECK(wisp_session_tick(&s, 4000 + 4999999) == WISP_SESSION_NONE);
    CHECK(wisp_session_tick(&s, 4000 + 5000000) == WISP_SESSION_ENDED && !s.active);
    CHECK(wisp_session_tick(&s, 4000 + 9000000) == WISP_SESSION_NONE);

    /* BYE ends it; then it's back to error 7 */
    n = msg(in, WISP_OP_SESSION_HELLO, 8, &wisp_session_hello_req_desc, &hello);
    wisp_session_rx(&s, 0, in, n, 10000000, out, sizeof out, &r);
    CHECK(r.event == WISP_SESSION_STARTED);
    n = msg(in, WISP_OP_SESSION_BYE, 0, NULL, NULL);
    wisp_session_rx(&s, 0, in, n, 10000001, out, sizeof out, &r);
    CHECK(r.event == WISP_SESSION_ENDED && !s.active && r.reply_len == 0);
    n = msg(in, WISP_OP_SESSION_PING, 9, &wisp_session_ping_req_desc, &ping);
    wisp_session_rx(&s, 0, in, n, 10000002, out, sizeof out, &r);
    CHECK(wisp_get16(out + 4) == WISP_ERR_NOT_ALLOWED);
}

int main(void) {
    test_crc();
    test_frame_basics();
    for (uint32_t seed = 1; seed <= 5; seed++) test_rx_chunking(seed);
    test_tx_window();
    test_lossy_link(7, 3000, 300, 0, 0);
    for (uint32_t seed = 1; seed <= 20; seed++) test_lossy_link(seed * 2654435761u, 2000, 600, 20, 10);
    test_lossy_link(11, 2000, 600, 200, 100); /* very noisy */
    test_lossy_link(13, 70000, 24, 2, 1);     /* seq wraps */
    test_msg_table();
    test_codecs();
    test_session();
    printf("core: %s\n", test_failures ? "FAILED" : "ok");
    return test_failures != 0;
}
