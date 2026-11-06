/* Wisp core: glasses-side session state machine. MIT License, Wisp contributors.
 *
 * Gates everything on HELLO, answers PING and TIME_SYNC, and ends the
 * session after session_timeout_ms without a frame. Feed it every received
 * message body, control frames included; it answers session messages itself
 * and tells the caller which others to dispatch. Every request with req != 0
 * gets exactly one response (an empty payload is ok), req = 0 gets none:
 * the caller keeps that rule for what it dispatches. CREDIT and RESYNC are
 * reported in any state and never answered. */
#ifndef WISP_SESSION_H
#define WISP_SESSION_H

#include "msgs.h"

#define WISP_SESSION_TIMEOUT_DEFAULT_MS 10000u

typedef enum {
    WISP_SESSION_NONE,
    WISP_SESSION_STARTED, /* HELLO accepted (also ends any previous session): reset per-session state */
    WISP_SESSION_ENDED,   /* BYE or timeout: stop everything the session started */
    WISP_SESSION_CREDIT,  /* seq = ack_seq, for wisp_tx_ack (or use wisp_tx_control on the frame) */
    WISP_SESSION_RESYNC,  /* seq = last_good_seq, for wisp_tx_resync */
    WISP_SESSION_DISPATCH /* not a session message and the session is up: the caller handles (and answers) it */
} wisp_session_event;

typedef struct {
    wisp_session_event event;
    uint16_t seq;
    size_t reply_len; /* > 0: send reply[0, reply_len) as a body on the same svc */
} wisp_session_result;

typedef struct {
    const wisp_session_hello_rsp_t *info; /* what HELLO answers; owned by the caller */
    bool active;
    uint64_t last_rx_us;
    wisp_session_hello_req_t peer;
    uint16_t max_frame;  /* negotiated: min of both sides */
    uint32_t peer_window;
} wisp_session;

void wisp_session_init(wisp_session *s, const wisp_session_hello_rsp_t *info);
/* One received message body. Returns WISP_OK, or WISP_E_SPACE if reply is too small. */
int wisp_session_rx(wisp_session *s, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
                    uint8_t *reply, size_t cap, wisp_session_result *r);
/* Call periodically; returns WISP_SESSION_ENDED once when the session times out. */
wisp_session_event wisp_session_tick(wisp_session *s, uint64_t now_us);

#endif
