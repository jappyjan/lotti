/*
 * SPDX-License-Identifier: MIT
 *
 * Native HAL internals: init calls and the wisp-core engine callbacks (wisp/engine.h wisp_hal).
 */
#ifndef WISP_NATIVE_H
#define WISP_NATIVE_H

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

#endif /* WISP_NATIVE_H */
