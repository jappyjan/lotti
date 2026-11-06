/* Wisp core: one link connection on the glasses side. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/conn.h"

#define QHDR 4u /* queued body: svc, route, len u16 */

static uint32_t ms_of(uint64_t us) { return (uint32_t)(us / 1000u); }

static uint32_t rx_window(const wisp_conn *c) { return c->cfg.rx_window ? c->cfg.rx_window : WISP_RX_WINDOW_DEFAULT; }

static uint8_t our_route(const wisp_conn *c) { return (uint8_t)((c->cfg.lens & 3u) << 2); }

static void reset_link(wisp_conn *c) {
    wisp_rx_init(&c->rx, c->cfg.rx_buf, c->cfg.rx_cap);
    wisp_tx_init(&c->tx, c->cfg.ring, c->cfg.ring_cap);
    c->tx.ctrl_route = our_route(c);
    c->tx.ack_timeout_ms = c->cfg.ack_timeout_ms;
    c->consumed = 0;
    c->credit_due_us = WISP_CONN_NEVER;
    c->qlen = 0;
}

int wisp_conn_init(wisp_conn *c, const wisp_conn_config *cfg, const wisp_conn_handler *h) {
    if (!cfg->rx_buf || cfg->rx_cap <= WISP_FRAME_OVERHEAD || !cfg->ring || cfg->ring_cap <= WISP_FRAME_OVERHEAD ||
        (cfg->queue_cap && !cfg->queue) || !h->rx || !h->session)
        return WISP_E_ARG;
    memset(c, 0, sizeof *c);
    c->cfg = *cfg;
    c->h = *h;
    reset_link(c);
    return WISP_OK;
}

void wisp_conn_open(wisp_conn *c, uint64_t now_us) {
    (void)now_us;
    reset_link(c);
    c->open = true;
}

static const wisp_session *session(const wisp_conn *c) { return c->h.session(c->h.ctx); }

bool wisp_conn_session_active(const wisp_conn *c) { return session(c)->active; }

static void handle(wisp_conn *c, const wisp_frame *f, uint64_t now_us, bool control) {
    wisp_session_result r;
    c->h.rx(c->h.ctx, c, f->svc, f->body, f->len, now_us, &r);
    if (control) return; /* the frame itself was applied to the sender; the handler only saw traffic */
    switch (r.event) {
    case WISP_SESSION_STARTED: {
        const wisp_session *s = session(c);
        wisp_tx_set_peer(&c->tx, s->max_frame, s->peer_window);
        c->events |= WISP_CONN_STARTED;
        break;
    }
    case WISP_SESSION_ENDED:
        c->events |= WISP_CONN_ENDED;
        break;
    case WISP_SESSION_CREDIT:
        wisp_tx_ack(&c->tx, r.seq);
        break;
    case WISP_SESSION_RESYNC:
        wisp_tx_resync(&c->tx, r.seq);
        break;
    default:
        break;
    }
}

void wisp_conn_close(wisp_conn *c, uint64_t now_us) {
    if (c->open && wisp_conn_session_active(c)) {
        /* Same effect as the phone's BYE (req 0: no response). */
        uint8_t bye[WISP_MSG_HDR] = {WISP_OP_SESSION_BYE, 0, 0, 0};
        wisp_frame f = {WISP_SVC_SESSION, 0, 0, 0, sizeof bye, bye};
        c->open = false; /* nothing more goes out on this link */
        handle(c, &f, now_us, false);
        c->events |= WISP_CONN_ENDED;
    }
    c->open = false;
    reset_link(c);
}

/* Moves queued bodies into the sender while the window has room. */
static void flush_queue(wisp_conn *c) {
    size_t off = 0;
    while (off < c->qlen) {
        uint8_t *q = c->cfg.queue + off;
        size_t len = wisp_get16(q + 2);
        int r = wisp_tx_send(&c->tx, q[0], q[1], q + QHDR, len);
        if (r == WISP_E_WINDOW) break;
        if (r < 0) c->stats.dropped++; /* too big for the peer's limits after all: drop */
        off += QHDR + len;
    }
    if (off) {
        memmove(c->cfg.queue, c->cfg.queue + off, c->qlen - off);
        c->qlen -= off;
    }
}

int wisp_conn_send(wisp_conn *c, uint8_t svc, const uint8_t *body, size_t len) {
    if (!c->open) {
        c->stats.dropped++;
        return WISP_E_SPACE;
    }
    if (len > 0xFFFFu) return WISP_E_TOO_BIG;
    if (!c->qlen) {
        int r = wisp_tx_send(&c->tx, svc, our_route(c), body, len);
        if (r >= 0) return WISP_OK;
        if (r != WISP_E_WINDOW) return r;
    }
    if (c->qlen + QHDR + len > c->cfg.queue_cap) {
        c->stats.dropped++;
        return WISP_E_SPACE;
    }
    uint8_t *q = c->cfg.queue + c->qlen;
    q[0] = svc;
    q[1] = our_route(c);
    wisp_put16(q + 2, (uint16_t)len);
    if (len) memcpy(q + QHDR, body, len);
    c->qlen += QHDR + len;
    return WISP_OK;
}

static void send_credit(wisp_conn *c) {
    wisp_tx_queue_credit(&c->tx, c->rx.last_good_seq);
    c->consumed = 0;
    c->credit_due_us = WISP_CONN_NEVER;
}

