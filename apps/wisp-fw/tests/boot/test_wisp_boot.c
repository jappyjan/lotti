/*
 * SPDX-License-Identifier: MIT
 *
 * Host unit tests for the Wisp Boot decision, record codec and image check
 * (src/boot/wisp_boot.c). Built and run by scripts/test.sh with the host compiler under
 * ASan/UBSan; no Zephyr, no hardware.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wisp_boot.h"
#include "wisp_boot_layout.h"

static int failures;

#define CHECK(cond)                                                                        \
	do {                                                                               \
		if (!(cond)) {                                                             \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			failures++;                                                        \
		}                                                                          \
	} while (0)

#define WISP_ID   0x11111111u /* staging CRC word of the installed Wisp image */
#define RESCUE_ID 0x22222222u /* preamble CRC word of wisp/rescue.bin */
#define OTHER_ID  0x33333333u

static const struct wisp_boot_inputs normal = {
	.rescue_ok = true, .rescue_id = RESCUE_ID, .staging_present = true, .staging_id = WISP_ID};

/* One boot: decide, then store the record (as Wisp Boot does before acting). */
static struct wisp_boot_decision boot(struct wisp_boot_record *rec, const struct wisp_boot_inputs *in)
{
	struct wisp_boot_decision d = wisp_boot_decide(rec, in);

	*rec = d.record;
	CHECK(wisp_boot_record_valid(rec));
	return d;
}

static void test_crc32(void)
{
	CHECK(wisp_boot_crc32(0, "123456789", 9) == 0xCBF43926u); /* zlib check value */
	CHECK(wisp_boot_crc32(0, "", 0) == 0);
	/* chunked == one shot */
	CHECK(wisp_boot_crc32(wisp_boot_crc32(0, "1234", 4), "56789", 5) == 0xCBF43926u);
}

static void test_record_layout(void)
{
	CHECK(sizeof(struct wisp_boot_record) == 16);
}

static void test_fresh_record_runs_app(void)
{
	struct wisp_boot_decision d = wisp_boot_decide(NULL, &normal);

	CHECK(d.action == WISP_BOOT_RUN_APP);
	CHECK(d.reason == WISP_BOOT_REASON_FRESH_RECORD);
	CHECK(d.record.attempts == 1);
	CHECK(d.record.image_id == WISP_ID);
	CHECK(wisp_boot_record_valid(&d.record));
}

static void test_three_unconfirmed_boots_then_rescue(void)
{
	struct wisp_boot_record rec;
	struct wisp_boot_decision d;

	wisp_boot_record_init(&rec, WISP_ID);
	for (unsigned i = 0; i < WISP_BOOT_MAX_ATTEMPTS; i++) {
		d = boot(&rec, &normal);
		CHECK(d.action == WISP_BOOT_RUN_APP);
	}
	d = boot(&rec, &normal);
	CHECK(d.action == WISP_BOOT_RESCUE);
	CHECK(d.reason == WISP_BOOT_REASON_UNCONFIRMED);
	CHECK(rec.state == WISP_BOOT_STATE_RESCUE);
	CHECK(rec.rescue_tries == 1);
}

static void test_confirm_resets(void)
{
	struct wisp_boot_record rec;

	wisp_boot_record_init(&rec, WISP_ID);
	for (int round = 0; round < 10; round++) {
		CHECK(boot(&rec, &normal).action == WISP_BOOT_RUN_APP);
		CHECK(boot(&rec, &normal).action == WISP_BOOT_RUN_APP);
		wisp_boot_confirm(&rec);
		CHECK(rec.attempts == 0 && rec.rescue_tries == 0);
	}
}

static void test_rescue_hold(void)
{
	struct wisp_boot_inputs in = normal;
	struct wisp_boot_decision d;

	in.rescue_hold = true;
	d = wisp_boot_decide(NULL, &in);
	CHECK(d.action == WISP_BOOT_RESCUE);
	CHECK(d.reason == WISP_BOOT_REASON_RESCUE_HOLD);
}

/* A power cut anywhere in the rescue: the next boot resumes it, whether the staging file
 * still holds the Wisp image (copy not committed) or already the rescue image. */
