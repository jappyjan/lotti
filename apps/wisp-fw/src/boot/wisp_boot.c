/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — pure decision logic, record codec, image check. See wisp_boot.h.
 */

#include "wisp_boot.h"

#include <stddef.h>

#include "wisp_boot_layout.h"

uint32_t wisp_boot_crc32(uint32_t crc, const void *data, uint32_t len)
{
	const uint8_t *p = data;

	crc = ~crc;
	while (len--) {
		crc ^= *p++;
		for (int i = 0; i < 8; i++) {
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
		}
	}
	return ~crc;
}

void wisp_boot_record_seal(struct wisp_boot_record *rec)
{
	rec->crc = wisp_boot_crc32(0, rec, (uint32_t)offsetof(struct wisp_boot_record, crc));
}

void wisp_boot_record_init(struct wisp_boot_record *rec, uint32_t image_id)
{
	*rec = (struct wisp_boot_record){
		.magic = WISP_BOOT_RECORD_MAGIC,
		.version = WISP_BOOT_RECORD_VERSION,
		.state = WISP_BOOT_STATE_RUN,
		.image_id = image_id,
	};
	wisp_boot_record_seal(rec);
}

bool wisp_boot_record_valid(const struct wisp_boot_record *rec)
{
	return rec != NULL && rec->magic == WISP_BOOT_RECORD_MAGIC &&
	       rec->version == WISP_BOOT_RECORD_VERSION && rec->state <= WISP_BOOT_STATE_RESCUE &&
	       rec->attempts <= WISP_BOOT_MAX_ATTEMPTS &&
	       rec->rescue_tries <= WISP_BOOT_MAX_RESCUE_TRIES &&
	       rec->crc == wisp_boot_crc32(0, rec, (uint32_t)offsetof(struct wisp_boot_record, crc));
}

void wisp_boot_confirm(struct wisp_boot_record *rec)
{
	rec->state = WISP_BOOT_STATE_RUN;
	rec->attempts = 0;
	rec->rescue_tries = 0;
	wisp_boot_record_seal(rec);
}

struct wisp_boot_decision wisp_boot_decide(const struct wisp_boot_record *stored,
					   const struct wisp_boot_inputs *in)
{
	struct wisp_boot_decision d = {.reason = WISP_BOOT_REASON_NORMAL};
	uint32_t staging = in->staging_present ? in->staging_id : 0;
	bool rescue_due;

	if (!wisp_boot_record_valid(stored)) {
		wisp_boot_record_init(&d.record, staging);
		d.reason = WISP_BOOT_REASON_FRESH_RECORD;
	} else {
		d.record = *stored;
		/*
		 * Same install? While a rescue is pending the staging file holds either the old
		 * image (copy not committed yet) or the rescue image (copy done, not installed):
		 * both mean "this install, rescue still due". Anything else was installed since.
		 */
		bool same = staging == d.record.image_id ||
			    (d.record.state == WISP_BOOT_STATE_RESCUE && in->rescue_ok &&
			     staging == in->rescue_id);
		if (!same) {
			wisp_boot_record_init(&d.record, staging);
			d.reason = WISP_BOOT_REASON_NEW_INSTALL;
		}
	}

	if (in->rescue_hold) {
		rescue_due = true;
		d.reason = WISP_BOOT_REASON_RESCUE_HOLD;
	} else if (d.record.state == WISP_BOOT_STATE_RESCUE) {
		rescue_due = true;
		d.reason = WISP_BOOT_REASON_RESCUE_RESUME;
	} else if (d.record.attempts >= WISP_BOOT_MAX_ATTEMPTS) {
		rescue_due = true;
		d.reason = WISP_BOOT_REASON_UNCONFIRMED;
	} else {
		rescue_due = false;
	}

	if (!rescue_due) {
		d.action = WISP_BOOT_RUN_APP;
		d.record.attempts++;
	} else if (!in->rescue_ok) {
		d.action = WISP_BOOT_RUN_APP_DEGRADED;
		d.reason = WISP_BOOT_REASON_NO_RESCUE_IMAGE;
		d.record.state = WISP_BOOT_STATE_RUN;
		d.record.attempts = 1; /* this boot; a fresh window instead of re-deciding */
	} else if (d.record.rescue_tries >= WISP_BOOT_MAX_RESCUE_TRIES) {
		d.action = WISP_BOOT_RUN_APP_DEGRADED;
		d.reason = WISP_BOOT_REASON_TRIES_SPENT;
		d.record.state = WISP_BOOT_STATE_RUN;
		d.record.attempts = 1;
	} else {
		d.action = WISP_BOOT_RESCUE;
		d.record.state = WISP_BOOT_STATE_RESCUE;
		d.record.rescue_tries++;
		d.record.attempts = 0;
	}

	/* attempts stays <= MAX_ATTEMPTS and rescue_tries <= MAX_RESCUE_TRIES (both checked by
	 * wisp_boot_record_valid), so the byte counters cannot wrap. */
	wisp_boot_record_seal(&d.record);
	return d;
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

int wisp_boot_image_check(const uint8_t pre[32], uint32_t sp, uint32_t reset, uint32_t file_size)
{
	uint32_t w0 = le32(pre);
	uint32_t size = w0 & 0x00FFFFFFu;
	uint32_t end;

	if ((w0 >> 24) != WISP_PREAMBLE_FLAGS) {
		return 1;
	}
	if (size != file_size || size < WISP_PREAMBLE_SIZE + 8u) {
		return 2;
	}
	if (le32(pre + 0x10) != WISP_PREAMBLE_TYPE) {
		return 3;
	}
	if (le32(pre + 0x14) != WISP_APP_BASE) {
		return 4;
	}
	if (le32(pre + 0x08) || le32(pre + 0x0C) || le32(pre + 0x18) || le32(pre + 0x1C)) {
		return 5;
	}
	end = WISP_APP_BASE + (size - WISP_PREAMBLE_SIZE);
	if (end > WISP_APP_CEILING) {
		return 6;
	}
	if (!(sp > 0x20000000u && sp <= 0x20380000u) || (sp & 7u)) {
		return 7;
	}
	if (!(reset & 1u) || (reset & ~1u) < WISP_APP_BASE || (reset & ~1u) >= end) {
		return 8;
	}
	return 0;
}