void wisp_conn_feed(wisp_conn *c, const uint8_t *data, size_t len, uint64_t now_us) {
    if (!c->open) return;
    c->stats.rx_bytes += (uint32_t)len;
    wisp_rx_event ev;
    wisp_frame f;
    do {
        size_t n = wisp_rx_feed(&c->rx, data, len, &ev, &f);
        data += n;
        len -= n;
        switch (ev) {
        case WISP_RX_FRAME:
            c->stats.frames++;
            c->consumed += (uint32_t)f.len + WISP_FRAME_OVERHEAD;
            if (c->credit_due_us == WISP_CONN_NEVER) c->credit_due_us = now_us + WISP_CONN_CREDIT_DELAY_US;
            handle(c, &f, now_us, false);
            break;
        case WISP_RX_CONTROL:
            wisp_tx_control(&c->tx, &f);
            handle(c, &f, now_us, true);
            break;
        case WISP_RX_DUPLICATE:
            c->stats.dups++;
            wisp_tx_queue_credit(&c->tx, c->rx.last_good_seq);
            break;
        case WISP_RX_RESYNC:
            c->stats.resyncs_sent++;
            wisp_tx_queue_resync(&c->tx, c->rx.last_good_seq);
            break;
        default:
            break;
        }
    } while (ev != WISP_RX_NONE);
    flush_queue(c); /* a CREDIT may have opened the window */
    /* Our CREDIT: now if a quarter of the window is used or bytes go out anyway, else at the
     * 20 ms deadline (wisp_conn_tick). */
    if (c->consumed && ((uint64_t)c->consumed * 4u >= rx_window(c) || wisp_tx_pending(&c->tx)))
        send_credit(c);
}

size_t wisp_conn_pull(wisp_conn *c, uint8_t *out, size_t cap, uint64_t now_us) {
    if (!c->open) return 0;
    flush_queue(c);
    if (c->consumed && wisp_tx_pending(&c->tx)) send_credit(c); /* rides along */
    /* While frames are still going out this only restarts the ack-timeout clock. */
    wisp_tx_tick(&c->tx, ms_of(now_us));
    size_t n = wisp_tx_pull(&c->tx, out, cap);
    c->stats.tx_bytes += (uint32_t)n;
    return n;
}

size_t wisp_conn_pending(const wisp_conn *c) { return c->open ? wisp_tx_pending(&c->tx) : 0; }

uint64_t wisp_conn_deadline(const wisp_conn *c, uint64_t now_us) {
    uint64_t d = WISP_CONN_NEVER;
    if (c->h.deadline) d = c->h.deadline(c->h.ctx, now_us);
    if (!c->open) return d;
    if (c->consumed && c->credit_due_us < d) d = c->credit_due_us;
    const wisp_tx *tx = &c->tx;
    if (tx->nframes && tx->sent >= tx->used && !tx->frame_left) {
        /* Everything held went out: the ack timeout runs from the last progress. */
        uint32_t timeout = tx->ack_timeout_ms ? tx->ack_timeout_ms : WISP_ACK_TIMEOUT_DEFAULT_MS;
        uint32_t waited = ms_of(now_us) - tx->progress_ms;
        uint64_t at = now_us + (waited >= timeout ? 0u : (uint64_t)(timeout - waited) * 1000u);
        if (at < d) d = at;
    }
    return d < now_us ? now_us : d;
}

uint64_t wisp_conn_tick(wisp_conn *c, uint64_t now_us) {
    if (c->h.tick && c->h.tick(c->h.ctx, c, now_us)) c->events |= WISP_CONN_ENDED;
    if (c->open) {
        if (c->consumed && now_us >= c->credit_due_us) send_credit(c);
        wisp_tx_tick(&c->tx, ms_of(now_us));
        flush_queue(c);
    }
    return wisp_conn_deadline(c, now_us);
}

uint32_t wisp_conn_events(wisp_conn *c) {
    uint32_t e = c->events;
    c->events = 0;
    return e;
}

/* ---- the session alone ---- */

static void basic_rx(void *ctx, wisp_conn *c, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
                     wisp_session_result *r) {
    wisp_basic *b = ctx;
    if (wisp_session_rx(&b->session, svc, body, len, now_us, b->reply, sizeof b->reply, r) < 0) {
        r->reply_len = 0;
        return;
    }
    if (r->reply_len) {
        wisp_conn_send(c, svc, b->reply, r->reply_len);
        return;
    }
    wisp_hdr h;
    if (r->event == WISP_SESSION_DISPATCH && wisp_hdr_decode(body, len, &h) >= 0 && h.req &&
        !(h.mflags & (WISP_MF_RESPONSE | WISP_MF_ERROR | WISP_MF_EVENT))) {
        int n = wisp_msg_error(b->reply, sizeof b->reply, h.op, h.req, WISP_ERR_UNSUPPORTED, NULL);
        if (n > 0) wisp_conn_send(c, svc, b->reply, (size_t)n);
    }
}

static bool basic_tick(void *ctx, wisp_conn *c, uint64_t now_us) {
    (void)c;
    return wisp_session_tick(&((wisp_basic *)ctx)->session, now_us) == WISP_SESSION_ENDED;
}

static uint64_t basic_deadline(void *ctx, uint64_t now_us) {
    const wisp_session *s = &((wisp_basic *)ctx)->session;
    (void)now_us;
    if (!s->active) return WISP_CONN_NEVER;
    uint32_t ms = s->info->session_timeout_ms ? s->info->session_timeout_ms : WISP_SESSION_TIMEOUT_DEFAULT_MS;
    return s->last_rx_us + (uint64_t)ms * 1000u;
}

static const wisp_session *basic_session(void *ctx) { return &((wisp_basic *)ctx)->session; }

void wisp_basic_init(wisp_basic *b, const wisp_session_hello_rsp_t *info) {
    memset(b, 0, sizeof *b);
    wisp_session_init(&b->session, info);
}

wisp_conn_handler wisp_basic_handler(wisp_basic *b) {
    wisp_conn_handler h = {b, basic_rx, basic_tick, basic_deadline, basic_session};
    return h;
}