static void test_rescue_resumes_after_power_cut(void)
{
	struct wisp_boot_record rec;
	struct wisp_boot_inputs committed = normal;

	committed.staging_id = RESCUE_ID;
	wisp_boot_record_init(&rec, WISP_ID);
	rec.attempts = WISP_BOOT_MAX_ATTEMPTS;
	wisp_boot_record_seal(&rec);
	CHECK(boot(&rec, &normal).action == WISP_BOOT_RESCUE);
	/* cut before the copy committed */
	struct wisp_boot_decision d = boot(&rec, &normal);
	CHECK(d.action == WISP_BOOT_RESCUE && d.reason == WISP_BOOT_REASON_RESCUE_RESUME);
	/* cut after the copy committed (staging = rescue) */
	d = boot(&rec, &committed);
	CHECK(d.action == WISP_BOOT_RESCUE && d.reason == WISP_BOOT_REASON_RESCUE_RESUME);
	CHECK(rec.image_id == WISP_ID);
}

static void test_rescue_tries_spent_runs_degraded(void)
{
	struct wisp_boot_record rec;
	struct wisp_boot_decision d;

	wisp_boot_record_init(&rec, WISP_ID);
	rec.attempts = WISP_BOOT_MAX_ATTEMPTS;
	wisp_boot_record_seal(&rec);
	for (unsigned i = 0; i < WISP_BOOT_MAX_RESCUE_TRIES; i++) {
		CHECK(boot(&rec, &normal).action == WISP_BOOT_RESCUE);
	}
	d = boot(&rec, &normal);
	CHECK(d.action == WISP_BOOT_RUN_APP_DEGRADED);
	CHECK(d.reason == WISP_BOOT_REASON_TRIES_SPENT);
	CHECK(rec.state == WISP_BOOT_STATE_RUN);
	/* still never halts: from here every boot runs the app */
	for (int i = 0; i < 20; i++) {
		CHECK(boot(&rec, &normal).action != WISP_BOOT_RESCUE);
	}
}

static void test_no_rescue_image_never_rescues(void)
{
	struct wisp_boot_inputs in = normal;
	struct wisp_boot_record rec;
	int degraded = 0;

	in.rescue_ok = false;
	wisp_boot_record_init(&rec, WISP_ID);
	for (int i = 0; i < 30; i++) {
		struct wisp_boot_decision d = boot(&rec, &in);

		CHECK(d.action != WISP_BOOT_RESCUE);
		degraded += d.action == WISP_BOOT_RUN_APP_DEGRADED;
	}
	CHECK(degraded == 9); /* boot 4, then every third boot */
}

/* A new install (the staging file changed) starts a fresh record, also mid-rescue. */
static void test_new_install_resets(void)
{
	struct wisp_boot_inputs other = normal;
	struct wisp_boot_record rec;
	struct wisp_boot_decision d;

	other.staging_id = OTHER_ID;
	wisp_boot_record_init(&rec, WISP_ID);
	rec.attempts = 2;
	rec.state = WISP_BOOT_STATE_RESCUE;
	rec.rescue_tries = WISP_BOOT_MAX_RESCUE_TRIES;
	wisp_boot_record_seal(&rec);
	d = boot(&rec, &other);
	CHECK(d.action == WISP_BOOT_RUN_APP);
	CHECK(d.reason == WISP_BOOT_REASON_NEW_INSTALL);
	CHECK(rec.attempts == 1 && rec.rescue_tries == 0 && rec.image_id == OTHER_ID);
}

static void test_corrupt_records(void)
{
	struct wisp_boot_record rec;

	wisp_boot_record_init(&rec, WISP_ID);
	for (size_t i = 0; i < sizeof(rec) * 8; i++) {
		struct wisp_boot_record bad = rec;

		((unsigned char *)&bad)[i / 8] ^= (unsigned char)(1u << (i % 8));
		CHECK(!wisp_boot_record_valid(&bad));
		CHECK(wisp_boot_decide(&bad, &normal).reason == WISP_BOOT_REASON_FRESH_RECORD);
	}
	CHECK(!wisp_boot_record_valid(NULL));
}

/* Exhaustive sweep over small states: never wraps, never yields an invalid record, and with
 * a valid rescue image an app that never confirms reaches a rescue within MAX_ATTEMPTS + 1
 * boots from any valid state of the same install. */
