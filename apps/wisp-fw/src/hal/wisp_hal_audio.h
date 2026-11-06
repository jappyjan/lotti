/*
 * SPDX-License-Identifier: MIT
 *
 * Audio HAL: microphone capture (GX8002 over I2S, or PDM0) and the piezo buzzer (PWM,
 * GPIO145). There is no speaker. LC3 encoding is the core's job (protocol service 0x06).
 */
#ifndef WISP_HAL_AUDIO_H
#define WISP_HAL_AUDIO_H

#include <stddef.h>
#include <stdint.h>

/* 16 kHz, 16-bit, mono, little-endian PCM blocks. NULL cb stops capture. */
typedef void (*wisp_mic_cb)(const int16_t *pcm, size_t samples, void *ctx);
int wisp_hal_mic_enable(wisp_mic_cb cb, void *ctx);

/* freq_hz 0 = silent. duty 0..255. Returns at once; the tone ends after duration_ms. */
int wisp_hal_buzzer(uint16_t freq_hz, uint8_t duty, uint16_t duration_ms);

#endif /* WISP_HAL_AUDIO_H */
