/* Wisp core: frames, the streaming receiver and the sender window.
 * MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/crc.h"
#include "wisp/frame.h"
#include "wisp/msgs.h"

static size_t min_sz(size_t a, size_t b) { return a < b ? a : b; }

static void put_header(uint8_t *h, uint8_t svc, uint8_t route, uint8_t fflags, uint16_t len, uint16_t seq) {
    h[0] = WISP_MAGIC;
    h[1] = svc;
    h[2] = route;
    h[3] = fflags;
    wisp_put16(h + 4, len);
    wisp_put16(h + 6, seq);
}

int wisp_frame_encode(uint8_t *out, size_t cap, uint8_t svc, uint8_t route, uint8_t fflags, uint16_t seq,
                      const uint8_t *body, size_t len) {
    if ((route & WISP_ROUTE_RESERVED) || (fflags & WISP_FF_RESERVED)) return WISP_E_ARG;
    if (len > 0xFFFF) return WISP_E_TOO_BIG;
    if (cap < len + WISP_FRAME_OVERHEAD) return WISP_E_SPACE;
    put_header(out, svc, route, fflags, (uint16_t)len, seq);
    if (len) memcpy(out + WISP_FRAME_HDR, body, len);
    wisp_put16(out + WISP_FRAME_HDR + len, wisp_crc16(WISP_CRC16_INIT, out, WISP_FRAME_HDR + len));
    return (int)(len + WISP_FRAME_OVERHEAD);
}

int wisp_ctrl_decode(const wisp_frame *f, uint16_t *seq) {
    if (f->svc != WISP_SVC_SESSION || !(f->fflags & WISP_FF_CTRL) || f->len < WISP_CTRL_BODY || f->body[1])
        return WISP_E_MALFORMED;
    uint8_t op = f->body[0];
    if (op != WISP_OP_SESSION_CREDIT && op != WISP_OP_SESSION_RESYNC) return WISP_E_MALFORMED;
    *seq = wisp_get16(f->body + 4);
    return op;
}

/* ---- receiver ---- */

void wisp_rx_init(wisp_rx *rx, uint8_t *buf, size_t cap) {
    memset(rx, 0, sizeof *rx);
    rx->buf = buf;
    rx->cap = cap;
    size_t max_body = cap > WISP_FRAME_OVERHEAD ? cap - WISP_FRAME_OVERHEAD : 0;
    rx->max_body = (uint16_t)min_sz(max_body, 0xFFFF);
    rx->last_good_seq = 0xFFFF;
}

static void rx_drop(wisp_rx *rx, size_t n) {
    rx->fill -= n;
    for (size_t i = 0; i < rx->fill; i++) rx->buf[i] = rx->buf[i + n]; /* overlapping, forward */
}

/* Counts discarded bytes; true when they start a new bad run, which asks for one RESYNC. */
static bool rx_bad(wisp_rx *rx, size_t n) {
    rx->bad_bytes += (uint32_t)n;
    if (rx->bad_run) return false;
    rx->bad_run = rx->recovering = true;
    return true;
}

/* buf[0] doesn't start a valid frame: drop up to the next magic byte. */
static bool rx_skip(wisp_rx *rx) {
    size_t i = 1;
    while (i < rx->fill && rx->buf[i] != WISP_MAGIC) i++;
    rx_drop(rx, i);
    return rx_bad(rx, i);
}

