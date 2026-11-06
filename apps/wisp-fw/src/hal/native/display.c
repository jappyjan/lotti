/*
 * SPDX-License-Identifier: MIT
 *
 * Native display HAL: wisp-core's composed strips -> the panel's frame buffer (wisp_flush) ->
 * dirty rows to the panel at frame end (uled_write_rows). The frame buffer is the panel
 * driver's own (uncached, DMA-able), so there is exactly one copy of the frame.
 */
#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/pm/device_runtime.h>

#include "uled.h"
#include "wisp_flush.h"
#include "wisp_hal.h"
#include "wisp_native.h"

static const struct device *const panel = DEVICE_DT_GET(DT_NODELABEL(uled));
static struct wisp_flush flush;
static bool powered;
static bool ready;
static K_MUTEX_DEFINE(lock);

/* Merge dirty runs separated by up to 4 clean rows: one command instead of several. */
#define MERGE_GAP 4

static int write_rows(void *ctx, uint16_t y0, uint16_t rows, const uint8_t *px)
{
	ARG_UNUSED(ctx);
	ARG_UNUSED(px);
	return uled_write_rows(panel, uled_frame(panel), y0, rows);
}

int wisp_native_display_init(void)
{
	if (!device_is_ready(panel)) {
		return WISP_HAL_EIO;
	}
	wisp_flush_init(&flush, uled_frame(panel), write_rows, NULL, MERGE_GAP);
	ready = true;
	return 0;
}

int wisp_hal_display_info(struct wisp_display_info *out)
{
	out->width = WISP_DISPLAY_WIDTH;
	out->height = WISP_DISPLAY_HEIGHT;
	out->bpp = 4;
	out->has_gpu = false;
	return 0;
}

int wisp_hal_display_power(bool on)
{
	int err = 0;

	if (!ready) {
		return WISP_HAL_EIO;
	}
	k_mutex_lock(&lock, K_FOREVER);
	if (on && !powered) {
		err = pm_device_runtime_get(panel);
		if (err == 0) {
			powered = true;
			/* Power-up blanked the panel; resend what the core last composed. */
			wisp_flush_invalidate(&flush);
			err = wisp_flush_commit(&flush);
		}
	} else if (!on && powered) {
		powered = false;
		err = pm_device_runtime_put(panel);
	}
	k_mutex_unlock(&lock);
	return err ? WISP_HAL_EIO : 0;
}

int wisp_hal_display_brightness(uint8_t level)
{
	if (!ready) {
		return WISP_HAL_EIO;
	}
	/* 0..255 -> stock's 1..100. */
	return uled_brightness(panel, (uint8_t)(1u + (uint32_t)level * 99u / 255u)) ? WISP_HAL_EIO : 0;
}

int wisp_hal_display_write(uint16_t y0, uint16_t rows, const uint8_t *buf, wisp_display_done_cb done,
			   void *ctx)
{
	int err = 0;

	if (!ready) {
		return WISP_HAL_EIO;
	}
	if (y0 + rows > WISP_DISPLAY_HEIGHT) {
		return WISP_HAL_EINVAL;
	}
	k_mutex_lock(&lock, K_FOREVER);
	wisp_flush_present(&flush, 0, y0, WISP_DISPLAY_WIDTH, rows, buf, WISP_DISPLAY_STRIDE);
	if (powered) {
		err = wisp_flush_commit(&flush);
	}
	k_mutex_unlock(&lock);
	if (done) {
		done(ctx);
	}
	return err ? WISP_HAL_EIO : 0;
}

void wisp_native_present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px,
			 size_t stride)
{
	ARG_UNUSED(ctx);
	if (!ready) {
		return;
	}
	k_mutex_lock(&lock, K_FOREVER);
	wisp_flush_present(&flush, x, y, w, h, px, stride);
	k_mutex_unlock(&lock);
}

void wisp_native_frame_done(void *ctx, uint32_t frame)
{
	ARG_UNUSED(ctx);
	ARG_UNUSED(frame);
	if (!ready) {
		return;
	}
	k_mutex_lock(&lock, K_FOREVER);
	/* Unpowered: the rows stay dirty and go out at the next power-up. */
	if (powered) {
		(void)wisp_flush_commit(&flush);
	}
	k_mutex_unlock(&lock);
}

const struct wisp_flush *wisp_native_flush(void)
{
	return &flush;
}
