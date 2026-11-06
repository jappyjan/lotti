/*
 * SPDX-License-Identifier: MIT
 *
 * Link HAL: what a link target provides to src/link/wisp_link.c (the transport adapter that
 * drives wisp-core's wisp_conn). Native: Zephyr GATT, src/ble/wisp_ble.c. Host tests: a fake.
 *
 * The target only moves bytes and reports connection state. Framing, CRC, credits, resync
 * and the session live in wisp-core (protocol.md "Frames"); which advertising mode to use and
 * when to drop an idle link is decided by the adapter, so it is the same everywhere.
 */
#ifndef WISP_HAL_LINK_H
#define WISP_HAL_LINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum wisp_adv_mode {
	WISP_ADV_OFF = 0,
	WISP_ADV_FAST = 1, /* right after boot or a disconnect: found quickly */
	WISP_ADV_SLOW = 2, /* after that: cheap */
};

enum wisp_link_profile {
	WISP_LINK_IDLE = 0,
	WISP_LINK_INTERACTIVE = 1,
	WISP_LINK_BULK = 2,
};

struct wisp_hal_link_ops {
	/*
	 * One notification of at most the link's payload size (ATT MTU - 3). Returns 0 once it is
	 * queued (tx_done() follows when the stack has sent it), WISP_HAL_EBUSY when no buffer is
	 * free (the adapter retries the same bytes after the next tx_done()), or another negative
	 * code (the bytes are dropped; the protocol's ack timeout resends them).
	 */
	int (*notify)(void *ctx, const uint8_t *data, size_t len);
	/* Drop the current connection (it was idle without a session for too long). */
	void (*disconnect)(void *ctx);
	/* Start, switch or stop connectable advertising of the Wisp service. */
	void (*advertise)(void *ctx, enum wisp_adv_mode mode);
};

#endif /* WISP_HAL_LINK_H */
