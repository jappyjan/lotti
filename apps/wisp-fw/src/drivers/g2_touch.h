/*
 * SPDX-License-Identifier: MIT
 *
 * G2 touchpad + wear controller (PSoC 4000T, Even's firmware) — driver API.
 * Facts: docs/wisp/hardware.md "Touch and wear".
 */
#ifndef WISP_G2_TOUCH_H
#define WISP_G2_TOUCH_H

#include <stdbool.h>
#include <stdint.h>

#include <zephyr/device.h>

/* Report byte 1. */
#define G2_TOUCH_PRESS      0x01u
#define G2_TOUCH_RELEASE    0x02u
#define G2_TOUCH_TAP        0x04u /* count in .count */
#define G2_TOUCH_DOUBLE     0x08u
#define G2_TOUCH_LONG       0x10u
#define G2_TOUCH_SLIDE_BACK 0x20u /* stock "L" / DOWNROLL */
#define G2_TOUCH_SLIDE_FWD  0x40u /* stock "R" / UPROLL */
#define G2_TOUCH_ERROR      0x80u /* the driver resets the PSoC, the event is not delivered */

/* Report byte 0. */
enum g2_wear {
	G2_WEAR_NO_CHANGE = 0,
	G2_WEAR_OFF = 1,
	G2_WEAR_ON = 2,
};

struct g2_touch_event {
	uint8_t wear;   /* enum g2_wear */
	uint8_t flags;  /* G2_TOUCH_* */
	uint8_t count;  /* tap count, or slide distance */
	uint8_t speed;  /* slide speed */
	uint8_t raw[16];
};

typedef void (*g2_touch_cb)(const struct device *dev, const struct g2_touch_event *ev, void *ctx);

/* Called from the system work queue for every report. NULL disables delivery. */
int g2_touch_set_callback(const struct device *dev, g2_touch_cb cb, void *ctx);

/* PSoC firmware version (command 1), read at init. Log only: Wisp never updates the PSoC. */
uint32_t g2_touch_version(const struct device *dev);

/* Last wear state seen (enum g2_wear; G2_WEAR_NO_CHANGE until the first proximity report). */
uint8_t g2_touch_wear(const struct device *dev);

/* Command 5: save a fresh proximity baseline. The PSoC writes it to its own EEPROM; stock does
 * this on every case insertion. Call only while the glasses are in the case. */
int g2_touch_save_baseline(const struct device *dev);

/* Read and deliver one report now, as on an attention edge (the work item calls this). For
 * the Renode driver test, which has no GPIO interrupt model. */
int g2_touch_service(const struct device *dev);

/* The PSoC command set this driver may send (anything else, command 2 = DFU above all, is
 * refused before it reaches the bus). Exposed for the unit test. */
bool g2_touch_cmd_allowed(uint8_t cmd);

#endif /* WISP_G2_TOUCH_H */
