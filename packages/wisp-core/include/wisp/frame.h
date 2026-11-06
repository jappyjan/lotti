/* Wisp core: frames, the streaming receiver and the sender window.
 * MIT License, Wisp contributors.
 *
 * Frame: magic 0x57, svc, route, fflags, len u16, seq u16, body[len], crc u16
 * (CRC-16/CCITT-FALSE over everything before it). See docs/wisp/protocol.md. */
#ifndef WISP_FRAME_H
#define WISP_FRAME_H

#include "common.h"

#define WISP_MAGIC 0x57u
#define WISP_FRAME_HDR 8u
#define WISP_FRAME_OVERHEAD 10u
#define WISP_MAX_FRAME_DEFAULT 4096u /* max body length unless HELLO says otherwise */
#define WISP_RX_WINDOW_DEFAULT 16384u
/* The peer's window until its HELLO (response) says otherwise: one default frame. */
#define WISP_PEER_WINDOW_INITIAL (WISP_MAX_FRAME_DEFAULT + WISP_FRAME_OVERHEAD)
#define WISP_ACK_TIMEOUT_DEFAULT_MS 1000u

/* fflags bit 0: an unsequenced control frame (CREDIT, RESYNC). Every other
 * fflags bit and route bits 4-7 are reserved: nonzero makes the frame bad. */
#define WISP_FF_CTRL 0x01u
#define WISP_FF_RESERVED 0xFEu
#define WISP_ROUTE_RESERVED 0xF0u
/* A control frame's body: op, mflags 0, req 0, then the u16 seq. */
#define WISP_CTRL_BODY 6u
#define WISP_CTRL_FRAME (WISP_CTRL_BODY + WISP_FRAME_OVERHEAD)

typedef struct {
    uint8_t svc, route, fflags;
    uint16_t seq;
    uint16_t len;
    const uint8_t *body;
} wisp_frame;

/* Writes one frame; returns its size (len + 10) or WISP_E_SPACE / WISP_E_TOO_BIG, or
 * WISP_E_ARG for reserved bits in route or fflags. */
int wisp_frame_encode(uint8_t *out, size_t cap, uint8_t svc, uint8_t route, uint8_t fflags, uint16_t seq,
                      const uint8_t *body, size_t len);

/* A control frame's CREDIT {ack_seq} or RESYNC {last_good_seq}: returns WISP_OP_SESSION_CREDIT
 * or WISP_OP_SESSION_RESYNC and sets *seq, or WISP_E_MALFORMED for anything else. */
int wisp_ctrl_decode(const wisp_frame *f, uint16_t *seq);

/* ---- receiver ----
 *
 * Feed it the link's bytes in any chunking. It delivers frames in seq order
 * (seq starts at 0 per connection), passes control frames through whatever
 * its state, reports duplicates (answer each with a CREDIT), and asks for a
 * RESYNC {last_good_seq} when it had to discard bytes or saw a seq gap.
 * Frames after a gap are dropped; the sender resends them.
 *
 *   do {
 *       size_t n = wisp_rx_feed(&rx, p, len, &ev, &f);
 *       p += n; len -= n;
 *       if (ev == WISP_RX_FRAME) handle(&f);              // f.body valid until the next feed
 *       if (ev == WISP_RX_CONTROL) wisp_tx_control(&tx, &f);
 *       if (ev == WISP_RX_DUPLICATE) wisp_tx_queue_credit(&tx, rx.last_good_seq);
 *       if (ev == WISP_RX_RESYNC) wisp_tx_queue_resync(&tx, rx.last_good_seq);
 *   } while (ev != WISP_RX_NONE);
 */
typedef enum {
    WISP_RX_NONE,
    WISP_RX_FRAME,     /* the next frame in sequence */
    WISP_RX_CONTROL,   /* a control frame (fflags CTRL); f.seq is meaningless */
    WISP_RX_DUPLICATE, /* a frame already delivered: answer with CREDIT {last_good_seq} */
    WISP_RX_RESYNC,    /* send RESYNC {last_good_seq} */
} wisp_rx_event;

typedef struct {
    uint8_t *buf;           /* holds one frame: max body + 10 bytes */
    size_t cap;
    size_t fill;
    uint16_t max_body;
    uint16_t last_good_seq; /* 0xFFFF before the first frame */
    bool recovering;        /* RESYNC asked, waiting for last_good_seq + 1 */
    bool bad_run;           /* inside a run of discarded bytes */
    bool delivered;         /* buf holds the frame returned last time */
    uint32_t frames, controls, bad_bytes, dups, gaps;
} wisp_rx;

