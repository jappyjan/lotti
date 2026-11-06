/* Tests for wisp_conn (one glasses-side link connection) and wisp_basic. */
#include <string.h>

#include "test.h"
#include "wisp/conn.h"

/* ---- the glasses side under test ---- */

static const wisp_session_hello_rsp_t INFO = {
    .proto_major = 0, .proto_minor = 2, .max_frame = 1024, .rx_window = 4096, .fw_name = "wisp-test",
    .fw_version = "0.0.1", .lens = 1, .canvas_w = 640, .canvas_h = 480, .bpp = 4, .session_timeout_ms = 10000,
};

typedef struct {
    wisp_basic basic;
    wisp_conn c;
    uint8_t rxbuf[1024 + WISP_FRAME_OVERHEAD];
    uint8_t ring[8192];
    uint8_t queue[8192];
} glasses;

static void glasses_init(glasses *g, uint32_t rx_window) {
    wisp_basic_init(&g->basic, &INFO);
    wisp_conn_handler h = wisp_basic_handler(&g->basic);
    wisp_conn_config cfg = {g->rxbuf, sizeof g->rxbuf, g->ring, sizeof g->ring, g->queue, sizeof g->queue,
                            rx_window, 1, 0};
    CHECK(wisp_conn_init(&g->c, &cfg, &h) == WISP_OK);
    wisp_conn_open(&g->c, 0);
}

/* ---- a minimal phone: its own rx/tx, records what it receives ---- */

typedef struct {
    uint8_t svc;
    wisp_hdr h;
    uint8_t payload[256];
    size_t len;
} msg;

typedef struct {
    wisp_rx rx;
    wisp_tx tx;
    uint8_t rxbuf[4096 + WISP_FRAME_OVERHEAD];
    uint8_t ring[65536];
    msg got[512];
    size_t ngot;
    uint32_t credits_seen, resyncs_seen;
    bool credit_each_chunk;
} phone;

static void phone_init(phone *p) {
    memset(p, 0, sizeof *p);
    wisp_rx_init(&p->rx, p->rxbuf, sizeof p->rxbuf);
    wisp_tx_init(&p->tx, p->ring, sizeof p->ring);
    p->credit_each_chunk = true;
}

static int phone_try_send(phone *p, uint8_t svc, uint8_t op, uint8_t mflags, uint16_t req, const void *payload,
                          size_t plen) {
    uint8_t body[512];
    wisp_hdr h = {op, mflags, req};
    wisp_hdr_encode(body, &h);
    if (plen) memcpy(body + WISP_MSG_HDR, payload, plen);
    return wisp_tx_send(&p->tx, svc, 0, body, WISP_MSG_HDR + plen);
}

static void phone_send(phone *p, uint8_t svc, uint8_t op, uint8_t mflags, uint16_t req, const void *payload,
                       size_t plen) {
    CHECK(phone_try_send(p, svc, op, mflags, req, payload, plen) >= 0);
}

static void phone_hello(phone *p, uint16_t req, uint16_t max_frame, uint32_t rx_window) {
    wisp_session_hello_req_t m = {.proto_major = 0, .proto_minor = 2, .max_frame = max_frame,
                                  .rx_window = rx_window, .app_id = "com.example", .client_name = "test"};
    uint8_t pl[64];
    int n = wisp_pack(&wisp_session_hello_req_desc, &m, pl, sizeof pl);
    CHECK(n > 0);
    phone_send(p, WISP_SVC_SESSION, WISP_OP_SESSION_HELLO, 0, req, pl, (size_t)n);
}

