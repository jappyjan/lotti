/* Wisp core: one link connection on the glasses side. MIT License, Wisp contributors.
 *
 * Ties the frame receiver and sender to whatever runs above them (the session
 * alone, see wisp_basic below, or the engine) for one byte-stream connection:
 * a GATT link, an L2CAP channel, a socket. The transport only moves bytes and
 * time; everything the protocol says about frames lives here:
 *
 *   - frames in (any chunking), CREDIT for every duplicate, RESYNC after
 *     discarded bytes or a seq gap, control frames applied in any state;
 *   - coalesced CREDITs: right away when 25 % of our rx_window is consumed or
 *     when outgoing bytes are waiting anyway (it rides along for free), else
 *     20 ms after the first unacknowledged frame;
 *   - bodies that don't fit the peer's window wait in a queue, in order;
 *   - the peer's limits after HELLO, the ack timeout, the session timeout;
 *   - one deadline for the transport's timer (no polling while idle).
 *
 *   wisp_conn_open(&c, now);                         // link connected
 *   wisp_conn_feed(&c, data, len, now);              // bytes from the phone
 *   n = wisp_conn_pull(&c, buf, mtu, now);           // bytes for the phone, while n > 0
 *   next = wisp_conn_tick(&c, now);                  // at the deadline: absolute µs
 *   ev = wisp_conn_events(&c);                       // WISP_CONN_STARTED / _ENDED
 *   wisp_conn_close(&c, now);                        // link gone: ends the session
 */
#ifndef WISP_CONN_H
#define WISP_CONN_H

#include "frame.h"
#include "session.h"

#define WISP_CONN_CREDIT_DELAY_US 20000u /* protocol.md: coalesce at most 20 ms */
#define WISP_CONN_NEVER UINT64_MAX

typedef struct wisp_conn wisp_conn;

/* What runs above the frames. rx gets every received body, control frames
 * included, and fills r like wisp_session_rx / wisp_engine_rx; replies and
 * events go out through wisp_conn_send. */
typedef struct {
    void *ctx;
    void (*rx)(void *ctx, wisp_conn *c, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
               wisp_session_result *r);
    /* Periodic work; returns true once when the session timed out. */
    bool (*tick)(void *ctx, wisp_conn *c, uint64_t now_us);
    /* When tick next has something to do (absolute µs), or WISP_CONN_NEVER. */
    uint64_t (*deadline)(void *ctx, uint64_t now_us);
    /* The session state (negotiated max_frame and peer window, active). */
    const wisp_session *(*session)(void *ctx);
} wisp_conn_handler;

typedef struct {
    uint8_t *rx_buf; /* one frame: our max_frame + WISP_FRAME_OVERHEAD */
    size_t rx_cap;
    uint8_t *ring;   /* sent frames until acknowledged (≤ the peer's rx_window is used) */
    size_t ring_cap;
    uint8_t *queue;  /* bodies waiting for window space, 4 bytes overhead each */
    size_t queue_cap;
    uint32_t rx_window; /* what HELLO announces (0 = WISP_RX_WINDOW_DEFAULT): paces CREDITs */
    uint8_t lens;       /* 1 left, 2 right: source lens in our frames' route byte; 0 = unset */
    uint32_t ack_timeout_ms; /* 0 = WISP_ACK_TIMEOUT_DEFAULT_MS */
} wisp_conn_config;

enum {
    WISP_CONN_STARTED = 1u << 0, /* HELLO accepted */
    WISP_CONN_ENDED = 1u << 1,   /* BYE, session timeout, or the link closed with a session up */
};

typedef struct {
    uint32_t rx_bytes, tx_bytes, frames, resyncs_sent, dups, dropped;
} wisp_conn_stats;

struct wisp_conn {
    wisp_conn_config cfg;
    wisp_conn_handler h;
    wisp_rx rx;
    wisp_tx tx;
    bool open;
    uint32_t consumed;      /* frame bytes delivered since our last CREDIT */
    uint64_t credit_due_us; /* when the coalesced CREDIT must go out; WISP_CONN_NEVER if none */
    size_t qlen;
    uint32_t events;
    wisp_conn_stats stats;
};

/* Returns WISP_OK, or WISP_E_ARG for missing buffers or callbacks. */
int wisp_conn_init(wisp_conn *c, const wisp_conn_config *cfg, const wisp_conn_handler *h);
/* A new link connection: sequence numbers and windows start over. */
void wisp_conn_open(wisp_conn *c, uint64_t now_us);
/* The link went away: a running session ends as on BYE (everything it started stops). */
void wisp_conn_close(wisp_conn *c, uint64_t now_us);
/* Bytes from the link, any chunking. */
void wisp_conn_feed(wisp_conn *c, const uint8_t *data, size_t len, uint64_t now_us);
/* An outgoing message body (for the handler: responses and events). Returns WISP_OK, or
 * WISP_E_SPACE when the queue is full (the peer stopped reading) / WISP_E_TOO_BIG. */
int wisp_conn_send(wisp_conn *c, uint8_t svc, const uint8_t *body, size_t len);
/* Up to cap bytes for the link; 0 = nothing to send now. */
size_t wisp_conn_pull(wisp_conn *c, uint8_t *out, size_t cap, uint64_t now_us);
/* Bytes ready for wisp_conn_pull (the queue counts once the window lets it out). */
size_t wisp_conn_pending(const wisp_conn *c);
/* Timers (CREDIT, ack timeout, session timeout). Returns the next deadline, absolute µs, or
 * WISP_CONN_NEVER. Calling it early is harmless. */
uint64_t wisp_conn_tick(wisp_conn *c, uint64_t now_us);
/* The next deadline without doing anything. */
uint64_t wisp_conn_deadline(const wisp_conn *c, uint64_t now_us);
/* WISP_CONN_* events since the last call. */
uint32_t wisp_conn_events(wisp_conn *c);
bool wisp_conn_session_active(const wisp_conn *c);

/* ---- the session alone ----
 *
 * A handler for a target without the engine yet: HELLO, PING, TIME_SYNC, BYE
 * and the timeout; every other request (req != 0) gets error 1 (unsupported). */
typedef struct {
    wisp_session session;
    uint8_t reply[128];
} wisp_basic;

void wisp_basic_init(wisp_basic *b, const wisp_session_hello_rsp_t *info);
wisp_conn_handler wisp_basic_handler(wisp_basic *b);

#endif
