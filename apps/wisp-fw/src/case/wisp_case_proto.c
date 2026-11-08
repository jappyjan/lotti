/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp case-UART protocol codec (docs/wisp/case-uart.md). See wisp_case_proto.h.
 */
#include "wisp_case_proto.h"

#include <string.h>

static const uint8_t stock_version_query[5] = {0x24, 0x00, 0x01, 0x00, 0xA7};
static const uint8_t marker[3] = {WISP_CASE_ID0, WISP_CASE_ID1, WISP_CASE_ID2};
static const uint8_t reply_lengths[] = {8, 16, 24, 27};

static void put16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static void put32(uint8_t *p, uint32_t v)
{
	put16(p, (uint16_t)v);
	put16(p + 2, (uint16_t)(v >> 16));
}

static uint8_t sum8(const uint8_t *p, size_t n)
{
	uint32_t s = 0;

	while (n--) {
		s += *p++;
	}
	return (uint8_t)s;
}

size_t wisp_case_frame(uint8_t *out, const uint8_t *payload, size_t len)
{
	if (len + 5 > WISP_CASE_MAX_FRAME) {
		return 0;
	}
	out[0] = 0x5A;
	out[1] = 0xA5;
	out[2] = 0xFF;
	out[3] = (uint8_t)len;
	memcpy(out + 4, payload, len);
	out[4 + len] = sum8(out, 4 + len);
	return len + 5;
}

size_t wisp_case_version_frame(uint8_t *out, const struct wisp_case_version *ver)
{
	/* Stock's layout (wisp_case/bridge.py decode_version): 24, three identity bytes, the
	 * four version bytes, the hardware revision. 14 bytes: step 0's bridge takes it, the
	 * relay does not (the IDENT op is its counterpart there). */
	const uint8_t p[9] = {0x24,       WISP_CASE_ID0, WISP_CASE_ID1, WISP_CASE_ID2, ver->major,
			      ver->minor, ver->patch,    ver->image_kind, ver->hw};

	return wisp_case_frame(out, p, sizeof(p));
}

void wisp_case_status_encode(uint8_t out[WISP_CASE_STATUS_SIZE], const struct wisp_case_status *s)
{
	memset(out, 0, WISP_CASE_STATUS_SIZE);
	out[0] = WISP_CASE_STATUS_VERSION;
	out[1] = s->stage;
	put16(out + 2, (uint16_t)s->bt_result);
	out[4] = s->sensors;
	out[5] = s->flags;
	put16(out + 6, s->battery_mv);
	out[8] = s->charger_status;
	out[9] = s->vbus_status;
	out[10] = s->image_kind;
	out[11] = (uint8_t)s->pmic_last;
	put32(out + 12, s->reset_cause);
	put32(out + 16, s->uptime_ms);
	put32(out + 20, s->pmic_kicks);
	put32(out + 24, s->pmic_errors);
	put32(out + 28, s->apollo_feeds);
	put32(out + 32, s->sessions);
	put16(out + 36, s->confirm_calls);
	put16(out + 38, (uint16_t)s->confirm_result);
	put16(out + 40, s->boot_block_size);
	memcpy(out + 44, s->rev, sizeof(s->rev));
}

void wisp_case_rx_init(struct wisp_case_rx *rx)
{
	rx->len = 0;
}

/* A reply: WSP, op | 0x80, status, data; zero-padded to the shortest length the relay passes. */
static size_t reply(uint8_t *out, uint8_t op, uint8_t status, const uint8_t *data, size_t n)
{
	uint8_t p[27] = {WISP_CASE_ID0, WISP_CASE_ID1, WISP_CASE_ID2, (uint8_t)(op | 0x80u), status};
	size_t len = 0;

	if (n > sizeof(p) - 5) {
		return 0;
	}
	if (n) {
		memcpy(p + 5, data, n);
	}
	for (size_t i = 0; i < sizeof(reply_lengths); i++) {
		if (reply_lengths[i] >= 5 + n) {
			len = reply_lengths[i];
			break;
		}
	}
	return wisp_case_frame(out, p, len);
}

