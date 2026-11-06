/*
 * SPDX-License-Identifier: MIT
 *
 * Display HAL. The panel is 640×480, 4 bpp grey (two pixels per byte, high nibble first),
 * 320 bytes per line. The core composites layers into a frame buffer it owns and hands
 * finished lines to the HAL; the HAL never interprets pixels (protocol service 0x02).
 */
#ifndef WISP_HAL_DISPLAY_H
#define WISP_HAL_DISPLAY_H

#include <stdbool.h>
#include <stdint.h>

#define WISP_DISPLAY_WIDTH  640u
#define WISP_DISPLAY_HEIGHT 480u
#define WISP_DISPLAY_STRIDE 320u /* bytes per line at 4 bpp */

struct wisp_display_info {
	uint16_t width;
	uint16_t height;
	uint8_t bpp;
	bool has_gpu; /* NemaGFX available for blits/fills */
};

int wisp_hal_display_info(struct wisp_display_info *out);

/* Panel power. Off by default; the core turns it off when unworn. */
int wisp_hal_display_power(bool on);

/* 0..255; the HAL maps it to the panel's drive range. */
int wisp_hal_display_brightness(uint8_t level);

/*
 * Push lines [y0, y0 + rows) of a 4 bpp buffer (stride WISP_DISPLAY_STRIDE). Tear-free:
 * the HAL latches the lines at the next panel refresh. `done` runs when the buffer may be
 * reused.
 */
typedef void (*wisp_display_done_cb)(void *ctx);
int wisp_hal_display_write(uint16_t y0, uint16_t rows, const uint8_t *buf,
			   wisp_display_done_cb done, void *ctx);

#endif /* WISP_HAL_DISPLAY_H */
