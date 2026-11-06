/* Wisp core: glasses-side session state machine. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/frame.h"
#include "wisp/session.h"

void wisp_session_init(wisp_session *s, const wisp_session_hello_rsp_t *info) {
    memset(s, 0, sizeof *s);
    s->info = info;
}

/* Answers only requests that asked for it (req != 0); d NULL = an empty "ok". */
static int reply(const wisp_hdr *h, const wisp_desc *d, const void *msg, uint8_t *out, size_t cap,
                 wisp_session_result *r) {
    if (!h->req) return WISP_OK;
    wisp_hdr rh = {h->op, WISP_MF_RESPONSE, h->req};
    int n = wisp_msg_encode(out, cap, &rh, d, msg);
    if (n < 0) return n;
    r->reply_len = (size_t)n;
    return WISP_OK;
}

static int reply_error(const wisp_hdr *h, uint16_t code, uint8_t *out, size_t cap, wisp_session_result *r) {
    if (!h->req) return WISP_OK;
    int n = wisp_msg_error(out, cap, h->op, h->req, code, NULL);
    if (n < 0) return n;
    r->reply_len = (size_t)n;
    return WISP_OK;
}

int wisp_session_rx(wisp_session *s, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
                    uint8_t *reply_buf, size_t cap, wisp_session_result *r) {
    wisp_hdr h;
    r->event = WISP_SESSION_NONE;
    r->seq = 0;
    r->reply_len = 0;
    if (wisp_hdr_decode(body, len, &h) < 0) return WISP_OK; /* nothing to answer to */
    s->last_rx_us = now_us;
    const uint8_t *p = body + WISP_MSG_HDR;
    size_t plen = len - WISP_MSG_HDR;
    bool request = !(h.mflags & (WISP_MF_RESPONSE | WISP_MF_ERROR | WISP_MF_EVENT));

    union {
        wisp_session_hello_req_t hello;
        wisp_session_credit_req_t credit;
        wisp_session_resync_req_t resync;
        wisp_session_ping_req_t ping;
        wisp_session_time_sync_req_t time;
        wisp_session_time_sync_rsp_t time_rsp;
    } m;

    /* CREDIT and RESYNC (control frames) act in any state and are never answered. */
    if (svc == WISP_SVC_SESSION && request && (h.op == WISP_OP_SESSION_CREDIT || h.op == WISP_OP_SESSION_RESYNC)) {
        const wisp_desc *d = h.op == WISP_OP_SESSION_CREDIT ? &wisp_session_credit_req_desc : &wisp_session_resync_req_desc;
        if (wisp_unpack(d, p, plen, &m) < 0) return WISP_OK;
        r->event = h.op == WISP_OP_SESSION_CREDIT ? WISP_SESSION_CREDIT : WISP_SESSION_RESYNC;
        r->seq = h.op == WISP_OP_SESSION_CREDIT ? m.credit.ack_seq : m.resync.last_good_seq;
        return WISP_OK;
    }
    if (svc != WISP_SVC_SESSION) {
        if (!s->active) return request ? reply_error(&h, WISP_ERR_NOT_ALLOWED, reply_buf, cap, r) : WISP_OK;
        r->event = WISP_SESSION_DISPATCH;
        return WISP_OK;
    }
    if (!request) return WISP_OK; /* not for us */

    const wisp_desc *d = wisp_desc_find(svc, h.op, h.mflags);
    if (d && wisp_unpack(d, p, plen, &m) < 0) return reply_error(&h, WISP_ERR_BAD_PAYLOAD, reply_buf, cap, r);

    if (h.op == WISP_OP_SESSION_HELLO) {
        uint16_t ours = s->info->max_frame ? s->info->max_frame : WISP_MAX_FRAME_DEFAULT;
        uint16_t theirs = m.hello.max_frame ? m.hello.max_frame : WISP_MAX_FRAME_DEFAULT;
        s->peer = m.hello;
        s->max_frame = ours < theirs ? ours : theirs;
        s->peer_window = m.hello.rx_window ? m.hello.rx_window : WISP_RX_WINDOW_DEFAULT;
        s->active = true;
        r->event = WISP_SESSION_STARTED;
        return reply(&h, &wisp_session_hello_rsp_desc, s->info, reply_buf, cap, r);
    }
    if (!s->active) return reply_error(&h, WISP_ERR_NOT_ALLOWED, reply_buf, cap, r);

    switch (h.op) {
    case WISP_OP_SESSION_PING:
        return reply(&h, &wisp_session_ping_rsp_desc, &m.ping, reply_buf, cap, r);
    case WISP_OP_SESSION_TIME_SYNC: {
        uint64_t phone_ms = m.time.phone_ms;
        m.time_rsp.phone_ms = phone_ms;
        m.time_rsp.glass_us = now_us;
        return reply(&h, &wisp_session_time_sync_rsp_desc, &m.time_rsp, reply_buf, cap, r);
    }
    case WISP_OP_SESSION_BYE:
        s->active = false;
        r->event = WISP_SESSION_ENDED;
        return reply(&h, NULL, NULL, reply_buf, cap, r); /* ok */
    default:
        return reply_error(&h, WISP_ERR_UNSUPPORTED, reply_buf, cap, r);
    }
}

wisp_session_event wisp_session_tick(wisp_session *s, uint64_t now_us) {
    uint32_t ms = s->info->session_timeout_ms ? s->info->session_timeout_ms : WISP_SESSION_TIMEOUT_DEFAULT_MS;
    if (!s->active || now_us - s->last_rx_us < (uint64_t)ms * 1000u) return WISP_SESSION_NONE;
    s->active = false;
    return WISP_SESSION_ENDED;
}
