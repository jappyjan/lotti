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

#include "wisp_diag.h"

#define WISP_BOOT_STATUS_MAGIC   0x54534257u /* "WBST" little-endian */
#define WISP_BOOT_STATUS_VERSION 2u /* 2: adds the diagnostics (rstgen_stat .. prev) before crc */

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
	/* version 2: diagnostics (rung4.md W24 analysis, D1/D2) */
	uint32_t rstgen_stat;    /* RSTGEN.STAT at the start of this boot */
	uint32_t pmic_kick;      /* the nPM1300 watchdog kick at the start: 0 or boot_pmic.h's code */
	uint16_t window_answers; /* boot reports answered in the case-UART window */
	uint16_t window_ms;      /* how long the window stayed open (ms; STIMER, 0 if no crystal) */
	uint8_t prev_valid;      /* prev holds the previous boot's valid record */
	uint8_t uart_result;     /* boot_uart_init(): 0 = up */
	uint8_t stimer_clksel;   /* STCFG CLKSEL as found (3 = the 32 kHz crystal) */
	uint8_t reserved;
	struct wisp_diag_record prev; /* the previous boot's record as found (zeros if invalid) */
	uint32_t crc;            /* zlib CRC-32 of every byte before it; resealed on each change */
};

_Static_assert(sizeof(struct wisp_boot_inv_entry) == 44, "inventory entry layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, record) == 28, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, stage) == 44, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, staging_id) == 52, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, inv) == 72, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, confirm_calls) == 600, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, rstgen_stat) == 608, "status layout");
_Static_assert(__builtin_offsetof(struct wisp_boot_status, prev) == 624, "status layout");
_Static_assert(sizeof(struct wisp_boot_status) == 692, "status layout");

/* The boot report (wisp_diag.h, D2) from a version-2 status block: what the previous boot's record
 * says, and this boot's reset cause. `source` is WISP_REPORT_SRC_BOOT or WISP_REPORT_SRC_APP. */
static inline void wisp_boot_report_fill(uint8_t out[WISP_BOOT_REPORT_SIZE], uint8_t source,
					 const struct wisp_boot_status *s)
{
	const struct wisp_diag_record *p = &s->prev;
	uint32_t ms = 0xFFFFu;
	uint8_t flags = 0;

	for (uint32_t i = 0; i < WISP_BOOT_REPORT_SIZE; i++) {
		out[i] = 0;
	}
	if (s->prev_valid) {
		flags |= WISP_REPORT_F_PREV_VALID;
		flags |= (p->flags & WISP_DIAG_F_FAULT) ? WISP_REPORT_F_PREV_FAULT : 0;
		if (s->stimer_clksel == 3u) {
			uint64_t t = ((uint64_t)p->stage_ticks * 125u) >> 12; /* ms at 32768 Hz */

			ms = t < 0xFFFFu ? (uint32_t)t : 0xFFFFu;
		}
	}
	flags |= s->pmic_kick == 0 ? WISP_REPORT_F_KICK_OK : 0;
	flags |= s->stimer_clksel == 3u ? WISP_REPORT_F_STIMER_XT : 0;
	out[0] = source;
	out[1] = flags;
	out[2] = (uint8_t)(s->prev_valid ? p->boots + 1u : 1u);
	out[3] = s->prev_valid ? (uint8_t)p->stage : 0;
	wisp_diag_put32(out + 4, s->rstgen_stat);
	wisp_diag_put16(out + 8, ms);
	if (flags & WISP_REPORT_F_PREV_FAULT) {
		wisp_diag_put32(out + 10, p->fault_pc);
		wisp_diag_put32(out + 14, p->fault_lr);
		wisp_diag_put32(out + 18, p->cfsr);
	}
}

#endif /* WISP_BOOT_STATUS_H */
