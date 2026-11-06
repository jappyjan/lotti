/*
 * SPDX-License-Identifier: MIT
 *
 * The transport adapter between one GATT-style link and wisp-core's wisp_conn (wisp_link.h).
 */
#include <string.h>

#include "wisp_hal.h"
#include "wisp_link.h"

#define ATT_MTU_MIN 23u

static void set_adv(struct wisp_link *l, enum wisp_adv_mode mode)
{
	if (l->adv == mode) {
		return;
	}
	l->adv = mode;
	l->ops->advertise(l->ops_ctx, mode);
}

static void start_advertising(struct wisp_link *l, uint64_t now_us)
{
	l->fast_until_us = now_us + (uint64_t)l->cfg.fast_adv_ms * 1000u;
	set_adv(l, l->cfg.fast_adv_ms ? WISP_ADV_FAST : WISP_ADV_SLOW);
}

static uint16_t chunk_for(uint16_t att_mtu)
{
	uint16_t mtu = att_mtu < ATT_MTU_MIN ? ATT_MTU_MIN : att_mtu;
	uint16_t chunk = (uint16_t)(mtu - 3u);

	return chunk > WISP_LINK_MAX_CHUNK ? WISP_LINK_MAX_CHUNK : chunk;
}

int wisp_link_init(struct wisp_link *l, const struct wisp_link_config *cfg,
		   const struct wisp_hal_link_ops *ops, void *ops_ctx, uint64_t now_us)
{
	if (!cfg->hello || !ops || !ops->notify || !ops->disconnect || !ops->advertise) {
		return WISP_E_ARG;
	}
	memset(l, 0, sizeof(*l));
	l->cfg = *cfg;
	l->ops = ops;
	l->ops_ctx = ops_ctx;
	wisp_basic_init(&l->basic, cfg->hello);
	wisp_conn_handler h = wisp_basic_handler(&l->basic);
	int r = wisp_conn_init(&l->conn, &cfg->conn, &h);

	if (r < 0) {
		return r;
	}
	l->idle_since_us = WISP_CONN_NEVER;
	l->chunk = chunk_for(ATT_MTU_MIN);
	l->adv = WISP_ADV_OFF;
	start_advertising(l, now_us);
	return 0;
}

bool wisp_link_session_active(const struct wisp_link *l)
{
	return l->connected && wisp_conn_session_active(&l->conn);
}

/* Session up: the link stays. No session: it may stay idle_drop_ms. */
static void track_session(struct wisp_link *l, uint64_t now_us)
{
	uint32_t ev = wisp_conn_events(&l->conn);

	if (ev & WISP_CONN_STARTED) {
		l->stats.sessions++;
	}
	if (wisp_link_session_active(l)) {
		l->idle_since_us = WISP_CONN_NEVER;
	} else if (l->connected && l->idle_since_us == WISP_CONN_NEVER) {
		l->idle_since_us = now_us;
	}
}

static void flush(struct wisp_link *l, uint64_t now_us)
{
	if (!l->connected || !l->subscribed) {
		return;
	}
	for (;;) {
		if (!l->pending_len) {
			size_t n = wisp_conn_pull(&l->conn, l->pending, l->chunk, now_us);

			if (!n) {
				return;
			}
			l->pending_len = (uint16_t)n;
		}
		int r = l->ops->notify(l->ops_ctx, l->pending, l->pending_len);

		if (r == WISP_HAL_EBUSY) {
			l->stats.notify_busy++;
			return; /* same bytes again after the next tx_done */
		}
		if (r < 0) {
			l->stats.notify_errors++; /* lost: the ack timeout resends the frames */
		}
		l->pending_len = 0;
	}
}

void wisp_link_connected(struct wisp_link *l, uint16_t att_mtu, uint64_t now_us)
{
	l->connected = true;
	l->subscribed = false;
	l->pending_len = 0;
	l->chunk = chunk_for(att_mtu);
	l->idle_since_us = now_us;
	l->stats.connects++;
	wisp_conn_open(&l->conn, now_us);
	set_adv(l, WISP_ADV_OFF);
}

void wisp_link_mtu(struct wisp_link *l, uint16_t att_mtu, uint64_t now_us)
{
	uint16_t chunk = chunk_for(att_mtu);

	/* The ATT MTU only grows on a connection; a pending chunk is never larger than the new one. */
	if (chunk >= l->pending_len) {
		l->chunk = chunk;
	}
	flush(l, now_us);
}

void wisp_link_subscribed(struct wisp_link *l, bool on, uint64_t now_us)
{
	l->subscribed = on && l->connected;
	flush(l, now_us);
}

void wisp_link_rx(struct wisp_link *l, const uint8_t *data, size_t len, uint64_t now_us)
{
	if (!l->connected) {
		return;
	}
	wisp_conn_feed(&l->conn, data, len, now_us);
	track_session(l, now_us);
	flush(l, now_us);
}

void wisp_link_tx_done(struct wisp_link *l, uint64_t now_us)
{
	flush(l, now_us);
}

void wisp_link_disconnected(struct wisp_link *l, uint64_t now_us)
{
	if (!l->connected) {
		return;
	}
	l->connected = false;
	l->subscribed = false;
	l->pending_len = 0;
	l->idle_since_us = WISP_CONN_NEVER;
	l->stats.disconnects++;
	wisp_conn_close(&l->conn, now_us); /* a running session ends here, as on BYE */
	(void)wisp_conn_events(&l->conn);
	start_advertising(l, now_us);
}

uint64_t wisp_link_deadline(const struct wisp_link *l, uint64_t now_us)
{
	uint64_t d = WISP_CONN_NEVER;

	if (l->connected) {
		d = wisp_conn_deadline(&l->conn, now_us);
		if (l->cfg.idle_drop_ms && l->idle_since_us != WISP_CONN_NEVER) {
			uint64_t drop = l->idle_since_us + (uint64_t)l->cfg.idle_drop_ms * 1000u;

			d = drop < d ? drop : d;
		}
	} else if (l->adv == WISP_ADV_FAST) {
		d = l->fast_until_us;
	}
	return d < now_us ? now_us : d;
}

uint64_t wisp_link_tick(struct wisp_link *l, uint64_t now_us)
{
	if (l->connected) {
		wisp_conn_tick(&l->conn, now_us);
		track_session(l, now_us);
		flush(l, now_us);
		if (l->cfg.idle_drop_ms && l->idle_since_us != WISP_CONN_NEVER &&
		    now_us >= l->idle_since_us + (uint64_t)l->cfg.idle_drop_ms * 1000u) {
			l->stats.idle_drops++;
			l->idle_since_us = now_us; /* disconnected() follows; if not, ask again later */
			l->ops->disconnect(l->ops_ctx);
		}
	} else if (l->adv == WISP_ADV_FAST && now_us >= l->fast_until_us) {
		set_adv(l, WISP_ADV_SLOW);
	}
	return wisp_link_deadline(l, now_us);
}
