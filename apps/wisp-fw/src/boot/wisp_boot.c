/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot decision logic — DESIGN STUB, see wisp_boot.h. Host-testable: no Zephyr, no I/O.
 */

#include "wisp_boot.h"

#include <stddef.h>

uint32_t wisp_boot_crc32(const void *data, uint32_t len)
{
	const uint8_t *p = data;
	uint32_t crc = 0xFFFFFFFFu;

	while (len--) {
		crc ^= *p++;
		for (int i = 0; i < 8; i++) {
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
		}
	}
	return crc ^ 0xFFFFFFFFu;
}

void wisp_boot_record_seal(struct wisp_boot_record *rec)
{
	rec->crc = wisp_boot_crc32(rec, (uint32_t)offsetof(struct wisp_boot_record, crc));
}

void wisp_boot_record_init(struct wisp_boot_record *rec)
{
	*rec = (struct wisp_boot_record){
		.magic = WISP_BOOT_RECORD_MAGIC,
		.version = WISP_BOOT_RECORD_VERSION,
	};
	wisp_boot_record_seal(rec);
}

bool wisp_boot_record_valid(const struct wisp_boot_record *rec)
{
	return rec != NULL && rec->magic == WISP_BOOT_RECORD_MAGIC &&
	       rec->version == WISP_BOOT_RECORD_VERSION &&
	       rec->crc == wisp_boot_crc32(rec, (uint32_t)offsetof(struct wisp_boot_record, crc));
}

void wisp_boot_confirm(struct wisp_boot_record *rec)
{
	rec->attempts = 0;
	rec->fallbacks = 0;
	wisp_boot_record_seal(rec);
}

struct wisp_boot_decision wisp_boot_decide(const struct wisp_boot_record *stored,
					   const struct wisp_boot_inputs *in)
{
	struct wisp_boot_decision d = {.reason = WISP_BOOT_REASON_NORMAL};
	bool fallback_due;

	if (wisp_boot_record_valid(stored)) {
		d.record = *stored;
	} else {
		wisp_boot_record_init(&d.record);
		d.reason = WISP_BOOT_REASON_FRESH_RECORD;
	}

	if (in->rescue_hold) {
		fallback_due = true;
		d.reason = WISP_BOOT_REASON_RESCUE_HOLD;
	} else if (d.record.attempts >= WISP_BOOT_MAX_ATTEMPTS) {
		fallback_due = true;
		d.reason = WISP_BOOT_REASON_UNCONFIRMED;
	} else {
		fallback_due = false;
	}

	if (!fallback_due) {
		d.action = WISP_BOOT_RUN_APP;
		d.record.attempts++;
	} else if (!in->rescue_image_ok) {
		d.action = WISP_BOOT_RUN_APP_DEGRADED;
		d.reason = WISP_BOOT_REASON_NO_RESCUE_IMAGE;
		d.record.attempts = 0; /* give the app a fresh window instead of re-deciding */
	} else if (d.record.fallbacks >= WISP_BOOT_MAX_FALLBACKS) {
		d.action = WISP_BOOT_RUN_APP_DEGRADED;
		d.reason = WISP_BOOT_REASON_FALLBACKS_SPENT;
		d.record.attempts = 0;
	} else {
		d.action = WISP_BOOT_FALLBACK_TO_STOCK;
		d.record.fallbacks++;
		d.record.attempts = 0;
	}

	/* attempts never passes MAX_ATTEMPTS and fallbacks never passes MAX_FALLBACKS + 0, so
	 * the byte counters cannot wrap. */
	wisp_boot_record_seal(&d.record);
	return d;
}
