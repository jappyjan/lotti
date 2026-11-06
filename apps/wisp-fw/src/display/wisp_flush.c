/*
 * SPDX-License-Identifier: MIT
 *
 * Display flush path, see wisp_flush.h.
 */
#include "wisp_flush.h"

#include <string.h>

static void mark(struct wisp_flush *f, unsigned y)
{
	f->dirty[y >> 3] |= (uint8_t)(1u << (y & 7u));
}

static bool is_dirty(const struct wisp_flush *f, unsigned y)
{
	return (f->dirty[y >> 3] >> (y & 7u)) & 1u;
}

void wisp_flush_init(struct wisp_flush *f, uint8_t *fb, wisp_flush_write_fn write, void *ctx,
		     uint16_t merge_gap)
{
	memset(f, 0, sizeof(*f));
	f->fb = fb;
	f->write = write;
	f->ctx = ctx;
	f->merge_gap = merge_gap;
	memset(fb, 0, (size_t)WISP_FLUSH_STRIDE * WISP_FLUSH_H);
	wisp_flush_invalidate(f);
}

void wisp_flush_present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h,
			const uint8_t *px, size_t stride)
{
	struct wisp_flush *f = ctx;
	unsigned x0 = x & ~1u, x1 = (unsigned)x + w;

	if (x0 >= WISP_FLUSH_W || y >= WISP_FLUSH_H || w == 0 || h == 0) {
		return;
	}
	if (x1 > WISP_FLUSH_W) {
		x1 = WISP_FLUSH_W;
	}
	size_t bytes = (x1 - x0 + 1u) / 2u;
	unsigned rows = (unsigned)y + h > WISP_FLUSH_H ? WISP_FLUSH_H - y : h;

	for (unsigned r = 0; r < rows; r++) {
		memcpy(f->fb + (size_t)(y + r) * WISP_FLUSH_STRIDE + x0 / 2u, px + r * stride, bytes);
		mark(f, y + r);
	}
}

void wisp_flush_invalidate(struct wisp_flush *f)
{
	memset(f->dirty, 0xff, sizeof(f->dirty));
}

bool wisp_flush_pending(const struct wisp_flush *f)
{
	for (size_t i = 0; i < sizeof(f->dirty); i++) {
		if (f->dirty[i]) {
			return true;
		}
	}
	return false;
}

int wisp_flush_commit(struct wisp_flush *f)
{
	unsigned y = 0;

	f->frames++;
	while (y < WISP_FLUSH_H) {
		if (!is_dirty(f, y)) {
			y++;
			continue;
		}
		/* A run of dirty rows, extended across gaps of at most merge_gap clean rows. */
		unsigned end = y + 1, last = y;
		while (end < WISP_FLUSH_H && end - last <= f->merge_gap + 1u) {
			if (is_dirty(f, end)) {
				last = end;
			}
			end++;
		}
		unsigned rows = last + 1 - y;
		int err = f->write(f->ctx, (uint16_t)y, (uint16_t)rows,
				   f->fb + (size_t)y * WISP_FLUSH_STRIDE);
		if (err) {
			return err;
		}
		for (unsigned r = y; r <= last; r++) {
			f->dirty[r >> 3] &= (uint8_t)~(1u << (r & 7u));
		}
		f->writes++;
		f->rows_sent += rows;
		y = last + 1;
	}
	return 0;
}
