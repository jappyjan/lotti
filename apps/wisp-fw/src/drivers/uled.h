/*
 * SPDX-License-Identifier: MIT
 *
 * G2 microLED panel driver API (src/drivers/uled.c). Power is PM-runtime: take the device with
 * pm_device_runtime_get() to power the panel up (rails, init, blank frame), put it to power it
 * down. Writes on a suspended panel fail with -EBUSY.
 */
#ifndef WISP_ULED_H
#define WISP_ULED_H

#include <stdint.h>

#include <zephyr/device.h>

#define ULED_WIDTH   640u
#define ULED_HEIGHT  480u
#define ULED_STRIDE  320u
/* Every pixel write carries two bytes after the pixels (stock: frame DMA length 153 602, row
 * writes span + 2). A full-frame buffer must therefore be ULED_FRAME_BYTES long, with the last
 * two bytes 0. */
#define ULED_FRAME_BYTES (ULED_STRIDE * ULED_HEIGHT + 2u)

enum uled_panel {
	ULED_JBD4010 = 0,
	ULED_A6NG = 1,
};

enum uled_panel uled_panel(const struct device *dev);

/* The panel frame buffer (ULED_FRAME_BYTES, uncached, owned by the driver). The HAL composes
 * into it and passes it back to uled_write_rows(). */
uint8_t *uled_frame(const struct device *dev);

/* Rows [y0, y0 + rows) of a 4 bpp frame (stride ULED_STRIDE, high nibble = left pixel, as the
 * core). Whole-frame writes (y0 = 0, rows = 480) go out as one DMA and need the frame to be
 * ULED_FRAME_BYTES long; anything else is written row by row (the A6N-G has no partial update in
 * stock, so on that panel a partial write sends the whole frame from `frame`). `frame` is the
 * start of the full frame buffer; rows are taken from it. */
int uled_write_rows(const struct device *dev, const uint8_t *frame, uint16_t y0, uint16_t rows);

/* Brightness 1..100 (stock's level domain). */
int uled_brightness(const struct device *dev, uint8_t level);

/* Stock's health check (JBD status registers, A6N-G ASIC/panel registers). 0 = healthy. */
int uled_check(const struct device *dev);

#endif /* WISP_ULED_H */
