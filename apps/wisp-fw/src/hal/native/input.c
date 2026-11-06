/*
 * SPDX-License-Identifier: MIT
 *
 * Native input HAL on the G2 touch controller (src/drivers/g2_touch.c): press/release as raw
 * events (no position on this hardware), gesture flags as gestures, proximity as wear (sensors.c
 * subscribes through wisp_native_wear_cb).
 */
#include <zephyr/device.h>
#include <zephyr/kernel.h>

#include "g2_touch.h"
#include "wisp_hal.h"
#include "wisp_native.h"

static const struct device *const touch = DEVICE_DT_GET(DT_NODELABEL(touch));

static wisp_touch_cb raw_cb;
static void *raw_ctx;
static wisp_gesture_cb gesture_cb;
static void *gesture_ctx;
static bool long_down;

void wisp_native_wear(uint8_t g2_wear, uint64_t t_ms); /* sensors.c */

static void raw(uint8_t phase, uint64_t t)
{
	struct wisp_touch_event ev = {.t_ms = t, .pos = 0, .phase = phase, .pressure = 0};

	if (raw_cb) {
		raw_cb(&ev, raw_ctx);
	}
}

static void gesture(uint8_t kind, uint64_t t)
{
	if (gesture_cb) {
		gesture_cb(kind, t, gesture_ctx);
	}
}

static void on_report(const struct device *dev, const struct g2_touch_event *ev, void *ctx)
{
	uint64_t t = (uint64_t)k_uptime_get();

	ARG_UNUSED(dev);
	ARG_UNUSED(ctx);
	if (ev->wear != G2_WEAR_NO_CHANGE) {
		wisp_native_wear(ev->wear, t);
	}
	if (ev->flags & G2_TOUCH_PRESS) {
		raw(WISP_TOUCH_DOWN, t);
	}
	if (ev->flags & G2_TOUCH_LONG) {
		long_down = true;
		gesture(WISP_HAL_GESTURE_LONG_START, t);
	}
	/* Stock: a single tap is a tap count < 2; 2..9 are ignored, >= 10 is a separate event. */
	if ((ev->flags & G2_TOUCH_TAP) && ev->count < 2) {
		gesture(WISP_HAL_GESTURE_TAP, t);
	}
	if (ev->flags & G2_TOUCH_DOUBLE) {
		gesture(WISP_HAL_GESTURE_DOUBLE_TAP, t);
	}
	if (ev->flags & G2_TOUCH_SLIDE_FWD) {
		gesture(WISP_HAL_GESTURE_SWIPE_FORWARD, t);
	}
	if (ev->flags & G2_TOUCH_SLIDE_BACK) {
		gesture(WISP_HAL_GESTURE_SWIPE_BACK, t);
	}
	if (ev->flags & G2_TOUCH_RELEASE) {
		if (long_down) {
			long_down = false;
			gesture(WISP_HAL_GESTURE_LONG_END, t);
		}
		raw(WISP_TOUCH_UP, t);
	}
}

int wisp_native_input_init(void)
{
	if (!device_is_ready(touch)) {
		return WISP_HAL_EIO;
	}
	/* Reports always flow (wear detection needs them); callbacks decide what is delivered. */
	return g2_touch_set_callback(touch, on_report, NULL) ? WISP_HAL_EIO : 0;
}

int wisp_hal_input_enable(wisp_touch_cb cb, void *ctx)
{
	raw_ctx = ctx;
	raw_cb = cb;
	return 0;
}

int wisp_hal_input_gestures(wisp_gesture_cb cb, void *ctx)
{
	gesture_ctx = ctx;
	gesture_cb = cb;
	return 0;
}

int wisp_hal_input_rescue_hold(bool *held)
{
	/* The PSoC reports a long press as an event, not as a level; Wisp Boot's rescue hold needs
	 * its own read of the controller and is not wired yet. */
	*held = false;
	return WISP_HAL_ENOTSUP;
}
