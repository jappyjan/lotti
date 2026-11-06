/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — the pure parts: boot decision, boot record codec, staged-image check, CRC-32.
 * No I/O, no hardware: host unit tests (tests/boot/) build this file alone.
 *
 * Wisp Boot is the first stage of the native image at 0x438000 (docs/wisp/safety.md
 * "Fallback-to-stock"). Every boot it reads its boot record (littlefs file wisp/boot.rec on
 * the NOR) and the 8-byte preamble head of the staged file ota/s200_firmware_ota.bin, checks
 * wisp/rescue.bin, decides with wisp_boot_decide(), writes the record back, then either jumps
 * to the Wisp app or performs the rescue: copy wisp/rescue.bin to the staging file, verify it,
 * write the update flag, reset. The Even bootloader then installs stock.
 *
 * Why the record lives on the NOR (rung 3, see apps/wisp-fw/README.md): it must survive power
 * loss and every reset kind; retained SRAM does neither reliably (and the SBL plus the Even
 * bootloader run before Wisp Boot on every boot and use SRAM themselves). MRAM would survive,
 * but Wisp Boot's only MRAM write stays the update flag (safety rule 1). littlefs commits a
 * small file atomically (copy-on-write metadata), and Wisp Boot needs littlefs anyway for the
 * rescue copy.
 *
 * Install identity: an install always goes through the staging file (the bootloader programs
 * MRAM from it and never deletes it), so the CRC word of the staging preamble identifies what
 * was installed last. A record whose image_id differs belongs to an older install and is
 * replaced by a fresh one — a reinstalled Wisp starts with a clean attempt count.
 */
#ifndef WISP_BOOT_H
#define WISP_BOOT_H

#include <stdbool.h>
#include <stdint.h>

/* Unconfirmed boots in a row before falling back (safety.md: "3 boots in a row"). */
#define WISP_BOOT_MAX_ATTEMPTS 3u

/*
 * Rescue attempts (copy + verify + flag + reset) before Wisp Boot stops trying and runs the
 * app degraded. Each boot that reaches Wisp Boot with a rescue pending counts one: a power cut
 * in the middle of the rescue, or a bootloader that did not install the staged image. Running
 * the app instead of resetting forever keeps a chance of a phone session.
 */
#define WISP_BOOT_MAX_RESCUE_TRIES 4u

#define WISP_BOOT_RECORD_MAGIC   0x54424957u /* "WIBT" little-endian */
#define WISP_BOOT_RECORD_VERSION 2u

enum wisp_boot_state {
	WISP_BOOT_STATE_RUN = 0,    /* counting app boots */
	WISP_BOOT_STATE_RESCUE = 1, /* a rescue was decided and is not known to have completed */
};

/* The boot record, stored as-is (little-endian, 16 bytes) in wisp/boot.rec. CRC-32 (zlib)
 * over every byte before `crc`. */
struct wisp_boot_record {
	uint32_t magic;
	uint8_t version;
	uint8_t state;        /* enum wisp_boot_state */
	uint8_t attempts;     /* unconfirmed app boots since the last confirm */
	uint8_t rescue_tries; /* rescues started since the last confirm / fresh record */
	uint32_t image_id;    /* staging-file CRC word of the install this record belongs to */
	uint32_t crc;
};

/* What the platform reports to the decision. Gathered before deciding, no I/O after. */
struct wisp_boot_inputs {
	bool rescue_hold;     /* touchpad rescue hold seen at boot */
	bool rescue_ok;       /* wisp/rescue.bin present and passes wisp_boot_image_check() + CRC */
	uint32_t rescue_id;   /* its preamble CRC word (valid when rescue_ok) */
	bool staging_present; /* ota/s200_firmware_ota.bin has at least a preamble */
	uint32_t staging_id;  /* its preamble CRC word (valid when staging_present) */
};

enum wisp_boot_action {
	/* Boot the Wisp app; the record was updated (attempt counted). */
	WISP_BOOT_RUN_APP = 0,
	/* Stage wisp/rescue.bin, write the update flag, reset. The record was updated. */
	WISP_BOOT_RESCUE = 1,
	/* A rescue is due but impossible (no valid rescue image, or the tries are spent): boot the
	 * app anyway with a fresh attempt window — halting would be a brick. */
	WISP_BOOT_RUN_APP_DEGRADED = 2,
};

enum wisp_boot_reason {
	WISP_BOOT_REASON_NORMAL = 0,
	WISP_BOOT_REASON_FRESH_RECORD = 1, /* record missing/corrupt */
	WISP_BOOT_REASON_NEW_INSTALL = 2,  /* record from an older install */
	WISP_BOOT_REASON_RESCUE_HOLD = 3,
	WISP_BOOT_REASON_UNCONFIRMED = 4,  /* MAX_ATTEMPTS unconfirmed boots */
	WISP_BOOT_REASON_RESCUE_RESUME = 5, /* a rescue was pending: power cut or not installed */
	WISP_BOOT_REASON_NO_RESCUE_IMAGE = 6,
	WISP_BOOT_REASON_TRIES_SPENT = 7,
};

struct wisp_boot_decision {
	enum wisp_boot_action action;
	enum wisp_boot_reason reason;
	struct wisp_boot_record record; /* write back before acting */
};

/* CRC-32 (zlib: reflected 0xEDB88320, init/xorout 0xFFFFFFFF). `crc` = previous result
 * (0 to start), so it can run over chunks: crc = wisp_boot_crc32(crc, chunk, n). */
uint32_t wisp_boot_crc32(uint32_t crc, const void *data, uint32_t len);

void wisp_boot_record_init(struct wisp_boot_record *rec, uint32_t image_id);
bool wisp_boot_record_valid(const struct wisp_boot_record *rec);
void wisp_boot_record_seal(struct wisp_boot_record *rec);

/*
 * The decision. `stored` may be NULL or invalid (treated as missing). Pure: same inputs, same
 * output, no side effects.
 */
struct wisp_boot_decision wisp_boot_decide(const struct wisp_boot_record *stored,
					   const struct wisp_boot_inputs *in);

/* What the app's confirm does once a boot is good (BLE advertising + HELLO done). */
void wisp_boot_confirm(struct wisp_boot_record *rec);

/*
 * Staged-image header check: the 32-byte preamble of a main image as the Even bootloader reads
 * it, plus its first two vector words, against the file size. Mirrors safety rule 3 (wisp-ota
 * has its own implementation): flags 0x04, size = file size, type 0xCB, run base 0x438000,
 * reserved words 0, end <= 0x7F8000, SP in SRAM and 8-byte aligned, reset vector Thumb and
 * inside the image. The CRC (word 1) is checked separately by streaming the file.
 * Returns 0 when acceptable, else a small positive code naming the first failed check.
 */
int wisp_boot_image_check(const uint8_t preamble[32], uint32_t sp, uint32_t reset,
			  uint32_t file_size);

#endif /* WISP_BOOT_H */
