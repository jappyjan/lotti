/*
 * SPDX-License-Identifier: MIT
 *
 * Host unit tests for the display flush path (src/display/wisp_flush.c). Built and run by
 * scripts/test.sh with the host compiler under ASan/UBSan; no Zephyr, no hardware.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisp_flush.h"

static int failures;

#define CHECK(cond)                                                                        \
	do {                                                                               \
		if (!(cond)) {                                                             \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                                        \
		}                                                                          \
	} while (0)

/* A fake panel: its own frame, plus a log of the writes. */
static uint8_t panel[WISP_FLUSH_STRIDE * WISP_FLUSH_H];
static struct {
	uint16_t y0, rows;
} wlog[64];
static unsigned nwrites;
static int fail_at = -1;

static int panel_write(void *ctx, uint16_t y0, uint16_t rows, const uint8_t *px)
{
	(void)ctx;
	if ((int)nwrites == fail_at) {
		fail_at = -1;
		return -5;
	}
	CHECK(y0 + rows <= WISP_FLUSH_H);
	memcpy(panel + (size_t)y0 * WISP_FLUSH_STRIDE, px, (size_t)rows * WISP_FLUSH_STRIDE);
	if (nwrites < 64) {
		wlog[nwrites].y0 = y0;
		wlog[nwrites].rows = rows;
	}
	nwrites++;
	return 0;
}

static uint8_t fb[WISP_FLUSH_STRIDE * WISP_FLUSH_H];

static void reset_log(void)
{
	nwrites = 0;
	memset(wlog, 0, sizeof(wlog));
}

int main(void)
{
	struct wisp_flush f;
	uint8_t strip[8 * 40];

	/* After init the whole frame is dirty and goes out as one write. */
	wisp_flush_init(&f, fb, panel_write, NULL, 0);
	memset(panel, 0x55, sizeof(panel));
	CHECK(wisp_flush_pending(&f));
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].y0 == 0 && wlog[0].rows == 480);
	CHECK(memcmp(panel, fb, sizeof(fb)) == 0);
	CHECK(!wisp_flush_pending(&f));

	/* Nothing dirty: nothing sent. */
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 0);

	/* A 16-pixel-wide strip at (100, 10), 8 rows: only rows 10..17 go out; bytes land at x/2. */
	for (unsigned i = 0; i < sizeof(strip); i++) {
		strip[i] = (uint8_t)(i * 7u + 1u);
	}
	wisp_flush_present(&f, 100, 10, 16, 8, strip, 40);
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].y0 == 10 && wlog[0].rows == 8);
	for (unsigned r = 0; r < 8; r++) {
		CHECK(memcmp(panel + (10u + r) * WISP_FLUSH_STRIDE + 50u, strip + r * 40u, 8) == 0);
		CHECK(panel[(10u + r) * WISP_FLUSH_STRIDE + 49u] == 0);
		CHECK(panel[(10u + r) * WISP_FLUSH_STRIDE + 58u] == 0);
	}

	/* Two separate runs: two writes without merging, one with merge_gap >= the gap. */
	wisp_flush_present(&f, 0, 0, 2, 1, strip, 40);
	wisp_flush_present(&f, 0, 4, 2, 1, strip, 40);
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 2 && wlog[0].y0 == 0 && wlog[0].rows == 1 && wlog[1].y0 == 4 &&
	      wlog[1].rows == 1);
	f.merge_gap = 3;
	wisp_flush_present(&f, 0, 0, 2, 1, strip, 40);
	wisp_flush_present(&f, 0, 4, 2, 1, strip, 40);
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].y0 == 0 && wlog[0].rows == 5);
	f.merge_gap = 0;

	/* Clipping: a strip that crosses the right and bottom edges. */
	wisp_flush_present(&f, 636, 478, 16, 8, strip, 40);
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].y0 == 478 && wlog[0].rows == 2);
	CHECK(memcmp(panel + 478u * WISP_FLUSH_STRIDE + 318u, strip, 2) == 0);

	/* A failed write keeps its rows dirty; the next commit resends them. */
	wisp_flush_present(&f, 0, 200, 640, 1, fb, 320);
	fail_at = 0;
	reset_log();
	CHECK(wisp_flush_commit(&f) == -5);
	CHECK(wisp_flush_pending(&f));
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].y0 == 200);

	/* Invalidate (panel power-up) resends everything. */
	wisp_flush_invalidate(&f);
	reset_log();
	CHECK(wisp_flush_commit(&f) == 0);
	CHECK(nwrites == 1 && wlog[0].rows == 480);
	CHECK(memcmp(panel, fb, sizeof(fb)) == 0);

	if (failures) {
		fprintf(stderr, "test_flush: %d failure(s)\n", failures);
		return 1;
	}
	printf("test_flush: all passed\n");
	return 0;
}
