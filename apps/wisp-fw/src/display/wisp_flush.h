/*
 * SPDX-License-Identifier: MIT
 *
 * Display flush path: the core composes damaged rects into strips (wisp_present_fn) and calls
 * frame_done after the last one; this module keeps the panel's frame in a shadow buffer and, at
 * frame_done, sends only the rows that changed to the panel (one partial update per contiguous
 * run of dirty rows). Portable C, no Zephyr: host-tested in tests/display/.
 *
 * Pixel format in and out: 4 bpp, high nibble = left pixel, 320 bytes per row (the core's
 * format, wisp/display.h). If the panel wants the other nibble order, the panel driver swaps;
 * this module never interprets pixels.
 */
#ifndef WISP_FLUSH_H_
#define WISP_FLUSH_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WISP_FLUSH_W      640u
#define WISP_FLUSH_H      480u
#define WISP_FLUSH_STRIDE 320u

/* Writes rows [y0, y0 + rows) of the frame (stride WISP_FLUSH_STRIDE) to the panel. Returns 0
 * or a negative errno; on error the rows stay dirty and are retried on the next flush. */
typedef int (*wisp_flush_write_fn)(void *ctx, uint16_t y0, uint16_t rows, const uint8_t *px);

struct wisp_flush {
	uint8_t *fb; /* WISP_FLUSH_STRIDE * WISP_FLUSH_H bytes, owned by the caller */
	wisp_flush_write_fn write;
	void *ctx;
	/* Coalesce dirty runs separated by at most this many clean rows into one write (one
	 * command and one DMA instead of several; costs a few rows of redundant transfer). */
	uint16_t merge_gap;
	uint8_t dirty[WISP_FLUSH_H / 8]; /* one bit per row */
	uint32_t frames, writes, rows_sent;
};

void wisp_flush_init(struct wisp_flush *f, uint8_t *fb, wisp_flush_write_fn write, void *ctx,
		     uint16_t merge_gap);

/* wisp_present_fn: copy a composed strip into the shadow frame and mark its rows dirty.
 * x and w are even (the core guarantees it); out-of-range parts are clipped. */
void wisp_flush_present(void *f, uint16_t x, uint16_t y, uint16_t w, uint16_t h,
			const uint8_t *px, size_t stride);

/* Mark every row dirty (after the panel lost its frame: power-up, recovery). */
void wisp_flush_invalidate(struct wisp_flush *f);

/* Send the dirty rows. Returns 0, or the first write error (remaining rows stay dirty). */
int wisp_flush_commit(struct wisp_flush *f);

bool wisp_flush_pending(const struct wisp_flush *f);

#endif /* WISP_FLUSH_H_ */