/* req = the whole checked request, n = its length (9, 25 or 32). */
static size_t handle(const uint8_t *req, size_t n, const struct wisp_case_version *ver,
		     const struct wisp_case_ops *ops, uint8_t *out, bool *reset)
{
	uint8_t op = req[7];
	const uint8_t *args = req + 8;
	size_t nargs = n - 9;
	uint8_t d[WISP_CASE_READ_MAX + 5];
	struct wisp_case_status st = {0};

	switch (op) {
	case WISP_CASE_OP_IDENT:
		if (nargs != 0) {
			return reply(out, op, WISP_CASE_E_ARGS, NULL, 0);
		}
		ops->status(ops->ctx, &st);
		d[0] = ver->major;
		d[1] = ver->minor;
		d[2] = ver->patch;
		d[3] = ver->image_kind;
		d[4] = st.stage;
		d[5] = st.flags;
		put16(d + 6, st.battery_mv);
		put16(d + 8, (uint16_t)st.bt_result);
		return reply(out, op, WISP_CASE_OK, d, 10);
	case WISP_CASE_OP_READ: {
		uint8_t status_block[WISP_CASE_STATUS_SIZE];
		const uint8_t *blk = NULL;
		size_t total = 0;
		uint16_t off;
		uint8_t want;

		if (nargs != 16) {
			return reply(out, op, WISP_CASE_E_ARGS, NULL, 0);
		}
		off = (uint16_t)(args[1] | args[2] << 8);
		want = args[3];
		if (args[0] == WISP_CASE_BLOCK_STATUS) {
			ops->status(ops->ctx, &st);
			wisp_case_status_encode(status_block, &st);
			blk = status_block;
			total = sizeof(status_block);
		} else if (args[0] == WISP_CASE_BLOCK_BOOT) {
			blk = ops->boot_block(ops->ctx, off, &total);
			if (!blk || total == 0) {
				return reply(out, op, WISP_CASE_E_NOTAVAIL, NULL, 0);
			}
		} else {
			return reply(out, op, WISP_CASE_E_ARGS, NULL, 0);
		}
		if (want == 0 || want > WISP_CASE_READ_MAX || off >= total) {
			return reply(out, op, WISP_CASE_E_ARGS, NULL, 0);
		}
		if (want > total - off) {
			want = (uint8_t)(total - off);
		}
		d[0] = args[0];
		put16(d + 1, off);
		put16(d + 3, (uint16_t)total);
		memcpy(d + 5, blk + off, want);
		return reply(out, op, WISP_CASE_OK, d, 5u + want);
	}
	case WISP_CASE_OP_RESET:
		if (nargs != 16 || memcmp(args, WISP_CASE_RESET_MAGIC, 4) != 0) {
			return reply(out, op, WISP_CASE_E_ARGS, NULL, 0);
		}
		*reset = true;
		return reply(out, op, WISP_CASE_OK, NULL, 0);
	default:
		return reply(out, op, WISP_CASE_E_UNKNOWN, NULL, 0);
	}
}

size_t wisp_case_rx_byte(struct wisp_case_rx *rx, uint8_t b, const struct wisp_case_version *ver,
			 const struct wisp_case_ops *ops, uint8_t *out, bool *reset)
{
	*reset = false;
	for (;;) {
		if (rx->len == 0) {
			if (b != 0x7E && b != stock_version_query[0]) {
				return 0; /* not the start of anything we answer */
			}
			rx->buf[rx->len++] = b;
			return 0;
		}
		if (rx->buf[0] == stock_version_query[0]) {
			if (b != stock_version_query[rx->len]) {
				rx->len = 0;
				continue; /* this byte may start a new request */
			}
			rx->buf[rx->len++] = b;
			if (rx->len < sizeof(stock_version_query)) {
				return 0;
			}
			rx->len = 0;
			return wisp_case_version_frame(out, ver);
		}
		/* 7E 00 01 n, n = 4 / 20 / 27; then 'W' 'S' 'P' */
		if ((rx->len == 1 && b != 0x00) || (rx->len == 2 && b != 0x01) ||
		    (rx->len == 3 && b != 4 && b != 20 && b != 27) ||
		    (rx->len >= 4 && rx->len <= 6 && b != marker[rx->len - 4])) {
			rx->len = 0;
			continue;
		}
		rx->buf[rx->len++] = b;
		if (rx->len < 4 || rx->len < (size_t)rx->buf[3] + 5u) {
			return 0;
		}
		size_t n = rx->len;

		rx->len = 0;
		if (rx->buf[n - 1] != (uint8_t)(n + 0x7Du + sum8(rx->buf, n - 1))) {
			return 0; /* corrupt: ignored */
		}
		return handle(rx->buf, n, ver, ops, out, reset);
	}
}
