/*
 * SPDX-License-Identifier: MIT
 *
 * Host unit tests for the case-UART protocol codec (src/case/wisp_case_proto.c), built and run
 * by scripts/test.sh under ASan/UBSan. The request and reply bytes are the golden vectors that
 * tests/case/test_case_uart.py also checks against the host side (tests/boot/case_uart.py), so
 * both ends of docs/wisp/case-uart.md agree byte for byte.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisp_case_proto.h"

static int failures;

#define CHECK(cond)                                                                        \
	do {                                                                               \
		if (!(cond)) {                                                             \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                                        \
		}                                                                          \
	} while (0)

static const struct wisp_case_version ver = {.major = 0, .minor = 1, .patch = 2, .image_kind = 0, .hw = 0};
static uint8_t block[612];
static size_t block_len = sizeof(block);

static void status(void *ctx, struct wisp_case_status *s)
{
	(void)ctx;
	s->stage = 5;
	s->bt_result = -5;
	s->sensors = 0x13;
	s->flags = 0x3B;
	s->battery_mv = 3987;
	s->image_kind = 0;
	s->pmic_last = 0;
	s->uptime_ms = 0x01020304;
	s->pmic_kicks = 7;
	s->confirm_result = 0x7FFF;
	s->boot_block_size = 612;
	memcpy(s->rev, "abcdef0123", 10);
}

static const uint8_t *boot_block(void *ctx, size_t offset, size_t *len)
{
	(void)ctx;
	(void)offset;
	*len = block_len;
	return block_len ? block : NULL;
}

/* The boot report of docs/wisp/case-uart.md's example: Wisp Boot, flags prev-valid | kick-ok |
 * stimer-xt, boot 3, previous stage 0x18 (hand-off) 9,100 ms in, reset cause WDRSTAT. */
static int report(void *ctx, uint8_t *out)
{
	static const uint8_t r[WISP_CASE_BOOT_REPORT_SIZE] = {0x00, 0x0D, 0x03, 0x18, 0x40, 0, 0, 0,
							      0x8C, 0x23};

	(void)ctx;
	memcpy(out, r, sizeof(r));
	return 0;
}

static uint8_t clock_block[48];

static const uint8_t *extra(void *ctx, uint8_t blk, size_t offset, size_t *len)
{
	(void)ctx;
	(void)offset;
	*len = blk == WISP_CASE_BLOCK_CLOCK ? sizeof(clock_block) : 0;
	return *len ? clock_block : NULL;
}

static const struct wisp_case_ops ops = {.status = status, .boot_block = boot_block};
static const struct wisp_case_ops ops_s0 = {
	.status = status, .boot_block = boot_block, .boot_report = report, .extra_block = extra};
static const struct wisp_case_ops ops_boot = {.boot_report = report}; /* Wisp Boot's window */
static const struct wisp_case_ops *cur = &ops;

/* Feed bytes; return the last reply's length (copied to out) and whether a reset was asked. */
static size_t feed(struct wisp_case_rx *rx, const char *hex, uint8_t *out, bool *reset)
{
	size_t got = 0;
	uint8_t reply[WISP_CASE_MAX_FRAME];

	*reset = false;
	for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
		unsigned int b;
		bool r = false;
		size_t n;

		sscanf(hex + i, "%2x", &b);
		n = wisp_case_rx_byte(rx, (uint8_t)b, &ver, cur, reply, &r);
		if (n) {
			memcpy(out, reply, n);
			got = n;
		}
		*reset |= r;
	}
	return got;
}

static int hex_eq(const uint8_t *b, size_t n, const char *hex)
{
	char s[2 * WISP_CASE_MAX_FRAME + 1];

	for (size_t i = 0; i < n; i++) {
		sprintf(s + 2 * i, "%02x", b[i]);
	}
	s[2 * n] = 0;
	if (strcmp(s, hex) != 0) {
		fprintf(stderr, "  got  %s\n  want %s\n", s, hex);
		return 0;
	}
	return 1;
}