size_t wisp_rx_feed(wisp_rx *rx, const uint8_t *data, size_t len, wisp_rx_event *ev, wisp_frame *frame) {
    size_t used = 0;
    *ev = WISP_RX_NONE;
    if (rx->delivered) {
        rx_drop(rx, WISP_FRAME_OVERHEAD + wisp_get16(rx->buf + 4));
        rx->delivered = false;
    }
    for (;;) {
        /* Hunt for a magic byte: in the input when the buffer is empty, else in the buffer. */
        if (rx->fill == 0) {
            size_t start = used;
            while (used < len && data[used] != WISP_MAGIC) used++;
            if (used > start && rx_bad(rx, used - start)) goto resync;
            if (used == len) return used;
        } else if (rx->buf[0] != WISP_MAGIC) {
            if (rx_skip(rx)) goto resync;
            continue;
        }

        size_t need = WISP_FRAME_HDR;
        if (rx->fill >= WISP_FRAME_HDR) {
            uint16_t body_len = wisp_get16(rx->buf + 4);
            if (body_len > rx->max_body || (rx->buf[2] & WISP_ROUTE_RESERVED) || (rx->buf[3] & WISP_FF_RESERVED)) {
                if (rx_skip(rx)) goto resync;
                continue;
            }
            need += body_len + 2u;
        }
        if (rx->fill < need) {
            size_t n = min_sz(need - rx->fill, len - used);
            memcpy(rx->buf + rx->fill, data + used, n);
            rx->fill += n;
            used += n;
            if (rx->fill < need) return used; /* input exhausted */
            if (need == WISP_FRAME_HDR) continue;
        }

        /* buf[0, need) is a candidate frame (the buffer may hold more after a skip). */
        const uint8_t *b = rx->buf;
        if (wisp_crc16(WISP_CRC16_INIT, b, need - 2) != wisp_get16(b + need - 2)) {
            if (rx_skip(rx)) goto resync;
            continue;
        }
        rx->bad_run = false;
        uint16_t seq = wisp_get16(b + 6);
        uint16_t ahead = (uint16_t)(seq - (uint16_t)(rx->last_good_seq + 1u));
        bool ctrl = b[3] & WISP_FF_CTRL; /* outside the sequence: always passed on */
        if (ctrl || ahead == 0) {
            if (ctrl) {
                rx->controls++;
            } else {
                rx->last_good_seq = seq;
                rx->recovering = false;
                rx->frames++;
            }
            frame->svc = b[1];
            frame->route = b[2];
            frame->fflags = b[3];
            frame->len = wisp_get16(b + 4);
            frame->seq = seq;
            frame->body = b + WISP_FRAME_HDR;
            rx->delivered = true;
            *ev = ctrl ? WISP_RX_CONTROL : WISP_RX_FRAME;
            return used;
        }
        rx_drop(rx, need);
        if (ahead >= 0x8000u) {
            rx->dups++; /* already delivered: the sender may have missed our CREDIT */
            *ev = WISP_RX_DUPLICATE;
            return used;
        }
        rx->gaps++; /* a frame went missing; ask once, then wait for it */
        if (!rx->recovering) {
            rx->recovering = true;
            goto resync;
        }
    }
resync:
    *ev = WISP_RX_RESYNC;
    return used;
}

/* ---- sender ---- */

void wisp_tx_init(wisp_tx *tx, uint8_t *ring, size_t cap) {
    memset(tx, 0, sizeof *tx);
    tx->ring = ring;
    tx->cap = cap;
    wisp_tx_set_peer(tx, 0, 0);
    tx->window = WISP_PEER_WINDOW_INITIAL;
}

void wisp_tx_set_peer(wisp_tx *tx, uint16_t max_frame, uint32_t rx_window) {
    tx->max_body = max_frame ? max_frame : WISP_MAX_FRAME_DEFAULT;
    tx->window = rx_window ? rx_window : WISP_RX_WINDOW_DEFAULT;
}

/* Ring offsets below are relative to tail. */
static void ring_write(wisp_tx *tx, size_t off, const uint8_t *src, size_t n) {
    size_t i = (tx->tail + off) % tx->cap, first = min_sz(n, tx->cap - i);
    if (first) memcpy(tx->ring + i, src, first);
    if (n > first) memcpy(tx->ring, src + first, n - first);
}

