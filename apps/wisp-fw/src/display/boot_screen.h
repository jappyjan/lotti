/*
 * SPDX-License-Identifier: MIT
 *
 * native-1's boot screen (rung4.md W25): a test pattern and "Wisp", composed by wisp-core's display
 * engine and sent through the native display HAL to the panel.
 */
#ifndef WISP_BOOT_SCREEN_H
#define WISP_BOOT_SCREEN_H

#include <stdint.h>

/* Composes the screen, powers the panel (after the rail gate) and schedules its power-down after
 * CONFIG_WISP_BOOT_SCREEN_S. Returns a WISP_CASE_DISPLAY_* state; *err gets the error. */
uint8_t wisp_boot_screen_show(int *err);

#endif /* WISP_BOOT_SCREEN_H */
