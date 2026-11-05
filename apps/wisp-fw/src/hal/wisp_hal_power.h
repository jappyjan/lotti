/*
 * SPDX-License-Identifier: MIT
 *
 * Power HAL: battery and charging (nPM1300, or BQ25180 + BQ27427), sleep, reset and the
 * watchdog. The watchdog belongs to Wisp Boot's fallback design (docs/wisp/safety.md).
 */
#ifndef WISP_HAL_POWER_H
#define WISP_HAL_POWER_H

#include <stdbool.h>
#include <stdint.h>

struct wisp_battery {
	uint16_t mv;
	uint8_t percent;
	bool charging;
	bool in_case;
};

int wisp_hal_battery(struct wisp_battery *out);

/* Feed the watchdog. Only the main loop calls this, never a timer callback. */
void wisp_hal_watchdog_feed(void);

/* Warm reset into the Even bootloader (which installs a staged image when flagged). */
void wisp_hal_reset(void);

#endif /* WISP_HAL_POWER_H */