static void phone_rx(phone *p, const uint8_t *data, size_t len) {
    wisp_rx_event ev;
    wisp_frame f;
    bool consumed = false;
    do {
        size_t n = wisp_rx_feed(&p->rx, data, len, &ev, &f);
        data += n;
        len -= n;
        if (ev == WISP_RX_CONTROL) {
            uint16_t seq;
            int op = wisp_ctrl_decode(&f, &seq);
            if (op == WISP_OP_SESSION_CREDIT) p->credits_seen++;
            if (op == WISP_OP_SESSION_RESYNC) p->resyncs_seen++;
            wisp_tx_control(&p->tx, &f);
        }
        if (ev == WISP_RX_DUPLICATE) wisp_tx_queue_credit(&p->tx, p->rx.last_good_seq);
        if (ev == WISP_RX_RESYNC) wisp_tx_queue_resync(&p->tx, p->rx.last_good_seq);
        if (ev == WISP_RX_FRAME) {
            consumed = true;
            CHECK(f.route == (1u << 2)); /* source lens: left */
            if (p->ngot < 512 && f.len >= WISP_MSG_HDR) {
                msg *m = &p->got[p->ngot++];
                m->svc = f.svc;
                wisp_hdr_decode(f.body, f.len, &m->h);
                m->len = f.len - WISP_MSG_HDR;
                if (m->len > sizeof m->payload) m->len = sizeof m->payload;
                memcpy(m->payload, f.body + WISP_MSG_HDR, m->len);
            }
        }
    } while (ev != WISP_RX_NONE);
    if (consumed && p->credit_each_chunk) wisp_tx_queue_credit(&p->tx, p->rx.last_good_seq);
}

/* Moves bytes both ways in chunks of `mtu` until both sides are quiet. */
static void pump(phone *p, glasses *g, size_t mtu, uint64_t now) {
    uint8_t buf[512];
    for (int guard = 0; guard < 10000; guard++) {
        size_t a = wisp_tx_pull(&p->tx, buf, mtu);
        if (a) wisp_conn_feed(&g->c, buf, a, now);
        size_t b = wisp_conn_pull(&g->c, buf, mtu, now);
        if (b) phone_rx(p, buf, b);
        if (!a && !b) return;
    }
    CHECK(!"pump did not settle");
}

static const msg *last(const phone *p) { return p->ngot ? &p->got[p->ngot - 1] : NULL; }

static void test_hello(void) {
    static glasses g;
    static phone p;
    for (size_t mtu = 1; mtu <= 244; mtu = mtu * 3 + 1) {
        glasses_init(&g, 0);
        phone_init(&p);
        CHECK(!wisp_conn_session_active(&g.c));
        phone_hello(&p, 1, 0, 0);
        pump(&p, &g, mtu, 1000);
        CHECK(wisp_conn_events(&g.c) == WISP_CONN_STARTED);
        CHECK(wisp_conn_session_active(&g.c));
        CHECK(p.ngot == 1);
        const msg *m = last(&p);
        CHECK(m && m->svc == WISP_SVC_SESSION && m->h.op == WISP_OP_SESSION_HELLO && m->h.req == 1 &&
              m->h.mflags == WISP_MF_RESPONSE);
        wisp_session_hello_rsp_t rsp;
        CHECK(m && wisp_unpack(&wisp_session_hello_rsp_desc, m->payload, m->len, &rsp) == WISP_OK);
        CHECK(!strcmp(rsp.fw_name, "wisp-test") && rsp.max_frame == 1024 && rsp.rx_window == 4096);
        /* the phone's defaults apply now: 4096 frames, 16 KiB window, our max_frame is smaller */
        CHECK(g.c.tx.window == WISP_RX_WINDOW_DEFAULT && g.c.tx.max_body == 1024);
        CHECK(g.basic.session.max_frame == 1024);
    }
}

