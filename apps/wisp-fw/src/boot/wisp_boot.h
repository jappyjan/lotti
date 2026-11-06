/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — DESIGN STUB (milestone M0). Not linked into the image entry yet.
 *
 * Wisp Boot is the tiny first stage of the native image at 0x438000 (docs/wisp/README.md,
 * docs/wisp/safety.md "Fallback-to-stock"). On every boot it:
 *   1. reads its retained boot record,
 *   2. decides — this file — whether to run the Wisp app or fall back to stock,
 *   3. on fallback: copies wisp/rescue.bin to ota/s200_firmware_ota.bin, verifies its CRC,
 *      writes the update flag (0x55555555) and resets, so the Even bootloader installs stock.
 * The app confirms a boot only after BLE is advertising and a phone session finished HELLO.
 *
 * Only step 2 exists here, as a pure function with no I/O, so it can be unit tested on the
 * host (tests/boot/) and fault-tested in Renode later (rung 3). Steps 1 and 3 need the
 * storage/power HAL and the record location, both still open.
 */
#ifndef WISP_BOOT_H
#define WISP_BOOT_H

#include <stdbool.h>
#include <stdint.h>

/* Unconfirmed boots in a row before falling back (safety.md: "3 boots in a row"). */
#define WISP_BOOT_MAX_ATTEMPTS 3u

/*
 * Fallbacks in a row that may be attempted before Wisp Boot stops trying. If the Even
 * bootloader keeps handing control back to Wisp (staged image rejected, flag not honoured),
 * resetting forever would drain the battery with no way in; running the app at least keeps
 * a chance of a phone session. Open question for rung 3 (safety.md "Still to verify").
 */
#define WISP_BOOT_MAX_FALLBACKS 2u

#define WISP_BOOT_RECORD_MAGIC   0x54424957u /* "WIBT" little-endian */
#define WISP_BOOT_RECORD_VERSION 1u

/*
 * Retained boot record. Location TBD (retained SRAM survives a warm reset but not a power
 * loss; an MRAM word is never written outside the documented flag — safety rule 1 — so a
 * NOR file or the NV area are the candidates). Fixed layout, little-endian, CRC-32 (zlib)
 * over every byte before `crc`.
 */
struct wisp_boot_record {
	uint32_t magic;
	uint16_t version;
	uint8_t attempts;  /* unconfirmed boots since the last confirm */
	uint8_t fallbacks; /* fallbacks tried since the last confirm */
	uint32_t crc;
};

/* What the platform reports to the decision. All gathered before deciding, no I/O after. */
struct wisp_boot_inputs {
	bool rescue_hold;     /* touchpad rescue hold seen at boot */
	bool rescue_image_ok; /* wisp/rescue.bin present, header + CRC valid, main-only */
};

enum wisp_boot_action {
	/* Boot the Wisp app; the record was updated (attempt counted). */
	WISP_BOOT_RUN_APP = 0,
	/* Stage wisp/rescue.bin, write the update flag, reset. The record was updated. */
	WISP_BOOT_FALLBACK_TO_STOCK = 1,
	/* A fallback is due but impossible (no valid rescue image, or the fallback budget is
	 * spent): boot the app anyway — halting would be a brick. */
	WISP_BOOT_RUN_APP_DEGRADED = 2,
};

enum wisp_boot_reason {
	WISP_BOOT_REASON_NORMAL = 0,
	WISP_BOOT_REASON_FRESH_RECORD = 1,   /* record missing/corrupt: first boot after install */
	WISP_BOOT_REASON_RESCUE_HOLD = 2,
	WISP_BOOT_REASON_UNCONFIRMED = 3,    /* MAX_ATTEMPTS unconfirmed boots */
	WISP_BOOT_REASON_NO_RESCUE_IMAGE = 4,
	WISP_BOOT_REASON_FALLBACKS_SPENT = 5,
};

struct wisp_boot_decision {
	enum wisp_boot_action action;
	enum wisp_boot_reason reason;
	struct wisp_boot_record record; /* write back before acting */
};

/* CRC-32 (zlib: reflected 0xEDB88320, init/xorout 0xFFFFFFFF). */
uint32_t wisp_boot_crc32(const void *data, uint32_t len);

/* A fresh, valid record (attempts 0). */
void wisp_boot_record_init(struct wisp_boot_record *rec);

bool wisp_boot_record_valid(const struct wisp_boot_record *rec);

/* Recompute rec->crc after changing fields. */
void wisp_boot_record_seal(struct wisp_boot_record *rec);

/*
 * The decision. `stored` may be NULL or invalid (treated as a fresh record). Pure: same
 * inputs, same output, no side effects.
 */
struct wisp_boot_decision wisp_boot_decide(const struct wisp_boot_record *stored,
					   const struct wisp_boot_inputs *in);

/* What the app does once a boot is good (BLE advertising + HELLO done): attempts and
 * fallbacks back to 0. */
void wisp_boot_confirm(struct wisp_boot_record *rec);

#endif /* WISP_BOOT_H */
