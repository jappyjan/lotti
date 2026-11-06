/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp HAL — the boundary between Wisp core (portable C, packages/wisp-core) and one target
 * (docs/wisp/README.md, "Architecture"). Each target implements these headers once:
 *   native  Apollo510 drivers (this app, later)
 *   host    calls into the stock firmware
 *   sim     desktop / WASM
 *
 * M0 status: declarations only. Nothing implements or calls them yet, and nothing here may
 * depend on Zephyr — the same headers serve every target.
 *
 * Conventions: functions return 0 or a negative errno-style code (WISP_HAL_E*). Callbacks
 * into the core may run in interrupt context unless stated otherwise; the core copies data
 * out and returns quickly. Everything starts powered off (decision W9).
 */
#ifndef WISP_HAL_H
#define WISP_HAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WISP_HAL_OK        0
#define WISP_HAL_EIO      (-5)
#define WISP_HAL_ENOMEM   (-12)
#define WISP_HAL_EBUSY    (-16)
#define WISP_HAL_EINVAL   (-22)
#define WISP_HAL_ENOTSUP  (-95)
#define WISP_HAL_ETIMEDOUT (-110)

/* Monotonic milliseconds since boot; the core's only clock. */
uint64_t wisp_hal_uptime_ms(void);

#include "wisp_hal_display.h"
#include "wisp_hal_input.h"
#include "wisp_hal_sensors.h"
#include "wisp_hal_audio.h"
#include "wisp_hal_power.h"
#include "wisp_hal_storage.h"
#include "wisp_hal_link.h"

#endif /* WISP_HAL_H */
