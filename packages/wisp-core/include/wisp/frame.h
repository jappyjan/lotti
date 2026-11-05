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

typedef struct {
    uint8_t svc, route, fflags;
    uint16_t seq;
    uint16_t len;
    const uint8_t *body;
} wisp_frame;

/* Writes one frame; returns its size (len + 10) or WISP_E_SPACE / WISP_E_TOO_BIG. */
int wisp_frame_encode(uint8_t *out, size_t cap, uint8_t svc, uint8_t route, uint16_t seq,
                      const uint8_t *body, size_t len);

/* ---- receiver ----
 *
 * Feed it the link's bytes in any chunking. It delivers frames in seq order
 * (seq starts at 0 per connection), drops duplicates silently, and asks for a
 * RESYNC {last_good_seq} when it had to discard bytes or saw a seq gap.
 *
 *   do {
 *       size_t n = wisp_rx_feed(&rx, p, len, &ev, &f);
 *       p += n; len -= n;
 *       if (ev == WISP_RX_FRAME) handle(&f);              // f.body valid until the next feed
 *       if (ev == WISP_RX_RESYNC) send_resync(rx.last_good_seq);
 *   } while (ev != WISP_RX_NONE);
 */
typedef enum { WISP_RX_NONE, WISP_RX_FRAME, WISP_RX_RESYNC } wisp_rx_event;

typedef struct {
    uint8_t *buf;           /* holds one frame: max body + 10 bytes */
    size_t cap;
    size_t fill;
    uint16_t max_body;
    uint16_t last_good_seq; /* 0xFFFF before the first frame */
    bool recovering;        /* RESYNC asked, waiting for last_good_seq + 1 */
    bool bad_run;           /* inside a run of discarded bytes */
    bool delivered;         /* buf holds the frame returned last time */
    uint32_t frames, bad_bytes, dups, gaps;
} wisp_rx;

void wisp_rx_init(wisp_rx *rx, uint8_t *buf, size_t cap);
/* Returns how many input bytes it consumed; WISP_RX_NONE means all of them. */
size_t wisp_rx_feed(wisp_rx *rx, const uint8_t *data, size_t len, wisp_rx_event *ev, wisp_frame *frame);

/* ---- sender ----
 *
 * Frames are encoded into a caller-provided ring and kept there until
 * CREDIT acknowledges them, so RESYNC can resend them. The ring never holds
 * more than the peer's rx_window, which is the protocol's credit rule.
 * The link pulls bytes in whatever chunks it can carry. */
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
    uint32_t resends;
} wisp_tx;

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
/* Ack timeout: resend every held frame. */
void wisp_tx_resend_all(wisp_tx *tx);
/* Bytes waiting to be pulled. */
size_t wisp_tx_pending(const wisp_tx *tx);

#endif
