/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot status block: what Wisp Boot saw and decided on this boot, left in its own RAM
 * (WISP_BOOT_RAM_*) for the app, which reports it over the case UART (docs/wisp/case-uart.md)
 * and later over BLE. The services table (boot_services.h, version >= 2) points at it.
 *
 * Shared by Wisp Boot, the Wisp app and the host tools (tests/boot/rung3.py parses the same
 * layout). Little-endian, naturally aligned, no padding the compiler could choose: the
 * _Static_asserts below pin every offset the host side reads.
 */
#ifndef WISP_BOOT_STATUS_H
#define WISP_BOOT_STATUS_H

#include <stdint.h>

#define WISP_BOOT_STATUS_MAGIC   0x54534257u /* "WBST" little-endian */
#define WISP_BOOT_STATUS_VERSION 1u

/* build flags */
#define WISP_BOOT_BUILD_OBSERVE  0x1u /* observe-only: no NOR or MRAM write code, always run-app */
#define WISP_BOOT_BUILD_LOG      0x2u /* UART1 debug log compiled in */

/* stage: how far Wisp Boot got before it handed over */
enum wisp_boot_stage {
	WISP_BOOT_STAGE_START = 1,   /* watchdog armed */
	WISP_BOOT_STAGE_NOR = 2,     /* NOR answered with the expected RDID */
	WISP_BOOT_STAGE_MOUNTED = 3, /* littlefs mounted */
	WISP_BOOT_STAGE_INPUTS = 4,  /* record, staging, rescue.bin and inventory read */
	WISP_BOOT_STAGE_DECIDED = 5, /* decision taken (and, in the fallback build, recorded) */
	WISP_BOOT_STAGE_APP = 6,     /* about to jump to the app */
};

/* The /firmware inventory: stock keeps the co-processor images there and reprograms the PSoC
 * from touch.bin on a version mismatch (hardware.md). Wisp never writes them; it only reports. */
#define WISP_BOOT_INV_MAX  12u
#define WISP_BOOT_INV_NAME 32u
#define WISP_PATH_FIRMWARE "firmware"

struct wisp_boot_inv_entry {
	char name[WISP_BOOT_INV_NAME]; /* file name, NUL-padded (longer names are cut, see result) */
	uint32_t size;                 /* bytes */
	uint32_t crc;                  /* zlib CRC-32 of the whole file */
	int32_t result;                /* 0, a negative littlefs error, or 1 = name cut */
};

struct wisp_boot_status {
	uint32_t magic;          /* WISP_BOOT_STATUS_MAGIC */
	uint16_t version;        /* WISP_BOOT_STATUS_VERSION */
	uint16_t size;           /* sizeof(struct wisp_boot_status) */
	uint32_t build;          /* WISP_BOOT_BUILD_* */
	uint32_t nor_id;         /* RDID bytes (byte 0 = manufacturer), 0 if never read */
	int32_t nor_result;      /* nor_init(): 0 or its error (-11 = unknown RDID) */
	int32_t mount_result;    /* lfs_mount(): 0 or a littlefs error; 1 = not attempted */
	int32_t record_result;   /* reading wisp/boot.rec: 0, or < 0 (missing, short) */
	uint8_t record[16];      /* wisp/boot.rec as read (zeros if none) */
	uint8_t stage;           /* enum wisp_boot_stage */
	uint8_t staging_present; /* ota/s200_firmware_ota.bin has a preamble */
	uint8_t rescue_ok;       /* wisp/rescue.bin passes the header check and its full CRC */
	uint8_t action;          /* what Wisp Boot did (enum wisp_boot_action) */
	uint8_t would_action;    /* what the fallback build decides with these inputs */
	uint8_t reason;          /* enum wisp_boot_reason of that decision */
	uint8_t inv_count;       /* entries filled in inv[] */
	uint8_t inv_truncated;   /* 1 if /firmware held more than WISP_BOOT_INV_MAX files */
	uint32_t staging_id;     /* staging preamble CRC word (valid when staging_present) */
	uint32_t staging_size;   /* staging file size in bytes (0 if missing) */
	uint32_t rescue_id;      /* rescue.bin preamble CRC word (as read, also when not ok) */
	uint32_t rescue_size;    /* rescue.bin size in bytes (0 if missing) */
	int32_t inv_result;      /* opening /firmware: 0 or a littlefs error */
	struct wisp_boot_inv_entry inv[WISP_BOOT_INV_MAX];
	uint32_t confirm_calls;  /* confirm() calls by the app since boot */
	int32_t confirm_result;  /* the last confirm()'s result */
	uint32_t crc;            /* zlib CRC-32 of every byte before it; resealed on each change */
};

_Static_assert(sizeof(struct wisp_boot_inv_entry) == 44, "inventory entry layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, record) == 28, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, stage) == 44, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, staging_id) == 52, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, inv) == 72, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, confirm_calls) == 600, "status layout");
_Static_assert(sizeof(struct wisp_boot_status) == 612, "status layout");

#endif /* WISP_BOOT_STATUS_H */
