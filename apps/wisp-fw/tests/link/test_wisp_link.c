/*
 * SPDX-License-Identifier: MIT
 *
 * Host unit tests for the transport adapter (src/link/wisp_link.c) with a fake GATT target
 * and a phone built from wisp-core's own frame sender and receiver. Built and run by
 * scripts/test.sh with the host compiler under ASan/UBSan; no Zephyr, no hardware.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisp_hal.h"
#include "wisp_link.h"

static int failures;

#define CHECK(cond)                                                                        \
	do {                                                                               \
		if (!(cond)) {                                                             \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                                        \
		}                                                                          \
	} while (0)

#define MS 1000ull
#define S  1000000ull

/* ---- fake target ---- */

struct fake {
	enum wisp_adv_mode adv;
	unsigned adv_calls, disconnects;
	int busy;          /* the next n notifies find no buffer */
	int fail;          /* the next n notifies fail outright */
	uint8_t air[65536]; /* notified bytes, in order */
	size_t air_len;
	size_t max_chunk;
	unsigned notifies;
};

static int fake_notify(void *ctx, const uint8_t *data, size_t len)
{
	struct fake *f = ctx;

	if (f->busy > 0) {
		f->busy--;
		return WISP_HAL_EBUSY;
	}
	if (f->fail > 0) {
		f->fail--;
		return WISP_HAL_EIO;
	}
	CHECK(f->air_len + len <= sizeof(f->air));
	memcpy(f->air + f->air_len, data, len);
	f->air_len += len;
	f->max_chunk = len > f->max_chunk ? len : f->max_chunk;
	f->notifies++;
	return 0;
}

static void fake_disconnect(void *ctx)
{
	((struct fake *)ctx)->disconnects++;
}

static void fake_advertise(void *ctx, enum wisp_adv_mode mode)
{
	struct fake *f = ctx;

	f->adv = mode;
	f->adv_calls++;
}

static const struct wisp_hal_link_ops ops = {fake_notify, fake_disconnect, fake_advertise};

/* ---- the native configuration's numbers, at host scale ---- */

static const wisp_session_hello_rsp_t hello = {
	.proto_major = 0, .proto_minor = 2, .max_frame = 4096, .rx_window = 16384,
	.fw_name = "wisp-native", .fw_version = "test", .lens = 1, .canvas_w = 640,
	.canvas_h = 480, .bpp = 4, .session_timeout_ms = 10000,
};

struct glasses {
	struct wisp_link l;
	struct fake f;
	uint8_t rxbuf[4096 + WISP_FRAME_OVERHEAD];
	uint8_t ring[8192];
	uint8_t queue[4096];
};

static void glasses_init(struct glasses *g, uint64_t now)
{
	memset(&g->f, 0, sizeof(g->f));
	struct wisp_link_config cfg = {
		.hello = &hello,
		.conn = {g->rxbuf, sizeof(g->rxbuf), g->ring, sizeof(g->ring), g->queue,
			 sizeof(g->queue), 16384, 1, 0},
		.fast_adv_ms = 30000,
		.idle_drop_ms = 10000,
	};
	CHECK(wisp_link_init(&g->l, &cfg, &ops, &g->f, now) == 0);
}

/* ---- phone ---- */

struct phone {
	wisp_rx rx;
	wisp_tx tx;
	uint8_t rxbuf[4096 + WISP_FRAME_OVERHEAD];
	uint8_t ring[16384];
	size_t air_read;
	unsigned responses, errors;
	uint16_t last_req, last_err;
	wisp_session_hello_rsp_t hello;
};

static void phone_init(struct phone *p)
{
	memset(p, 0, sizeof(*p));
	wisp_rx_init(&p->rx, p->rxbuf, sizeof(p->rxbuf));
	wisp_tx_init(&p->tx, p->ring, sizeof(p->ring));
}

