/*
 * SPDX-License-Identifier: MIT
 *
 * The panel rails' gate (npm1300_switch.c), for a check before anything is switched.
 */
#ifndef WISP_NPM1300_SWITCH_H
#define WISP_NPM1300_SWITCH_H

#include <zephyr/device.h>

/* Reads the rail's configuration (no write): 0 if it is stock's, -EACCES if not, or a bus error. */
int wisp_npm1300_switch_check(const struct device *dev);

/* After the same read-back gate, the rail's disable task, whatever the refcount says (a rail left on
 * by a reset inside the boot screen's window). 0, -EACCES (nothing written) or a bus error. */
int wisp_npm1300_switch_force_off(const struct device *dev);

#endif /* WISP_NPM1300_SWITCH_H */