static void test_errors(void) {
    static glasses g;
    static phone p;
    glasses_init(&g, 0);
    phone_init(&p);
    uint8_t token[4] = {1, 2, 3, 4};
    phone_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, 7, token, 4); /* before HELLO */
    phone_send(&p, 2, 8, 0, 8, "\0", 1);                                     /* display COMMIT before HELLO */
    pump(&p, &g, 20, 0);
    CHECK(p.ngot == 2);
    CHECK(p.got[0].h.req == 7 && p.got[0].h.mflags == (WISP_MF_RESPONSE | WISP_MF_ERROR) &&
          wisp_get16(p.got[0].payload) == WISP_ERR_NOT_ALLOWED);
    CHECK(p.got[1].h.req == 8 && wisp_get16(p.got[1].payload) == WISP_ERR_NOT_ALLOWED);

    phone_hello(&p, 1, 0, 0);
    phone_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, 9, token, 4);
    phone_send(&p, 2, 8, 0, 10, "\0", 1);           /* not implemented here: error 1 */
    phone_send(&p, 2, 8, 0, 0, "\0", 1);            /* req 0: no answer, not even an error */
    phone_send(&p, 4, 2, WISP_MF_EVENT, 11, "", 0); /* an event: never answered */
    pump(&p, &g, 20, 0);
    CHECK(p.ngot == 5);
    CHECK(p.got[3].h.req == 9 && p.got[3].h.mflags == WISP_MF_RESPONSE && p.got[3].len == 4 &&
          !memcmp(p.got[3].payload, token, 4));
    CHECK(p.got[4].svc == 2 && p.got[4].h.req == 10 && p.got[4].h.op == 8 &&
          wisp_get16(p.got[4].payload) == WISP_ERR_UNSUPPORTED);
}

static void test_credit_coalescing(void) {
    static glasses g;
    static phone p;
    uint8_t buf[256];
    glasses_init(&g, 1024);
    phone_init(&p);
    phone_hello(&p, 1, 0, 0);
    pump(&p, &g, 244, 0);
    uint32_t c0 = p.credits_seen;
    CHECK(c0 == 1); /* the HELLO's CREDIT went out right away, ahead of the response */

    /* A frame with nothing to answer: the CREDIT waits for the 20 ms deadline. */
    phone_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, 0, "abcd", 4);
    size_t n = wisp_tx_pull(&p.tx, buf, sizeof buf);
    wisp_conn_feed(&g.c, buf, n, 100000);
    CHECK(wisp_conn_pending(&g.c) == 0);
    CHECK(wisp_conn_deadline(&g.c, 100000) == 100000 + WISP_CONN_CREDIT_DELAY_US);
    CHECK(wisp_conn_tick(&g.c, 119999) == 120000);
    CHECK(wisp_conn_pending(&g.c) == 0);
    wisp_conn_tick(&g.c, 120000);
    CHECK(wisp_conn_pending(&g.c) == WISP_CTRL_FRAME);
    n = wisp_conn_pull(&g.c, buf, sizeof buf, 120000);
    phone_rx(&p, buf, n);
    CHECK(p.credits_seen == c0 + 1);
    CHECK(wisp_conn_deadline(&g.c, 120000) == 120000 + 10000000ull - 20000); /* only the session timeout */

    /* A quarter of the 1 KiB window consumed: CREDIT at once. */
    uint8_t blob[100] = {0};
    for (int i = 0; i < 3; i++) phone_send(&p, 0x80, 1, 0, 0, blob, sizeof blob); /* 3 × 114 B ≥ 256 */
    n = wisp_tx_pull(&p.tx, buf, sizeof buf);
    wisp_conn_feed(&g.c, buf, n, 200000);
    CHECK(wisp_conn_pending(&g.c) == 0); /* 2 frames = 228 B < 256 */
    n = wisp_tx_pull(&p.tx, buf, sizeof buf);
    wisp_conn_feed(&g.c, buf, n, 200000);
    CHECK(wisp_conn_pending(&g.c) == WISP_CTRL_FRAME);
}

