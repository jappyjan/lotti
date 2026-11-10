/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp case-UART protocol, the codec (docs/wisp/case-uart.md is the spec). Portable C, no
 * Zephyr: host-tested in tests/case/. The Zephyr side (wisp_case.c) only moves bytes.
 *
 * Shaped for the pinned case relay (drdaeman's case_exchange.c, apps/wisp-recovery status.py),
 * which forwards only requests of 9, 25 or 32 bytes in the loader's host framing and passes back
 * only 5A A5 FF frames of 13, 21, 29 or 32 bytes:
 *
 *   request  7E 00 01 n  'W' 'S' 'P' op  args[n - 4]  c     n = 4, 20 or 27
 *   reply    5A A5 FF L  'W' 'S' 'P' op|80 status data..  s  L = 8, 16, 24 or 27 (zero-padded)
 *
 * c = (len(request) + 0x7D + the sum of every byte before c) & 0xFF (the loader's and stock's
 * request check: stock's version query 24 00 01 00 A7 has it too); s = the sum of every byte
 * before s. Also answered: stock's version query (5 raw bytes, step 0's bridge sends it). Ignored:
 * everything else, including the case app's 0x13 status poll (see the spec).
 */
#ifndef WISP_CASE_PROTO_H
#define WISP_CASE_PROTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WISP_CASE_MAX_FRAME 32u /* the longest request and reply the relay passes */
#define WISP_CASE_READ_MAX  17u /* data bytes in one READ reply (L = 27) */
#define WISP_CASE_BOOT_REPORT_SIZE 22u /* data bytes in a BOOTREP reply (L = 27) */

/* ops (the reply carries op | 0x80) */
#define WISP_CASE_OP_IDENT 0x01u /* 9-byte request: version, stage, flags, battery, bt result */
#define WISP_CASE_OP_READ  0x02u /* 25-byte request: block u8, offset u16, length u8 */
#define WISP_CASE_OP_RESET 0x03u /* 25-byte request: "RSET" */
#define WISP_CASE_OP_BOOTREP 0x04u /* 9-byte request: the boot report (wisp_diag.h, 22 bytes) */

/* READ blocks */
#define WISP_CASE_BLOCK_STATUS 1u /* the app's status (WISP_CASE_STATUS_SIZE bytes) */
#define WISP_CASE_BLOCK_BOOT   2u /* Wisp Boot's status block (wisp_boot_status.h) */
#define WISP_CASE_BLOCK_CLOCK  3u /* stage-0: its clock measurements (stage0.c) */
#define WISP_CASE_BLOCK_DIAG   4u /* stage-0: this boot's diagnostics record (wisp_diag.h) */

/* reply status byte */
#define WISP_CASE_OK         0u
#define WISP_CASE_E_UNKNOWN  1u /* unknown op */
#define WISP_CASE_E_ARGS     2u /* wrong arguments (length, range, block, reset magic) */
#define WISP_CASE_E_NOTAVAIL 3u /* no such data on this boot (e.g. no Wisp Boot status block) */

/* The version frame's identity bytes (stock sends 01 03 05 there). */
#define WISP_CASE_ID0 0x57u /* 'W' */
#define WISP_CASE_ID1 0x53u /* 'S' */
#define WISP_CASE_ID2 0x50u /* 'P' */

#define WISP_CASE_RESET_MAGIC "RSET"

/* The app's status block, version 1 (docs/wisp/case-uart.md has the table) */
#define WISP_CASE_STATUS_VERSION 1u
#define WISP_CASE_STATUS_SIZE    56u

/* flags */
#define WISP_CASE_F_BATTERY      0x01u /* battery fields are valid */
#define WISP_CASE_F_VBUS         0x02u /* VBUS present (the case) */
#define WISP_CASE_F_CHARGING     0x04u
#define WISP_CASE_F_PMIC_WDT     0x08u /* the PMIC watchdog was armed with stock's settings */
#define WISP_CASE_F_BOOT_SVC     0x10u /* Wisp Boot's services table found */
#define WISP_CASE_F_BOOT_STATUS  0x20u /* its status block is valid (magic, size, CRC) */
#define WISP_CASE_F_BOOT_OBSERVE 0x40u /* that Wisp Boot is the observe-only build */
#define WISP_CASE_F_SESSION      0x80u /* a BLE session (HELLO done) is up now */

struct wisp_case_status {
	uint8_t stage;           /* enum wisp_app_stage (app_status.h) */
	int16_t bt_result;       /* bt_enable(): 0, its error, or WISP_CASE_BT_NOT_STARTED */
	uint8_t sensors;         /* wisp_hal_sensors_present() */
	uint8_t flags;           /* WISP_CASE_F_* */
	uint16_t battery_mv;
	uint8_t charger_status;  /* nPM1300 BCHGCHARGESTATUS, raw */
	uint8_t vbus_status;     /* nPM1300 VBUSINSTATUS, raw */
	uint8_t image_kind;      /* 0 = native-0, 255 = development build */
	int8_t pmic_last;        /* last PMIC watchdog write: 0 or -errno */
	uint32_t reset_cause;    /* Apollo510 RSTGEN STAT as the app found it */
	uint32_t uptime_ms;
	uint32_t pmic_kicks;
	uint32_t pmic_errors;
	uint32_t apollo_feeds;
	uint32_t sessions;       /* BLE sessions since boot */
	uint16_t confirm_calls;  /* confirm() calls through Wisp Boot's services */
	int16_t confirm_result;  /* the last one's result, or WISP_CASE_NO_CONFIRM */
	uint16_t boot_block_size; /* Wisp Boot status block size, 0 if none */
	uint8_t display;         /* WISP_CASE_DISPLAY_* (native-1 on; 0 before) */
	int8_t display_err;      /* the panel's last error, 0 or -errno */
	char rev[12];            /* firmware git revision, NUL-padded */
};

/* display: what the panel did this boot (offset 42; offset 43 is its error). */
#define WISP_CASE_DISPLAY_NONE    0 /* not tried (no panel in this image, or not yet) */
#define WISP_CASE_DISPLAY_ON      1 /* powered, the boot screen drawn */
#define WISP_CASE_DISPLAY_OFF     2 /* the boot screen was shown and the panel powered down */
#define WISP_CASE_DISPLAY_REFUSED 3 /* the rail gate refused: the PMIC is not as stock left it */
#define WISP_CASE_DISPLAY_FAILED  4 /* power-up or drawing failed (display_err) */

#define WISP_CASE_BT_NOT_STARTED 0x7FFF
#define WISP_CASE_NO_CONFIRM     0x7FFF

struct wisp_case_version {
	uint8_t major, minor, patch, image_kind, hw;
};

/* What the codec needs from the target to answer. With `status` NULL (Wisp Boot's boot-report
 * window) only BOOTREP is answered: IDENT, READ, RESET and stock's version query are ignored. */
struct wisp_case_ops {
	void (*status)(void *ctx, struct wisp_case_status *out);
	/* Wisp Boot's status block, or NULL (len = 0). offset = where this READ starts (the target
	 * may take a fresh snapshot at 0). */
	const uint8_t *(*boot_block)(void *ctx, size_t offset, size_t *len);
	void *ctx;
	/* Optional. The boot report (WISP_BOOT_REPORT_SIZE bytes); returns 0, or nonzero if there is
	 * none (status 3). NULL: BOOTREP gets status 1 (unknown op), as before it existed. */
	int (*boot_report)(void *ctx, uint8_t *out);
	/* Optional. READ blocks 3 and up, or NULL (len = 0): status 2, as for an unknown block. */
	const uint8_t *(*extra_block)(void *ctx, uint8_t block, size_t offset, size_t *len);
};

/* Byte-wise request parser. */
struct wisp_case_rx {
	uint8_t buf[WISP_CASE_MAX_FRAME];
	size_t len;
};

void wisp_case_rx_init(struct wisp_case_rx *rx);

/*
 * Feed one received byte. When it completes a request, writes the reply frame into out (cap >=
 * WISP_CASE_MAX_FRAME) and returns its length; *reset is set if the target must reset once the
 * reply is sent. Returns 0 otherwise (incomplete, ignored or malformed: nothing is sent).
 */
size_t wisp_case_rx_byte(struct wisp_case_rx *rx, uint8_t b, const struct wisp_case_version *ver,
			 const struct wisp_case_ops *ops, uint8_t *out, bool *reset);

/* Encoders, exposed for the tests. */
size_t wisp_case_frame(uint8_t *out, const uint8_t *payload, size_t len);
size_t wisp_case_version_frame(uint8_t *out, const struct wisp_case_version *ver);
void wisp_case_status_encode(uint8_t out[WISP_CASE_STATUS_SIZE], const struct wisp_case_status *s);

#endif /* WISP_CASE_PROTO_H */
