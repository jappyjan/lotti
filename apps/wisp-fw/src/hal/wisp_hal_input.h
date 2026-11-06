/*
 * SPDX-License-Identifier: MIT
 *
 * Input HAL: the touchpad (PSoC 4000T on I2C5). The G2's touch controller runs Even's firmware
 * and reports gestures, press and release, but no position (docs/wisp/hardware.md "Touch and
 * wear"), so on native the raw events carry pos 0 and the gestures come from the controller
 * (wisp_hal_input_gestures). The sim may deliver real positions. The HAL never reflashes the
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

/* Gestures recognised by the touch controller; same numbering as wisp-core's WISP_GESTURE_*. */
enum wisp_gesture {
	WISP_HAL_GESTURE_TAP = 1,
	WISP_HAL_GESTURE_DOUBLE_TAP = 2,
	WISP_HAL_GESTURE_LONG_START = 3,
	WISP_HAL_GESTURE_LONG_END = 4,
	WISP_HAL_GESTURE_SWIPE_FORWARD = 5,
	WISP_HAL_GESTURE_SWIPE_BACK = 6,
};

typedef void (*wisp_gesture_cb)(uint8_t kind, uint64_t t_ms, void *ctx);

/* NULL cb stops gesture delivery. ENOTSUP where the target has no gesture source. */
int wisp_hal_input_gestures(wisp_gesture_cb cb, void *ctx);

/* True while the rescue hold (long press at boot) is seen; read by Wisp Boot. */
int wisp_hal_input_rescue_hold(bool *held);

#endif /* WISP_HAL_INPUT_H */