static void test_window_queue(void) {
    static glasses g;
    static phone p;
    glasses_init(&g, 0);
    phone_init(&p);
    p.credit_each_chunk = false;
    phone_hello(&p, 1, 0, 100); /* the phone takes at most 100 bytes in flight */
    pump(&p, &g, 244, 0);
    wisp_tx_queue_credit(&p.tx, p.rx.last_good_seq);
    pump(&p, &g, 244, 0);
    CHECK(g.c.tx.window == 100 && g.c.tx.nframes == 0);
    size_t before = p.ngot;
    uint8_t body[40];
    for (uint8_t i = 0; i < 20; i++) {
        wisp_hdr h = {3, WISP_MF_EVENT, 0};
        wisp_hdr_encode(body, &h);
        memset(body + WISP_MSG_HDR, i, sizeof body - WISP_MSG_HDR);
        CHECK(wisp_conn_send(&g.c, 0x80, body, sizeof body) == WISP_OK);
    }
    CHECK(g.c.qlen > 0);         /* 2 frames of 50 B fit, the rest waits */
    CHECK(g.c.tx.used <= 100);
    for (int round = 0; round < 40 && g.c.qlen + g.c.tx.nframes; round++) {
        pump(&p, &g, 244, 0);
        wisp_tx_queue_credit(&p.tx, p.rx.last_good_seq);
        pump(&p, &g, 244, 0);
    }
    CHECK(g.c.qlen == 0 && g.c.tx.nframes == 0);
    CHECK(p.ngot == before + 20);
    for (uint8_t i = 0; i < 20 && before + i < p.ngot; i++) CHECK(p.got[before + i].payload[0] == i); /* in order */

    /* A peer that stops reading fills the queue: sends fail, nothing breaks. */
    uint8_t big[80] = {0};
    int fails = 0;
    for (int i = 0; i < 200; i++) fails += wisp_conn_send(&g.c, 0x80, big, sizeof big) == WISP_E_SPACE;
    CHECK(fails > 0 && g.c.stats.dropped == (uint32_t)fails);
}

static void test_resync_and_ack_timeout(void) {
    static glasses g;
    static phone p;
    uint8_t buf[256];
    glasses_init(&g, 0);
    phone_init(&p);
    phone_hello(&p, 1, 0, 0);
    pump(&p, &g, 244, 0);

    /* A corrupted byte from the phone: RESYNC {last_good_seq}. */
    phone_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, 5, "wxyz", 4);
    size_t n = wisp_tx_pull(&p.tx, buf, sizeof buf);
    buf[9] ^= 0x40;
    wisp_conn_feed(&g.c, buf, n, 1000);
    CHECK(g.c.stats.resyncs_sent == 1);
    n = wisp_conn_pull(&g.c, buf, sizeof buf, 1000);
    phone_rx(&p, buf, n);
    CHECK(p.resyncs_seen == 1);
    size_t before = p.ngot;
    pump(&p, &g, 244, 1000); /* the phone resent it */
    CHECK(p.ngot == before + 1 && last(&p)->h.req == 5);

    /* Our frame's CREDIT never comes: resent after the ack timeout, counted from the pull. */
    p.credit_each_chunk = false;
    phone_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, 6, "1234", 4);
    n = wisp_tx_pull(&p.tx, buf, sizeof buf);
    wisp_conn_feed(&g.c, buf, n, 2000000);
    n = wisp_conn_pull(&g.c, buf, sizeof buf, 2000000);
    CHECK(n > 0);
    CHECK(wisp_conn_pull(&g.c, buf, sizeof buf, 2000000) == 0);
    CHECK(wisp_conn_deadline(&g.c, 2000000) == 3000000);
    CHECK(wisp_conn_tick(&g.c, 2999000) == 3000000 && g.c.tx.timeouts == 0);
    wisp_conn_tick(&g.c, 3000000);
    CHECK(g.c.tx.timeouts == 1 && wisp_conn_pending(&g.c) > 0);
}