static void phone_request(struct phone *p, uint8_t svc, uint8_t op, uint16_t req, const void *pl,
			  size_t plen)
{
	uint8_t body[256];
	wisp_hdr h = {op, 0, req};

	wisp_hdr_encode(body, &h);
	memcpy(body + WISP_MSG_HDR, pl, plen);
	CHECK(wisp_tx_send(&p->tx, svc, 0, body, WISP_MSG_HDR + plen) >= 0);
}

static void phone_hello(struct phone *p, uint16_t req)
{
	wisp_session_hello_req_t m = {.proto_major = 0, .proto_minor = 2,
				      .app_id = "com.example.test", .client_name = "host"};
	uint8_t pl[64];
	int n = wisp_pack(&wisp_session_hello_req_desc, &m, pl, sizeof(pl));

	phone_request(p, WISP_SVC_SESSION, WISP_OP_SESSION_HELLO, req, pl, (size_t)n);
}

/* Writes everything the phone has, in chunks of `mtu` bytes, then reads the notifications. */
static void exchange(struct phone *p, struct glasses *g, size_t mtu, uint64_t now)
{
	uint8_t buf[512];

	for (int guard = 0; guard < 1000; guard++) {
		size_t n = wisp_tx_pull(&p->tx, buf, mtu);

		if (!n) {
			break;
		}
		wisp_link_rx(&g->l, buf, n, now);
	}
	size_t len = g->f.air_len - p->air_read;
	const uint8_t *data = g->f.air + p->air_read;
	wisp_rx_event ev;
	wisp_frame fr;
	bool consumed = false;

	p->air_read = g->f.air_len;
	do {
		size_t n = wisp_rx_feed(&p->rx, data, len, &ev, &fr);

		data += n;
		len -= n;
		if (ev == WISP_RX_CONTROL) {
			wisp_tx_control(&p->tx, &fr);
		}
		if (ev == WISP_RX_RESYNC) {
			wisp_tx_queue_resync(&p->tx, p->rx.last_good_seq);
		}
		if (ev == WISP_RX_DUPLICATE) {
			wisp_tx_queue_credit(&p->tx, p->rx.last_good_seq);
		}
		if (ev == WISP_RX_FRAME) {
			wisp_hdr h;

			consumed = true;
			CHECK(wisp_hdr_decode(fr.body, fr.len, &h) == WISP_MSG_HDR);
			p->last_req = h.req;
			if (h.mflags & WISP_MF_ERROR) {
				p->errors++;
				p->last_err = wisp_get16(fr.body + WISP_MSG_HDR);
			} else if (h.mflags & WISP_MF_RESPONSE) {
				p->responses++;
				if (fr.svc == WISP_SVC_SESSION && h.op == WISP_OP_SESSION_HELLO) {
					CHECK(wisp_unpack(&wisp_session_hello_rsp_desc,
							  fr.body + WISP_MSG_HDR,
							  fr.len - WISP_MSG_HDR, &p->hello) == WISP_OK);
				}
			}
		}
	} while (ev != WISP_RX_NONE);
	if (consumed) {
		wisp_tx_queue_credit(&p->tx, p->rx.last_good_seq);
	}
}

static void test_advertising(void)
{
	static struct glasses g;

	glasses_init(&g, 0);
	CHECK(g.f.adv == WISP_ADV_FAST && g.f.adv_calls == 1);
	CHECK(wisp_link_deadline(&g.l, 0) == 30 * S);
	CHECK(wisp_link_tick(&g.l, 29 * S) == 30 * S && g.f.adv == WISP_ADV_FAST);
	CHECK(wisp_link_tick(&g.l, 30 * S) == WISP_CONN_NEVER && g.f.adv == WISP_ADV_SLOW);

	/* connected: advertising off; disconnected: fast again, then slow */
	wisp_link_connected(&g.l, 23, 40 * S);
	CHECK(g.f.adv == WISP_ADV_OFF);
	wisp_link_disconnected(&g.l, 41 * S);
	CHECK(g.f.adv == WISP_ADV_FAST && wisp_link_deadline(&g.l, 41 * S) == 71 * S);
	wisp_link_tick(&g.l, 71 * S);
	CHECK(g.f.adv == WISP_ADV_SLOW);
	CHECK(g.f.adv_calls == 5);
}

