/*
 * SPDX-License-Identifier: MIT
 *
 * The app's diagnostics (rung4.md, "Diagnostics the next image must carry", D3-D5): breadcrumbs in
 * Wisp Boot's record (src/boot/wisp_diag.h, stage codes 0x80 and up), a fatal-error handler that
 * records the fault and resets at once, and the STIMER liveness check. On boards without Wisp Boot
 * (native_sim) every call is a no-op.
 */
#ifndef WISP_APP_DIAG_H
#define WISP_APP_DIAG_H

#include <stdint.h>

#if defined(CONFIG_BOARD_WISP_G2)
#include "wisp_diag.h"

/* A breadcrumb: the record's stage and its time, sealed and cleaned from the D-cache. Any
 * thread; not from an ISR that may preempt another mark (none does). */
void wisp_app_diag_mark(uint16_t stage);
/* This boot's record as it stands (64 bytes), for the case UART's READ block 4. */
const uint8_t *wisp_app_diag_record(void);
#else
#define WISP_DIAG_APP_MAIN 0
#define WISP_DIAG_APP_CASE 0
#define WISP_DIAG_APP_HAL 0
#define WISP_DIAG_APP_DISPLAY 0
#define WISP_DIAG_APP_BT_START 0
#define WISP_DIAG_APP_BT_UP 0
#define WISP_DIAG_APP_BT_FAILED 0
#define WISP_DIAG_APP_IDLE 0
#define WISP_DIAG_APP_SESSION 0
#define WISP_DIAG_APP_RESET_REQ 0
static inline void wisp_app_diag_mark(uint16_t stage)
{
	(void)stage;
}
#endif

#endif /* WISP_APP_DIAG_H */
