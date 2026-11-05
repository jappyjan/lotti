/*
 * SPDX-License-Identifier: MIT
 *
 * Host unit tests for the Wisp Boot decision (src/boot/wisp_boot.c). Built and run by
 * scripts/test.sh with the host compiler; no Zephyr.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisp_boot.h"

static int failures;

#define CHECK(cond)                                                                        \
	do {                                                                               \
		if (!(cond)) {                                                             \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                                        \
		}                                                                          \
	} while (0)

static const struct wisp_boot_inputs normal = {.rescue_image_ok = true};

static void test_crc32_known_vector(void)
{
	/* zlib crc32("123456789") */
	CHECK(wisp_boot_crc32("123456789", 9) == 0xCBF43926u);
	CHECK(wisp_boot_crc32("", 0) == 0);
}

static void test_record_layout(void)
{
	CHECK(sizeof(struct wisp_boot_record) == 12);
}

static void test_fresh_record_runs_app(void)
{
	struct wisp_boot_decision d = wisp_boot_decide(NULL, &normal);

	CHECK(d.action == WISP_BOOT_RUN_APP);
	CHECK(d.reason == WISP_BOOT_REASON_FRESH_RECORD);
	CHECK(d.record.attempts == 1);
	CHECK(wisp_boot_record_valid(&d.record));
}

static void test_corrupt_record_is_fresh(void)
{
	struct wisp_boot_record r;

	wisp_boot_record_init(&r);
	r.attempts = 3;
	/* not resealed: CRC mismatch */
	struct wisp_boot_decision d = wisp_boot_decide(&r, &normal);

	CHECK(d.reason == WISP_BOOT_REASON_FRESH_RECORD);
	CHECK(d.action == WISP_BOOT_RUN_APP);
	CHECK(d.record.attempts == 1);
}

static void test_three_unconfirmed_boots_fall_back(void)
{
	struct wisp_boot_record r;

	wisp_boot_record_init(&r);
	for (unsigned i = 1; i <= WISP_BOOT_MAX_ATTEMPTS; i++) {
		struct wisp_boot_decision d = wisp_boot_decide(&r, &normal);

		CHECK(d.action == WISP_BOOT_RUN_APP);
		CHECK(d.record.attempts == i);
		r = d.record;
	}

	struct wisp_boot_decision d = wisp_boot_decide(&r, &normal);

	CHECK(d.action == WISP_BOOT_FALLBACK_TO_STOCK);
	CHECK(d.reason == WISP_BOOT_REASON_UNCONFIRMED);
	CHECK(d.record.fallbacks == 1);
	CHECK(d.record.attempts == 0);
	CHECK(wisp_boot_record_valid(&d.record));
}

static void test_confirm_resets(void)
{
	struct wisp_boot_record r;

	wisp_boot_record_init(&r);
	for (unsigned i = 0; i < 10; i++) {
		struct wisp_boot_decision d = wisp_boot_decide(&r, &normal);

		CHECK(d.action == WISP_BOOT_RUN_APP);
		r = d.record;
		wisp_boot_confirm(&r);
		CHECK(r.attempts == 0 && r.fallbacks == 0);
		CHECK(wisp_boot_record_valid(&r));
	}
}

static void test_rescue_hold_falls_back_at_once(void)
{
	struct wisp_boot_record r;
	struct wisp_boot_inputs in = {.rescue_hold = true, .rescue_image_ok = true};

	wisp_boot_record_init(&r);
	struct wisp_boot_decision d = wisp_boot_decide(&r, &in);

	CHECK(d.action == WISP_BOOT_FALLBACK_TO_STOCK);
	CHECK(d.reason == WISP_BOOT_REASON_RESCUE_HOLD);
}

static void test_no_rescue_image_never_halts(void)
{
	struct wisp_boot_record r;
	struct wisp_boot_inputs in = {.rescue_hold = true, .rescue_image_ok = false};

	wisp_boot_record_init(&r);
	struct wisp_boot_decision d = wisp_boot_decide(&r, &in);

	CHECK(d.action == WISP_BOOT_RUN_APP_DEGRADED);
	CHECK(d.reason == WISP_BOOT_REASON_NO_RESCUE_IMAGE);
}

/* The bootloader keeps returning to Wisp: stop resetting after MAX_FALLBACKS. */
static void test_fallback_budget(void)
{
	struct wisp_boot_record r;
	unsigned fallbacks = 0, degraded = 0;

	wisp_boot_record_init(&r);
	for (unsigned boot = 0; boot < 40; boot++) {
		struct wisp_boot_decision d = wisp_boot_decide(&r, &normal);

		CHECK(d.action != WISP_BOOT_RUN_APP_DEGRADED ||
		      d.reason == WISP_BOOT_REASON_FALLBACKS_SPENT);
		fallbacks += d.action == WISP_BOOT_FALLBACK_TO_STOCK;
		degraded += d.action == WISP_BOOT_RUN_APP_DEGRADED;
		CHECK(d.record.attempts <= WISP_BOOT_MAX_ATTEMPTS);
		r = d.record;
	}
	CHECK(fallbacks == WISP_BOOT_MAX_FALLBACKS);
	CHECK(degraded > 0);
}

/* Exhaustive: every reachable record and input ends in a valid, sealed record, and a
 * fallback is only chosen with a valid rescue image. */
static void test_exhaustive_invariants(void)
{
	for (unsigned a = 0; a <= 4; a++) {
		for (unsigned f = 0; f <= 3; f++) {
			for (unsigned bits = 0; bits < 4; bits++) {
				struct wisp_boot_record r;
				struct wisp_boot_inputs in = {
					.rescue_hold = bits & 1, .rescue_image_ok = bits & 2};

				wisp_boot_record_init(&r);
				r.attempts = (uint8_t)a;
				r.fallbacks = (uint8_t)f;
				wisp_boot_record_seal(&r);

				struct wisp_boot_decision d = wisp_boot_decide(&r, &in);

				CHECK(wisp_boot_record_valid(&d.record));
				if (d.action == WISP_BOOT_FALLBACK_TO_STOCK) {
					CHECK(in.rescue_image_ok);
				}
				if (in.rescue_hold && in.rescue_image_ok &&
				    f < WISP_BOOT_MAX_FALLBACKS) {
					CHECK(d.action == WISP_BOOT_FALLBACK_TO_STOCK);
				}
			}
		}
	}
}

int main(void)
{
	test_crc32_known_vector();
	test_record_layout();
	test_fresh_record_runs_app();
	test_corrupt_record_is_fresh();
	test_three_unconfirmed_boots_fall_back();
	test_confirm_resets();
	test_rescue_hold_falls_back_at_once();
	test_no_rescue_image_never_halts();
	test_fallback_budget();
	test_exhaustive_invariants();

	if (failures) {
		fprintf(stderr, "wisp_boot: %d check(s) failed\n", failures);
		return EXIT_FAILURE;
	}
	printf("wisp_boot: all tests passed\n");
	return EXIT_SUCCESS;
}