int main(void)
{
	struct wisp_case_rx rx;
	uint8_t out[WISP_CASE_MAX_FRAME];
	bool reset;
	size_t n;

	for (size_t i = 0; i < sizeof(block); i++) {
		block[i] = (uint8_t)(i * 7);
	}
	wisp_case_rx_init(&rx);

	/* Stock's version query -> the stock-layout frame with "WSP" (step 0's bridge). */
	n = feed(&rx, "24000100a7", out, &reset);
	CHECK(n == 14 && hex_eq(out, n, "5aa5ff0924575350000102000028") && !reset);

	/* IDENT: a 9-byte request, a 21-byte reply (both shapes the relay passes). */
	n = feed(&rx, "7e0001045753500104", out, &reset);
	CHECK(n == 21 && hex_eq(out, n, "5aa5ff10575350810000010200053b930ffbff0068"));

	/* Ignored: garbage, the case app's 0x13 poll, a loader CONT, a bad checksum, another
	 * marker, a length the relay never forwards. */
	CHECK(feed(&rx, "13000001e4017d", out, &reset) == 0);
	CHECK(feed(&rx, "7e000104434f4e5434", out, &reset) == 0);
	CHECK(feed(&rx, "7e0001045753500105", out, &reset) == 0);
	CHECK(feed(&rx, "7e000105575350010000", out, &reset) == 0);
	/* ...and the parser recovers right after, also inside a broken request. */
	n = feed(&rx, "7e007e0001045753500104", out, &reset);
	CHECK(n == 21);

	/* READ of the app status: 17 bytes at a time, a 32-byte reply. */
	n = feed(&rx, "7e000114575350020100001100000000000000000000000037", out, &reset);
	CHECK(n == 32 && out[7] == 0x82 && out[8] == WISP_CASE_OK && out[9] == 1);
	CHECK(out[10] == 0 && out[11] == 0 && out[12] == WISP_CASE_STATUS_SIZE && out[13] == 0);
	CHECK(out[14] == WISP_CASE_STATUS_VERSION && out[15] == 5 && out[19] == 0x3B);
	CHECK(out[20] == (3987 & 0xFF) && out[21] == (3987 >> 8));

	/* READ of Wisp Boot's block at 595: the last 17 bytes. */
	n = feed(&rx, "7e00011457535002025302110000000000000000000000008d", out, &reset);
	CHECK(n == 32 && out[8] == WISP_CASE_OK && out[9] == 2 && out[10] == 0x53 && out[11] == 0x02);
	CHECK(out[12] == (612 & 0xFF) && out[13] == (612 >> 8) && memcmp(out + 14, block + 595, 17) == 0);
	block_len = 0;
	n = feed(&rx, "7e00011457535002025302110000000000000000000000008d", out, &reset);
	CHECK(n == 13 && out[8] == WISP_CASE_E_NOTAVAIL);
	block_len = sizeof(block);

	/* RESET: the right magic asks for a reset. */
	n = feed(&rx, "7e000114575350035253455400000000000000000000000064", out, &reset);
	CHECK(n == 13 && hex_eq(out, n, "5aa5ff08575350830000000083") && reset);

	/* An unknown op gets status 1. */
	n = feed(&rx, "7e000104575350090c", out, &reset);
	CHECK(n == 13 && out[7] == 0x89 && out[8] == WISP_CASE_E_UNKNOWN && !reset);

	/* BOOTREP (rung4.md W24 analysis, D2): an app without it (native-0) says unknown op... */
	n = feed(&rx, "7e0001045753500407", out, &reset);
	CHECK(n == 13 && out[7] == 0x84 && out[8] == WISP_CASE_E_UNKNOWN);
	/* ...stage-0 answers it, 32 bytes... */
	cur = &ops_s0;
	n = feed(&rx, "7e0001045753500407", out, &reset);
	CHECK(n == 32 && hex_eq(out, n, "5aa5ff1b5753508400000d0318400000008c23000000000000000000000000ae"));
	/* ...and its clock block (READ block 3); block 4 is not served by this callback: status 2. */
	n = feed(&rx, "7e000114575350020300001100000000000000000000000039", out, &reset);
	CHECK(n == 32 && out[8] == WISP_CASE_OK && out[9] == 3 && out[12] == 48);
	n = feed(&rx, "7e00011457535002043300110000000000000000000000006d", out, &reset);
	CHECK(n == 13 && out[8] == WISP_CASE_E_ARGS);
	/* Wisp Boot's window: only BOOTREP; IDENT, READ, RESET and stock's query get nothing. */
	cur = &ops_boot;
	n = feed(&rx, "7e0001045753500407", out, &reset);
	CHECK(n == 32 && hex_eq(out, n, "5aa5ff1b5753508400000d0318400000008c23000000000000000000000000ae"));
	CHECK(feed(&rx, "7e0001045753500104", out, &reset) == 0);
	CHECK(feed(&rx, "24000100a7", out, &reset) == 0);
	CHECK(feed(&rx, "7e000114575350035253455400000000000000000000000064", out, &reset) == 0 && !reset);
	CHECK(feed(&rx, "7e000114575350020100001100000000000000000000000037", out, &reset) == 0);
	cur = &ops;

	if (failures) {
		fprintf(stderr, "test_case_proto: %d failure(s)\n", failures);
		return 1;
	}
	printf("test_case_proto: OK\n");
	return 0;
}