static void test_session_timeout_and_reconnect(void) {
    static glasses g;
    static phone p;
    glasses_init(&g, 0);
    phone_init(&p);
    phone_hello(&p, 1, 0, 0);
    pump(&p, &g, 244, 5000000);
    CHECK(wisp_conn_events(&g.c) == WISP_CONN_STARTED);
    CHECK(wisp_conn_deadline(&g.c, 5000000) == 5000000 + 20000 || wisp_conn_deadline(&g.c, 5000000) == 15000000);
    while (wisp_conn_deadline(&g.c, 5000000) < 15000000) wisp_conn_tick(&g.c, wisp_conn_deadline(&g.c, 5000000));
    CHECK(wisp_conn_tick(&g.c, 14999999) == 15000000);
    CHECK(wisp_conn_events(&g.c) == 0);
    CHECK(wisp_conn_tick(&g.c, 15000000) == WISP_CONN_NEVER); /* nothing left to wait for */
    CHECK(wisp_conn_events(&g.c) == WISP_CONN_ENDED && !wisp_conn_session_active(&g.c));

    /* A new HELLO on the same link starts a new session; closing the link ends it. */
    phone_hello(&p, 2, 0, 0);
    pump(&p, &g, 244, 16000000);
    CHECK(wisp_conn_events(&g.c) == WISP_CONN_STARTED);
    wisp_conn_close(&g.c, 16000000);
    CHECK(wisp_conn_events(&g.c) == WISP_CONN_ENDED && !wisp_conn_session_active(&g.c));
    uint8_t buf[64];
    CHECK(wisp_conn_pull(&g.c, buf, sizeof buf, 16000000) == 0);
    CHECK(wisp_conn_send(&g.c, 0, buf, 4) == WISP_E_SPACE);
    wisp_conn_close(&g.c, 16000000); /* twice is fine, no second event */
    CHECK(wisp_conn_events(&g.c) == 0);

    /* Reconnect: sequence numbers start over. */
    wisp_conn_open(&g.c, 17000000);
    phone_init(&p);
    phone_hello(&p, 1, 0, 0);
    pump(&p, &g, 244, 17000000);
    CHECK(wisp_conn_events(&g.c) == WISP_CONN_STARTED && p.ngot == 1);
}

/* PINGs over a link that drops whole chunks both ways: every response arrives once, in order,
 * driven only by the deadlines wisp_conn_tick returns and the phone's own ack timeout. */
static void test_lossy(uint32_t seed) {
    static glasses g;
    static phone p;
    glasses_init(&g, 2048);
    phone_init(&p);
    phone_hello(&p, 1, 0, 0);
    uint64_t now = 0;
    uint16_t sent = 0;
    uint8_t buf[512];
    const uint16_t total = 300;
    for (int step = 0; step < 200000 && p.ngot < total + 1u; step++) {
        if (sent < total && wisp_tx_pending(&p.tx) < 200) {
            uint8_t tok[4];
            wisp_put32(tok, sent);
            if (phone_try_send(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 0, (uint16_t)(sent + 2), tok, 4) >= 0)
                sent++;
        }
        size_t a = wisp_tx_pull(&p.tx, buf, 1 + rnd(&seed) % 120);
        if (a && rnd(&seed) % 100 >= 3) wisp_conn_feed(&g.c, buf, a, now);
        size_t b = wisp_conn_pull(&g.c, buf, 1 + rnd(&seed) % 120, now);
        if (b && rnd(&seed) % 100 >= 3) phone_rx(&p, buf, b);
        now += 1000; /* 1 ms per step */
        if (wisp_conn_deadline(&g.c, now) <= now) wisp_conn_tick(&g.c, now);
        wisp_tx_tick(&p.tx, (uint32_t)(now / 1000));
    }
    CHECK(p.ngot == total + 1u);
    for (uint16_t i = 0; i < total && i + 1u < p.ngot; i++) {
        const msg *m = &p.got[i + 1];
        CHECK(m->h.req == i + 2 && wisp_get32(m->payload) == i);
    }
    CHECK(wisp_conn_session_active(&g.c));
}

int main(void) {
    test_hello();
    test_errors();
    test_credit_coalescing();
    test_window_queue();
    test_resync_and_ack_timeout();
    test_session_timeout_and_reconnect();
    for (uint32_t seed = 1; seed <= 20; seed++) test_lossy(seed * 2654435761u);
    if (test_failures) {
        fprintf(stderr, "%d check(s) failed\n", test_failures);
        return 1;
    }
    printf("conn: all tests passed\n");
    return 0;
}