static void test_hello_over_gatt(void)
{
	static struct glasses g;
	static struct phone p;

	glasses_init(&g, 0);
	phone_init(&p);
	wisp_link_connected(&g.l, 23, 1 * S);
	CHECK(!wisp_link_session_active(&g.l));
	CHECK(wisp_link_deadline(&g.l, 1 * S) == 11 * S); /* idle drop */

	/* HELLO before the phone subscribed: the answer waits, nothing is lost. */
	phone_hello(&p, 1);
	exchange(&p, &g, 20, 1 * S);
	CHECK(wisp_link_session_active(&g.l) && g.f.notifies == 0);
	wisp_link_subscribed(&g.l, true, 1 * S);
	exchange(&p, &g, 20, 1 * S);
	CHECK(p.responses == 1 && p.last_req == 1 && !strcmp(p.hello.fw_name, "wisp-native"));
	CHECK(g.f.max_chunk == 20); /* ATT MTU 23 */
	CHECK(g.l.stats.sessions == 1);

	/* MTU 247: chunks up to 244 bytes; a session keeps the link (no idle drop). Unsubscribed
	 * meanwhile, so four 200-byte bodies pile up and then go out in full chunks. */
	wisp_link_mtu(&g.l, 247, 2 * S);
	wisp_link_subscribed(&g.l, false, 2 * S);
	uint8_t body[200] = {0};

	for (uint16_t i = 0; i < 4; i++) {
		wisp_hdr h = {9, WISP_MF_RESPONSE, (uint16_t)(10 + i)};

		wisp_hdr_encode(body, &h);
		CHECK(wisp_conn_send(&g.l.conn, 0x80, body, sizeof(body)) == WISP_OK);
	}
	unsigned before = g.f.notifies;

	wisp_link_subscribed(&g.l, true, 2 * S);
	exchange(&p, &g, 244, 2 * S);
	CHECK(p.responses == 5 && p.last_req == 13);
	CHECK(g.f.max_chunk == 244 && g.f.notifies - before == 4); /* 4 x 210 B = 840 B */
	CHECK(wisp_link_deadline(&g.l, 2 * S) > 2 * S);
	CHECK(wisp_link_deadline(&g.l, 2 * S) <= 12 * S); /* session timeout, not idle drop */

	/* A request for a service this build doesn't have yet: error 1. */
	phone_request(&p, 2, 8, 20, "\0", 1);
	exchange(&p, &g, 244, 2 * S);
	CHECK(p.errors == 1 && p.last_req == 20 && p.last_err == WISP_ERR_UNSUPPORTED);
	CHECK(g.f.disconnects == 0);
}

static void test_backpressure(void)
{
	static struct glasses g;
	static struct phone p;

	glasses_init(&g, 0);
	phone_init(&p);
	wisp_link_connected(&g.l, 23, 0);
	wisp_link_subscribed(&g.l, true, 0);
	g.f.busy = 3; /* the stack's buffers are full for a while */
	phone_hello(&p, 1);
	exchange(&p, &g, 20, 0);
	CHECK(p.responses == 0 && g.l.pending_len > 0);
	for (int i = 0; i < 3; i++) {
		wisp_link_tx_done(&g.l, 0);
	}
	exchange(&p, &g, 20, 0);
	CHECK(p.responses == 1 && g.l.stats.notify_busy == 3);

	/* A notification that fails outright is lost; the ack timeout brings the frame back. */
	g.f.fail = 1;
	phone_request(&p, WISP_SVC_SESSION, WISP_OP_SESSION_PING, 2, "pong", 4);
	exchange(&p, &g, 20, 1 * S);
	CHECK(g.l.stats.notify_errors == 1);
	uint64_t t = 1 * S;

	for (int i = 0; i < 10 && p.responses < 2; i++) {
		t = wisp_link_tick(&g.l, t);
		exchange(&p, &g, 20, t);
	}
	CHECK(p.responses == 2 && p.last_req == 2);
	CHECK(t <= 3 * S);
}