static void ring_read(const wisp_tx *tx, size_t off, uint8_t *dst, size_t n) {
    size_t i = (tx->tail + off) % tx->cap, first = min_sz(n, tx->cap - i);
    if (first) memcpy(dst, tx->ring + i, first);
    if (n > first) memcpy(dst + first, tx->ring, n - first);
}

static size_t frame_size_at(const wisp_tx *tx, size_t off) {
    uint8_t h[WISP_FRAME_HDR];
    ring_read(tx, off, h, sizeof h);
    return WISP_FRAME_OVERHEAD + wisp_get16(h + 4);
}

static uint16_t tail_seq(const wisp_tx *tx) { return (uint16_t)(tx->next_seq - tx->nframes); }

int wisp_tx_send(wisp_tx *tx, uint8_t svc, uint8_t route, const uint8_t *body, size_t len) {
    size_t size = len + WISP_FRAME_OVERHEAD;
    if (len > tx->max_body || size > tx->window || size > tx->cap) return WISP_E_TOO_BIG;
    if (tx->used + size > tx->window || tx->used + size > tx->cap || tx->nframes >= 0x8000u) return WISP_E_WINDOW;
    if (route & WISP_ROUTE_RESERVED) return WISP_E_ARG;
    uint8_t h[WISP_FRAME_HDR], c[2];
    put_header(h, svc, route, 0, (uint16_t)len, tx->next_seq);
    wisp_put16(c, wisp_crc16(wisp_crc16(WISP_CRC16_INIT, h, sizeof h), body, len));
    ring_write(tx, tx->used, h, sizeof h);
    ring_write(tx, tx->used + WISP_FRAME_HDR, body, len);
    ring_write(tx, tx->used + WISP_FRAME_HDR + len, c, 2);
    tx->used += size;
    tx->nframes++;
    return tx->next_seq++;
}

static void do_ack(wisp_tx *tx, uint16_t ack_seq) {
    uint16_t n = (uint16_t)(ack_seq - tail_seq(tx) + 1u);
    if (n > tx->nframes) return; /* stale, or not sent yet */
    if (n) tx->acked = true;
    while (n--) {
        size_t size = frame_size_at(tx, 0);
        tx->tail = (tx->tail + size) % tx->cap;
        tx->used -= size;
        tx->sent = tx->sent > size ? tx->sent - size : 0;
        tx->nframes--;
    }
}

static void do_rewind(wisp_tx *tx, uint16_t first_seq) {
    int16_t skip = (int16_t)(uint16_t)(first_seq - tail_seq(tx));
    if (skip < 0) skip = 0; /* older than anything held: resend all */
    if (skip >= tx->nframes) return;
    size_t off = 0;
    while (skip--) off += frame_size_at(tx, off);
    if (off < tx->sent) {
        tx->sent = off;
        tx->resends++;
    }
}

/* Acks and rewinds wait for a frame boundary, so the link never carries half a frame. */
static void apply_pending(wisp_tx *tx) {
    if (tx->ack_pending) {
        tx->ack_pending = false;
        do_ack(tx, tx->ack_seq);
    }
    if (tx->rewind_pending) {
        tx->rewind_pending = false;
        do_rewind(tx, tx->rewind_seq);
    }
}

void wisp_tx_ack(wisp_tx *tx, uint16_t ack_seq) {
    if (tx->ack_pending && (int16_t)(uint16_t)(ack_seq - tx->ack_seq) <= 0) return;
    tx->ack_pending = true;
    tx->ack_seq = ack_seq;
    if (tx->frame_left == 0) apply_pending(tx);
}

void wisp_tx_resync(wisp_tx *tx, uint16_t last_good_seq) {
    wisp_tx_ack(tx, last_good_seq); /* the peer has everything up to last_good_seq */
    tx->rewind_pending = true;
    tx->rewind_seq = (uint16_t)(last_good_seq + 1u);
    if (tx->frame_left == 0) apply_pending(tx);
}