static void test_sweep(void)
{
	for (unsigned st = 0; st <= 1; st++) {
		for (unsigned a = 0; a <= WISP_BOOT_MAX_ATTEMPTS; a++) {
			for (unsigned t = 0; t <= WISP_BOOT_MAX_RESCUE_TRIES; t++) {
				for (unsigned mask = 0; mask < 8; mask++) {
					struct wisp_boot_inputs in = normal;
					struct wisp_boot_record rec;

					in.rescue_hold = mask & 1;
					in.rescue_ok = !(mask & 2);
					if (mask & 4) {
						in.staging_id = RESCUE_ID;
					}
					wisp_boot_record_init(&rec, WISP_ID);
					rec.state = (uint8_t)st;
					rec.attempts = (uint8_t)a;
					rec.rescue_tries = (uint8_t)t;
					wisp_boot_record_seal(&rec);
					for (int n = 0; n < 12; n++) {
						struct wisp_boot_decision d = boot(&rec, &in);

						CHECK(d.record.attempts <= WISP_BOOT_MAX_ATTEMPTS);
						CHECK(d.record.rescue_tries <= WISP_BOOT_MAX_RESCUE_TRIES);
						CHECK(d.action <= WISP_BOOT_RUN_APP_DEGRADED);
						if (d.action == WISP_BOOT_RESCUE) {
							CHECK(in.rescue_ok);
						}
					}
				}
				/* liveness: valid rescue, no hold, the same install, tries left */
				if (t < WISP_BOOT_MAX_RESCUE_TRIES) {
					struct wisp_boot_record rec;
					int rescued = 0;

					wisp_boot_record_init(&rec, WISP_ID);
					rec.state = (uint8_t)st;
					rec.attempts = (uint8_t)a;
					rec.rescue_tries = (uint8_t)t;
					wisp_boot_record_seal(&rec);
					for (unsigned n = 0; n <= WISP_BOOT_MAX_ATTEMPTS && !rescued; n++) {
						rescued = boot(&rec, &normal).action == WISP_BOOT_RESCUE;
					}
					CHECK(rescued);
				}
			}
		}
	}
}

static void put32(unsigned char *p, uint32_t v)
{
	p[0] = (unsigned char)v;
	p[1] = (unsigned char)(v >> 8);
	p[2] = (unsigned char)(v >> 16);
	p[3] = (unsigned char)(v >> 24);
}

static void test_image_check(void)
{
	unsigned char pre[32] = {0};
	const uint32_t size = 0x1000;
	const uint32_t sp = 0x2007FB00u, rst = 0x00438101u;

	put32(pre, 0x04000000u | size);
	put32(pre + 0x10, 0xCB);
	put32(pre + 0x14, 0x438000);
	CHECK(wisp_boot_image_check(pre, sp, rst, size) == 0);
	CHECK(wisp_boot_image_check(pre, sp, rst, size + 1) == 2);      /* size mismatch */
	CHECK(wisp_boot_image_check(pre, 0x10000000u, rst, size) == 7); /* SP not in SRAM */
	CHECK(wisp_boot_image_check(pre, sp + 4, rst, size) == 7);      /* SP misaligned */
	CHECK(wisp_boot_image_check(pre, sp, rst & ~1u, size) == 8);    /* not Thumb */
	CHECK(wisp_boot_image_check(pre, sp, 0x00440001u, size) == 8);  /* outside the image */
	pre[3] = 0x05;
	CHECK(wisp_boot_image_check(pre, sp, rst, size) == 1);          /* flags */
	pre[3] = 0x04;
	put32(pre + 0x14, 0x410000);
	CHECK(wisp_boot_image_check(pre, sp, rst, size) == 4);          /* run base */
	put32(pre + 0x14, 0x438000);
	put32(pre + 0x08, 1);
	CHECK(wisp_boot_image_check(pre, sp, rst, size) == 5);          /* reserved word */
	put32(pre + 0x08, 0);
	put32(pre, 0x04000000u | 0x00FFFFFFu);                           /* end past 0x7F8000 */
	CHECK(wisp_boot_image_check(pre, sp, rst, 0x00FFFFFFu) == 6);
}

int main(void)
{
	test_crc32();
	test_record_layout();
	test_fresh_record_runs_app();
	test_three_unconfirmed_boots_then_rescue();
	test_confirm_resets();
	test_rescue_hold();
	test_rescue_resumes_after_power_cut();
	test_rescue_tries_spent_runs_degraded();
	test_no_rescue_image_never_rescues();
	test_new_install_resets();
	test_corrupt_records();
	test_sweep();
	test_image_check();
	if (failures) {
		fprintf(stderr, "test_wisp_boot: %d failure(s)\n", failures);
		return 1;
	}
	printf("test_wisp_boot: all passed\n");
	return 0;
}