void wisp_rx_init(wisp_rx *rx, uint8_t *buf, size_t cap);
/* Returns how many input bytes it consumed; WISP_RX_NONE means all of them. */
size_t wisp_rx_feed(wisp_rx *rx, const uint8_t *data, size_t len, wisp_rx_event *ev, wisp_frame *frame);

/* ---- sender ----
 *
 * Frames are encoded into a caller-provided ring and kept there until
 * CREDIT acknowledges them, so RESYNC can resend them. The ring never holds
 * more than the peer's rx_window, which is the protocol's credit rule.
 * Control frames (our CREDIT and RESYNC) don't take ring or window space:
 * the latest of each waits in the sender and goes out at the next frame
 * boundary, ahead of data. The link pulls bytes in whatever chunks it can
 * carry. Call wisp_tx_tick periodically for the ack timeout. */
typedef struct {
    uint8_t *ring;
    size_t cap;
    size_t tail;       /* ring index of the oldest unacknowledged frame */
    size_t used;       /* bytes held */
    size_t sent;       /* bytes past tail pulled in the current pass */
    size_t frame_left; /* bytes of the frame being pulled still to go; 0 at a frame boundary */
    uint16_t next_seq;
    uint16_t nframes;
    uint16_t max_body; /* peer max_frame */
    uint32_t window;   /* peer rx_window */
    bool ack_pending, rewind_pending;
    uint16_t ack_seq, rewind_seq;
    bool credit_queued, resync_queued; /* our control frames waiting to go out */
    uint16_t credit_seq, resync_seq;
    uint8_t ctrl_route;                /* route byte of our control frames */
    uint8_t ctrl[WISP_CTRL_FRAME];     /* the control frame being pulled */
    uint8_t ctrl_off, ctrl_len;
    uint32_t ack_timeout_ms;           /* 0 = WISP_ACK_TIMEOUT_DEFAULT_MS */
    uint32_t progress_ms;              /* last tick with nothing to wait for, or the last ack */
    bool acked;                        /* an ack freed frames since the last tick */
    uint32_t resends, timeouts;
} wisp_tx;

/* Until wisp_tx_set_peer, the peer window is WISP_PEER_WINDOW_INITIAL. */
void wisp_tx_init(wisp_tx *tx, uint8_t *ring, size_t cap);
/* After HELLO: the peer's limits (0 = defaults). */
void wisp_tx_set_peer(wisp_tx *tx, uint16_t max_frame, uint32_t rx_window);
/* Queues a frame. Returns its seq, or WISP_E_WINDOW (retry after CREDIT) / WISP_E_TOO_BIG. */
int wisp_tx_send(wisp_tx *tx, uint8_t svc, uint8_t route, const uint8_t *body, size_t len);
/* Copies up to cap bytes of frames to transmit; returns the count. */
size_t wisp_tx_pull(wisp_tx *tx, uint8_t *out, size_t cap);
/* CREDIT {ack_seq}: frees every frame up to and including ack_seq. */
void wisp_tx_ack(wisp_tx *tx, uint16_t ack_seq);
/* RESYNC {last_good_seq}: resend every held frame after last_good_seq. */
void wisp_tx_resync(wisp_tx *tx, uint16_t last_good_seq);
/* Resend every held frame (what the ack timeout does). */
void wisp_tx_resend_all(wisp_tx *tx);
/* A received control frame (WISP_RX_CONTROL): applies its CREDIT or RESYNC. */
void wisp_tx_control(wisp_tx *tx, const wisp_frame *f);
/* Queue our CREDIT {ack_seq} / RESYNC {last_good_seq}; a newer one replaces a waiting one. */
void wisp_tx_queue_credit(wisp_tx *tx, uint16_t ack_seq);
void wisp_tx_queue_resync(wisp_tx *tx, uint16_t last_good_seq);
/* Ack timeout: once every frame held has been pulled and no CREDIT freed any of them for
 * ack_timeout_ms, resends them all. Returns true when it did. */
bool wisp_tx_tick(wisp_tx *tx, uint32_t now_ms);
/* Bytes waiting to be pulled, control frames included. */
size_t wisp_tx_pending(const wisp_tx *tx);

#endif
