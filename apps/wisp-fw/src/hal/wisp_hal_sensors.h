/*
 * SPDX-License-Identifier: MIT
 *
 * Sensor HAL: IMU (ICM-45608), magnetometer, ambient light (right temple only), wear
 * (PSoC proximity), temperature. Samples are batched by the HAL and delivered in blocks to
 * keep wake-ups rare (goal 4, protocol service 0x05). Units are SI-derived fixed point.
 */
#ifndef WISP_HAL_SENSORS_H
#define WISP_HAL_SENSORS_H

#include <stddef.h>
#include <stdint.h>

enum wisp_sensor {
	WISP_SENSOR_ACCEL = 0, /* mg, x/y/z */
	WISP_SENSOR_GYRO = 1,  /* mdps, x/y/z */
	WISP_SENSOR_MAG = 2,   /* 0.1 µT, x/y/z */
	WISP_SENSOR_LIGHT = 3, /* lux * 100 */
	WISP_SENSOR_WEAR = 4,  /* 0 = off the head, 1 = worn */
	WISP_SENSOR_TEMP = 5,  /* 0.01 °C */
	WISP_SENSOR_COUNT
};

struct wisp_sensor_sample {
	uint64_t t_ms;
	int32_t v[3];
};

typedef void (*wisp_sensor_cb)(enum wisp_sensor s, const struct wisp_sensor_sample *samples,
			       size_t count, void *ctx);

/* Which sensors this temple has (bit per enum wisp_sensor). */
uint32_t wisp_hal_sensors_present(void);

/* rate_hz 0 = off. batch = samples per callback. */
int wisp_hal_sensor_configure(enum wisp_sensor s, uint16_t rate_hz, uint16_t batch,
			      wisp_sensor_cb cb, void *ctx);

#endif /* WISP_HAL_SENSORS_H */
