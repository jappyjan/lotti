/*
 * SPDX-License-Identifier: MIT
 *
 * native-1's boot screen (rung4.md W25). Composed with wisp-core (layers, fills, text with the
 * built-in "Wisp" font), presented through the native display HAL (wisp_native_present /
 * frame_done -> wisp_flush -> the panel's frame buffer), then the panel is powered: its power-up
 * sends the whole frame. The pattern:
 *
 *   a 4-pixel frame at the canvas edge (value 15), so a cut-off or offset image shows;
 *   "Wisp" (value 15) centred at y 180..260;
 *   16 grey bands of 40 px across y 380..440, values 0..15 left to right.
 *
 * Before any rail is switched, both rail gates are read (npm1300_switch.c): if the PMIC is not as
 * stock configured it, nothing is written and the state is REFUSED. The panel powers down after
 * CONFIG_WISP_BOOT_SCREEN_S (stock keeps it off while nothing is shown).
 */
#include "boot_screen.h"

#include <errno.h>

#include <zephyr/device.h>
#include <zephyr/kernel.h>

#include <wisp/display.h>
#include <wisp/resource.h>
#include <wisp/text.h>

#include "app_status.h"
#include "boot_font.h"
#include "npm1300_switch.h"
#include "wisp_case_proto.h"
#include "wisp_hal.h"
#include "wisp_native.h"

#define W 640
#define H 480
#define LAYERS 8
#define STRIP 16

#define TEXT_W (4 * WISP_BOOT_FONT_ADVANCE)
#define TEXT_H WISP_BOOT_FONT_LINE_H

/* Content buffers: the frame's four edges, the text, the bands; plus the strip and temporaries. */
#define GFX_BYTES                                                                                  \
	(2 * (W / 2) * 4 + 2 * 2 * H + (TEXT_W / 2) * TEXT_H + (W / 2) * 60 + 4096u)

static uint8_t gfx[GFX_BYTES] __aligned(8);
static uint8_t tables[12 * 1024] __aligned(8);
static struct k_work_delayable off_work;

BUILD_ASSERT(DT_NODE_HAS_COMPAT(DT_PHANDLE(DT_NODELABEL(uled), vdd_supply), wisp_npm1300_switch) &&
		     DT_NODE_HAS_COMPAT(DT_PHANDLE(DT_NODELABEL(uled), vio_supply), wisp_npm1300_switch),
	     "the boot screen powers the panel only through the gated rail switches");

static void off_fn(struct k_work *w)
{
	ARG_UNUSED(w);
	int err = wisp_hal_display_power(false);

	wisp_app_status.display = err ? WISP_CASE_DISPLAY_FAILED : WISP_CASE_DISPLAY_OFF;
	wisp_app_status.display_err = (int8_t)(err ? -EIO : 0);
}

static int layer(wisp_display *d, uint8_t id, int16_t x, int16_t y, uint16_t w, uint16_t h)
{
	wisp_display_layer_set_req_t m = {
		.layer = id, .z = id, .flags = WISP_LAYER_VISIBLE, .alpha = 15,
		.x = x, .y = y, .w = w, .h = h,
	};

	return wisp_display_layer_set(d, &m);
}

static int compose(void)
{
	static wisp_pool pool;
	static wisp_display d;
	wisp_display_text_rsp_t txt;
	wisp_font font;
	int err;

	if (wisp_display_mem(W, H, LAYERS, STRIP) > sizeof(tables)) {
		return -ENOMEM;
	}
	wisp_pool_init(&pool, gfx, sizeof(gfx));
	wisp_display_init(&d, tables, W, H, LAYERS, STRIP, &pool, wisp_native_present, NULL);

	err = layer(&d, 0, 0, 0, W, 4);
	err = err ? err : layer(&d, 1, 0, H - 4, W, 4);
	err = err ? err : layer(&d, 2, 0, 0, 4, H);
	err = err ? err : layer(&d, 3, W - 4, 0, 4, H);
	for (uint8_t i = 0; i < 4 && !err; i++) {
		err = wisp_display_fill(&d, i, 15, 0, 0, W, H);
	}
	err = err ? err : layer(&d, 4, (W - TEXT_W) / 2, 180, TEXT_W, TEXT_H);
	if (!err && !wisp_font_open(wisp_boot_font, sizeof(wisp_boot_font), &font)) {
		err = -EINVAL;
	}
	err = err ? err
		  : wisp_text_draw(&d, 4, &font, 15, 0, 0, 0, 0, (const uint8_t *)"Wisp", 4, &txt);
	if (!err && txt.chars_drawn != 4) {
		err = -EIO;
	}
	err = err ? err : layer(&d, 5, 0, 380, W, 60);
	for (int b = 0; b < 16 && !err; b++) {
		err = wisp_display_fill(&d, 5, (uint8_t)b, b * 40, 0, 40, 60);
	}
	if (err) {
		return err > 0 ? -EINVAL : err;
	}
	wisp_native_frame_done(NULL, wisp_display_commit(&d));
	return 0;
}

uint8_t wisp_boot_screen_show(int *err)
{
	const struct device *const rails[] = {
		DEVICE_DT_GET(DT_PHANDLE(DT_NODELABEL(uled), vio_supply)),
		DEVICE_DT_GET(DT_PHANDLE(DT_NODELABEL(uled), vdd_supply)),
	};

	*err = 0;
	for (size_t i = 0; i < ARRAY_SIZE(rails); i++) {
		*err = device_is_ready(rails[i]) ? wisp_npm1300_switch_check(rails[i]) : -ENODEV;
		if (*err) {
			return *err == -EACCES ? WISP_CASE_DISPLAY_REFUSED : WISP_CASE_DISPLAY_FAILED;
		}
	}
	/* Power first: the JBD4010's init (stock's sequence) sends a blank frame from the panel's own
	 * frame buffer, which is also the one the flush composes into, so a screen composed before
	 * the power-up would be wiped. Composed after it, the commit sends the rows at once. */
	if (wisp_hal_display_power(true)) {
		*err = -EIO;
		return WISP_CASE_DISPLAY_FAILED;
	}
	*err = compose();
	if (*err) {
		return WISP_CASE_DISPLAY_FAILED;
	}
	k_work_init_delayable(&off_work, off_fn);
	k_work_schedule(&off_work, K_SECONDS(CONFIG_WISP_BOOT_SCREEN_S));
	return WISP_CASE_DISPLAY_ON;
}
