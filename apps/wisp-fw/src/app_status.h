/*
 * SPDX-License-Identifier: MIT
 *
 * What the app reports about itself over the case UART (docs/wisp/case-uart.md, STATUS): how far
 * the boot got, the Bluetooth result, the sensors found, the BLE sessions. Set by main.c and the
 * BLE side; read by src/case/wisp_case.c. Plain words, written from one thread each.
 */
#ifndef WISP_APP_STATUS_H
#define WISP_APP_STATUS_H

#include <stdint.h>

enum wisp_app_stage {
	WISP_APP_STAGE_KERNEL = 1,    /* main() entered */
	WISP_APP_STAGE_HAL = 2,       /* the native HAL is up */
	WISP_APP_STAGE_BT_START = 3,  /* bt_enable() running (the EM9305 bring-up) */
	WISP_APP_STAGE_BT_UP = 4,     /* Bluetooth up, advertising */
	WISP_APP_STAGE_BT_FAILED = 5, /* Bluetooth unavailable, running without a link */
};

struct wisp_app_status {
	volatile uint8_t stage;
	volatile int16_t bt_result; /* WISP_CASE_BT_NOT_STARTED until bt_enable() returns */
	volatile uint8_t sensors;
	volatile uint8_t session_up;
	volatile uint32_t sessions;
	volatile uint16_t confirm_calls;
	volatile int16_t confirm_result;
	volatile uint8_t display;    /* WISP_CASE_DISPLAY_* */
	volatile int8_t display_err;
	uint32_t reset_cause;
};

extern struct wisp_app_status wisp_app_status;

#endif /* WISP_APP_STATUS_H */
