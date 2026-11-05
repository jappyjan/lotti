/*
 * SPDX-License-Identifier: MIT
 *
 * Input HAL: the touchpad (PSoC 4000T on I2C5). Raw contacts only; gestures are the core's
 * business so apps can define their own (protocol service 0x04). The HAL never reflashes the
 * touch controller (safety rule 8).
 */
#ifndef WISP_HAL_INPUT_H
#define WISP_HAL_INPUT_H

#include <stdbool.h>
#include <stdint.h>

enum wisp_touch_phase {
	WISP_TOUCH_DOWN = 0,
	WISP_TOUCH_MOVE = 1,
	WISP_TOUCH_UP = 2,
};

struct wisp_touch_event {
	uint64_t t_ms;
	uint16_t pos;   /* along the temple, 0..65535 */
	uint8_t phase;  /* enum wisp_touch_phase */
	uint8_t pressure;
};

typedef void (*wisp_touch_cb)(const struct wisp_touch_event *ev, void *ctx);

/* NULL cb disables the touchpad. */
int wisp_hal_input_enable(wisp_touch_cb cb, void *ctx);

/* True while the rescue hold (long press at boot) is seen; read by Wisp Boot. */
int wisp_hal_input_rescue_hold(bool *held);

#endif /* WISP_HAL_INPUT_H */
