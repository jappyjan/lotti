/*
 * SPDX-License-Identifier: MIT
 *
 * Native HAL internals: init calls and the wisp-core engine callbacks (wisp/engine.h wisp_hal).
 */
#ifndef WISP_NATIVE_H
#define WISP_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct wisp_flush;

/* Each returns 0 or WISP_HAL_E*; a missing part is not fatal for the others. */
int wisp_native_power_init(void);
int wisp_native_display_init(void);
int wisp_native_input_init(void);
int wisp_native_sensors_init(void);

/* Engine callbacks: wisp_hal.present and wisp_hal.frame_done. */
void wisp_native_present(void *ctx, uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint8_t *px,
			 size_t stride);
void wisp_native_frame_done(void *ctx, uint32_t frame);

const struct wisp_flush *wisp_native_flush(void);

/* The watchdog thread (power.c): Wisp Boot's Apollo WDT and the nPM1300's, both every second.
 * Started first thing in main(); wisp_native_power_init() starts it too. */
struct wisp_watchdog_stats {
	uint32_t apollo_feeds;
	uint32_t pmic_kicks;
	uint32_t pmic_errors;
	int8_t pmic_last;  /* the last PMIC write's result (0 or -errno) */
	bool pmic_armed;   /* stock's arming sequence went through */
	bool starved;      /* the liveness check stopped feeding the Apollo WDT */
};
void wisp_native_watchdogs_start(void);
const struct wisp_watchdog_stats *wisp_native_watchdog_stats(void);

/* Battery voltage and the raw nPM1300 CHARGER STATUS / VBUS STATUS registers. */
int wisp_native_battery_raw(uint16_t *mv, uint8_t *chg_status, uint8_t *vbus_status);

#endif /* WISP_NATIVE_H */