static void test_idle_drop(void)
{
	static struct glasses g;
	static struct phone p;

	/* No HELLO within idle_drop_ms: the link is dropped. */
	glasses_init(&g, 0);
	wisp_link_connected(&g.l, 247, 5 * S);
	CHECK(wisp_link_tick(&g.l, 14 * S) == 15 * S && g.f.disconnects == 0);
	wisp_link_tick(&g.l, 15 * S);
	CHECK(g.f.disconnects == 1 && g.l.stats.idle_drops == 1);
	CHECK(wisp_link_deadline(&g.l, 15 * S) == 25 * S); /* asks again if the link stays */
	wisp_link_disconnected(&g.l, 15 * S + 50 * MS);
	CHECK(g.f.adv == WISP_ADV_FAST);

	/* After BYE the link may stay idle_drop_ms, then goes; a new HELLO in time keeps it. */
	phone_init(&p);
	wisp_link_connected(&g.l, 247, 20 * S);
	wisp_link_subscribed(&g.l, true, 20 * S);
	phone_hello(&p, 1);
	exchange(&p, &g, 244, 20 * S);
	phone_request(&p, WISP_SVC_SESSION, WISP_OP_SESSION_BYE, 2, "", 0);
	exchange(&p, &g, 244, 21 * S);
	CHECK(!wisp_link_session_active(&g.l) && p.responses == 2);
	CHECK(wisp_link_deadline(&g.l, 21 * S) <= 31 * S);
	phone_hello(&p, 3);
	exchange(&p, &g, 244, 25 * S);
	CHECK(wisp_link_session_active(&g.l) && g.l.stats.sessions == 2);

	/* Session timeout (the phone went quiet), then the idle drop. */
	uint64_t t = 25 * S, ended = 0;

	while (wisp_link_session_active(&g.l) && t < 60 * S) {
		ended = t;
		t = wisp_link_tick(&g.l, t);
	}
	CHECK(ended == 35 * S);
	while (g.f.disconnects == 1 && t < 60 * S) {
		/* the ack timeout keeps resending the unacknowledged BYE answer meanwhile */
		t = wisp_link_tick(&g.l, t);
	}
	CHECK(t >= 45 * S && t <= 46 * S);
	CHECK(g.f.disconnects == 2);
}

static void test_reconnect(void)
{
	static struct glasses g;
	static struct phone p;

	glasses_init(&g, 0);
	phone_init(&p);
	wisp_link_connected(&g.l, 247, 0);
	wisp_link_subscribed(&g.l, true, 0);
	phone_hello(&p, 1);
	exchange(&p, &g, 244, 0);
	CHECK(wisp_link_session_active(&g.l));

	/* The link drops mid-session: the session ends with it, advertising resumes. */
	wisp_link_disconnected(&g.l, 1 * S);
	CHECK(!wisp_link_session_active(&g.l) && g.f.adv == WISP_ADV_FAST);
	wisp_link_rx(&g.l, (const uint8_t *)"stale", 5, 1 * S); /* ignored */

	/* A new connection starts from seq 0. */
	phone_init(&p);
	p.air_read = g.f.air_len;
	wisp_link_connected(&g.l, 185, 2 * S);
	wisp_link_subscribed(&g.l, true, 2 * S);
	phone_hello(&p, 7);
	exchange(&p, &g, 182, 2 * S);
	CHECK(p.responses == 1 && p.last_req == 7 && wisp_link_session_active(&g.l));
	CHECK(g.l.stats.connects == 2 && g.l.stats.disconnects == 1);
}

int main(void)
{
	test_advertising();
	test_hello_over_gatt();
	test_backpressure();
	test_idle_drop();
	test_reconnect();
	if (failures) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("wisp_link: all tests passed\n");
	return 0;
}
