/*
 * SPDX-License-Identifier: MIT
 *
 * The transport adapter between one GATT-style link and wisp-core's wisp_conn.
 *
 * Owns only transport concerns: notifications cut to the link's payload size, back-pressure
 * (a chunk that found no buffer is retried as is), the advertising policy (fast after boot or a
 * disconnect, slow later, off while connected) and dropping a link that carries no session.
 * Every protocol rule (frames, credits, resync, HELLO, timeouts) is wisp_conn's.
 *
 * Not thread-safe: the target calls everything from one thread (native: the Wisp link work
 * queue). No Zephyr dependency, so the host tests in tests/link/ drive it with a fake target.
 * Time is absolute microseconds from any monotonic clock.
 */
#ifndef WISP_LINK_H
#define WISP_LINK_H

#include "wisp/conn.h"
#include "wisp_hal_link.h"

#define WISP_LINK_MAX_CHUNK 244 /* ATT MTU 247 - 3 */

struct wisp_link_config {
	const wisp_session_hello_rsp_t *hello; /* what HELLO answers */
	wisp_conn_config conn;                 /* buffers for frames */
	uint32_t fast_adv_ms;                  /* fast advertising after boot / a disconnect */
	uint32_t idle_drop_ms; /* a connection without a session for this long is dropped (0 = never) */
};

struct wisp_link_stats {
	uint32_t connects, disconnects, sessions, idle_drops, notify_busy, notify_errors;
};

struct wisp_link {
	struct wisp_link_config cfg;
	const struct wisp_hal_link_ops *ops;
	void *ops_ctx;
	wisp_basic basic;
	wisp_conn conn;
	bool connected, subscribed;
	enum wisp_adv_mode adv;
	uint64_t fast_until_us;  /* fast advertising ends */
	uint64_t idle_since_us;  /* connected without a session since; WISP_CONN_NEVER while one is up */
	uint16_t chunk;          /* payload bytes per notification */
	uint8_t pending[WISP_LINK_MAX_CHUNK];
	uint16_t pending_len;    /* a chunk pulled from the conn that still has to go out */
	struct wisp_link_stats stats;
};

/* Returns 0, or a negative wisp-core code for a bad config. Starts fast advertising. */
int wisp_link_init(struct wisp_link *l, const struct wisp_link_config *cfg,
		   const struct wisp_hal_link_ops *ops, void *ops_ctx, uint64_t now_us);

/* A central connected; mtu = ATT MTU (23 until exchanged). */
void wisp_link_connected(struct wisp_link *l, uint16_t att_mtu, uint64_t now_us);
void wisp_link_mtu(struct wisp_link *l, uint16_t att_mtu, uint64_t now_us);
/* The central enabled or disabled TX notifications (CCC). */
void wisp_link_subscribed(struct wisp_link *l, bool on, uint64_t now_us);
/* Bytes written to RX. */
void wisp_link_rx(struct wisp_link *l, const uint8_t *data, size_t len, uint64_t now_us);
/* A notification queued by ops->notify has been sent. */
void wisp_link_tx_done(struct wisp_link *l, uint64_t now_us);
void wisp_link_disconnected(struct wisp_link *l, uint64_t now_us);
/* Timers. Returns the next time to call it (absolute µs) or WISP_CONN_NEVER. */
uint64_t wisp_link_tick(struct wisp_link *l, uint64_t now_us);
uint64_t wisp_link_deadline(const struct wisp_link *l, uint64_t now_us);

bool wisp_link_session_active(const struct wisp_link *l);

#endif /* WISP_LINK_H */