void wisp_tx_resend_all(wisp_tx *tx) { wisp_tx_resync(tx, (uint16_t)(tail_seq(tx) - 1u)); }

void wisp_tx_control(wisp_tx *tx, const wisp_frame *f) {
    uint16_t seq;
    int op = wisp_ctrl_decode(f, &seq);
    if (op == WISP_OP_SESSION_CREDIT) wisp_tx_ack(tx, seq);
    if (op == WISP_OP_SESSION_RESYNC) wisp_tx_resync(tx, seq);
}

void wisp_tx_queue_credit(wisp_tx *tx, uint16_t ack_seq) {
    tx->credit_queued = true;
    tx->credit_seq = ack_seq;
}

void wisp_tx_queue_resync(wisp_tx *tx, uint16_t last_good_seq) {
    tx->resync_queued = true;
    tx->resync_seq = last_good_seq;
}

/* At a frame boundary: starts the next queued control frame, if any. */
static bool ctrl_next(wisp_tx *tx) {
    uint8_t body[WISP_CTRL_BODY] = {0};
    uint16_t seq;
    if (tx->resync_queued) {
        tx->resync_queued = false;
        body[0] = WISP_OP_SESSION_RESYNC;
        seq = tx->resync_seq;
    } else if (tx->credit_queued) {
        tx->credit_queued = false;
        body[0] = WISP_OP_SESSION_CREDIT;
        seq = tx->credit_seq;
    } else {
        return false;
    }
    wisp_put16(body + 4, seq);
    int n = wisp_frame_encode(tx->ctrl, sizeof tx->ctrl, WISP_SVC_SESSION, tx->ctrl_route & 0x0Fu, WISP_FF_CTRL, 0,
                              body, sizeof body);
    tx->ctrl_off = 0;
    tx->ctrl_len = (uint8_t)n;
    return true;
}

size_t wisp_tx_pull(wisp_tx *tx, uint8_t *out, size_t cap) {
    size_t n = 0;
    while (n < cap) {
        if (tx->ctrl_off < tx->ctrl_len) {
            size_t k = min_sz((size_t)(tx->ctrl_len - tx->ctrl_off), cap - n);
            memcpy(out + n, tx->ctrl + tx->ctrl_off, k);
            tx->ctrl_off = (uint8_t)(tx->ctrl_off + k);
            n += k;
            continue;
        }
        if (tx->frame_left == 0) {
            apply_pending(tx);
            if (ctrl_next(tx)) continue;
            if (tx->sent == tx->used) break;
            tx->frame_left = frame_size_at(tx, tx->sent);
        }
        size_t k = min_sz(tx->frame_left, cap - n);
        ring_read(tx, tx->sent, out + n, k);
        tx->sent += k;
        tx->frame_left -= k;
        n += k;
    }
    if (tx->frame_left == 0) apply_pending(tx);
    return n;
}

bool wisp_tx_tick(wisp_tx *tx, uint32_t now_ms) {
    uint32_t timeout = tx->ack_timeout_ms ? tx->ack_timeout_ms : WISP_ACK_TIMEOUT_DEFAULT_MS;
    /* Nothing held, an ack came in, or frames still going out: nothing to wait for yet. */
    if (!tx->nframes || tx->acked || tx->sent < tx->used || tx->frame_left) {
        tx->acked = false;
        tx->progress_ms = now_ms;
        return false;
    }
    if ((uint32_t)(now_ms - tx->progress_ms) < timeout) return false;
    wisp_tx_resend_all(tx);
    tx->timeouts++;
    tx->progress_ms = now_ms;
    return true;
}

size_t wisp_tx_pending(const wisp_tx *tx) {
    return tx->used - tx->sent + (size_t)(tx->ctrl_len - tx->ctrl_off) +
           (tx->credit_queued ? WISP_CTRL_FRAME : 0u) + (tx->resync_queued ? WISP_CTRL_FRAME : 0u);
}
