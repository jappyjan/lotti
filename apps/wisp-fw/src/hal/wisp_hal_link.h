/*
 * SPDX-License-Identifier: MIT
 *
 * Link HAL: a reliable, ordered byte pipe to the phone (BLE GATT or L2CAP CoC on native;
 * WebSocket in the sim). Framing, CRC, credits and resync live in the core (protocol.md
 * "Frames"); the HAL only moves bytes and reports connection state.
 *
 * Native BLE is milestone M6 and gated by safety rule 8 (no EM9305 reflash, ever).
 */
#ifndef WISP_HAL_LINK_H
#define WISP_HAL_LINK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum wisp_link_profile {
	WISP_LINK_IDLE = 0,
	WISP_LINK_INTERACTIVE = 1,
	WISP_LINK_BULK = 2,
};

struct wisp_link_cbs {
	void (*connected)(void *ctx, uint16_t mtu);
	void (*disconnected)(void *ctx);
	void (*rx)(void *ctx, const uint8_t *data, size_t len);
	void (*tx_ready)(void *ctx); /* room again after WISP_HAL_EBUSY */
};

int wisp_hal_link_start(const struct wisp_link_cbs *cbs, void *ctx);
int wisp_hal_link_send(const uint8_t *data, size_t len);
int wisp_hal_link_profile(enum wisp_link_profile p);

#endif /* WISP_HAL_LINK_H */
