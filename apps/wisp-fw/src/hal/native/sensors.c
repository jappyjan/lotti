/*
 * SPDX-License-Identifier: MIT
 *
 * Native sensor HAL: IMU (ICM-45608, data-ready interrupt, batched), ambient light (OPT3007,
 * one single-shot conversion per period on the system work queue), wear (touch controller
 * proximity, event-driven). Every sensor is suspended (IMU rail off, ALS in shutdown) until
 * configured with a rate, and suspended again at rate 0. Nothing runs when nothing is on.
 */
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/pm/device_runtime.h>

#include "g2_touch.h"
#include "wisp_hal.h"
#include "wisp_native.h"

#define BATCH_MAX 32

static const struct device *const imu = DEVICE_DT_GET(DT_NODELABEL(imu));
static const struct device *const als = DEVICE_DT_GET(DT_NODELABEL(als));
static const struct device *const touch = DEVICE_DT_GET(DT_NODELABEL(touch));

struct stream {
	wisp_sensor_cb cb;
	void *ctx;
	uint16_t rate_hz, batch, n;
	struct wisp_sensor_sample buf[BATCH_MAX];
};

static struct stream streams[WISP_SENSOR_COUNT];
static bool imu_held;
static struct k_work_delayable als_work;
static const struct sensor_trigger drdy = {.type = SENSOR_TRIG_DATA_READY, .chan = SENSOR_CHAN_ALL};

static void push(enum wisp_sensor s, uint64_t t, int32_t a, int32_t b, int32_t c)
{
	struct stream *st = &streams[s];

	if (!st->cb) {
		return;
	}
	st->buf[st->n++] = (struct wisp_sensor_sample){.t_ms = t, .v = {a, b, c}};
	if (st->n >= st->batch) {
		st->cb(s, st->buf, st->n, st->ctx);
		st->n = 0;
	}
}

static int32_t milli(const struct sensor_value *v)
{
	return (int32_t)(sensor_value_to_milli(v));
}

static int32_t mdps(const struct sensor_value *v)
{
	return (int32_t)((int64_t)milli(v) * 57296 / 1000);
}

static void imu_ready(const struct device *dev, const struct sensor_trigger *trig)
{
	struct sensor_value a[3], g[3];
	uint64_t t = (uint64_t)k_uptime_get();

	ARG_UNUSED(trig);
	if (sensor_sample_fetch(dev)) {
		return;
	}
	if (streams[WISP_SENSOR_ACCEL].rate_hz &&
	    sensor_channel_get(dev, SENSOR_CHAN_ACCEL_XYZ, a) == 0) {
		/* m/s² -> mg */
		push(WISP_SENSOR_ACCEL, t, milli(&a[0]) * 1000 / 9807, milli(&a[1]) * 1000 / 9807,
		     milli(&a[2]) * 1000 / 9807);
	}
	if (streams[WISP_SENSOR_GYRO].rate_hz &&
	    sensor_channel_get(dev, SENSOR_CHAN_GYRO_XYZ, g) == 0) {
		/* mrad/s -> mdps */
		push(WISP_SENSOR_GYRO, t, mdps(&g[0]), mdps(&g[1]), mdps(&g[2]));
	}
}

static int imu_apply(void)
{
	bool want = streams[WISP_SENSOR_ACCEL].rate_hz || streams[WISP_SENSOR_GYRO].rate_hz;
	struct sensor_value v;
	int err = 0;

	if (want && !imu_held) {
		err = pm_device_runtime_get(imu);
		if (err) {
			return WISP_HAL_EIO;
		}
		imu_held = true;
	}
	if (imu_held) {
		v = (struct sensor_value){.val1 = streams[WISP_SENSOR_ACCEL].rate_hz};
		err = sensor_attr_set(imu, SENSOR_CHAN_ACCEL_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &v);
		v = (struct sensor_value){.val1 = streams[WISP_SENSOR_GYRO].rate_hz};
		err = err ? err
			  : sensor_attr_set(imu, SENSOR_CHAN_GYRO_XYZ,
					    SENSOR_ATTR_SAMPLING_FREQUENCY, &v);
		err = err ? err : sensor_trigger_set(imu, &drdy, want ? imu_ready : NULL);
	}
	if (!want && imu_held) {
		imu_held = false;
		(void)pm_device_runtime_put(imu);
	}
	return err ? WISP_HAL_EIO : 0;
}

static void als_sample(struct k_work *work)
{
	struct stream *st = &streams[WISP_SENSOR_LIGHT];
	struct sensor_value lux;

	ARG_UNUSED(work);
	if (!st->rate_hz) {
		return;
	}
	if (pm_device_runtime_get(als) == 0) {
		if (sensor_sample_fetch(als) == 0 &&
		    sensor_channel_get(als, SENSOR_CHAN_LIGHT, &lux) == 0) {
			push(WISP_SENSOR_LIGHT, (uint64_t)k_uptime_get(),
			     lux.val1 * 100 + lux.val2 / 10000, 0, 0);
		}
		(void)pm_device_runtime_put(als);
	}
	k_work_reschedule(&als_work, K_MSEC(1000 / st->rate_hz));
}

/* From input.c, for every report that carries a proximity change. */
void wisp_native_wear(uint8_t g2_wear, uint64_t t_ms)
{
	push(WISP_SENSOR_WEAR, t_ms, g2_wear == G2_WEAR_ON ? 1 : 0, 0, 0);
}

int wisp_native_sensors_init(void)
{
	k_work_init_delayable(&als_work, als_sample);
	return 0;
}

uint32_t wisp_hal_sensors_present(void)
{
	uint32_t m = 0;

	if (device_is_ready(imu)) {
		m |= BIT(WISP_SENSOR_ACCEL) | BIT(WISP_SENSOR_GYRO);
	}
	if (device_is_ready(als)) {
		m |= BIT(WISP_SENSOR_LIGHT);
	}
	if (device_is_ready(touch)) {
		m |= BIT(WISP_SENSOR_WEAR);
	}
	return m;
}

int wisp_hal_sensor_configure(enum wisp_sensor s, uint16_t rate_hz, uint16_t batch, wisp_sensor_cb cb,
			      void *ctx)
{
	struct stream *st;

	if (s >= WISP_SENSOR_COUNT || !(wisp_hal_sensors_present() & BIT(s))) {
		return WISP_HAL_ENOTSUP;
	}
	st = &streams[s];
	st->cb = rate_hz ? cb : NULL;
	st->ctx = ctx;
	st->rate_hz = rate_hz;
	st->batch = CLAMP(batch, 1, BATCH_MAX);
	st->n = 0;
	switch (s) {
	case WISP_SENSOR_ACCEL:
	case WISP_SENSOR_GYRO:
		return imu_apply();
	case WISP_SENSOR_LIGHT:
		/* The ALS has no interrupt; at most 5 Hz (100 ms integration + margin). */
		st->rate_hz = MIN(rate_hz, 5);
		if (st->rate_hz) {
			k_work_reschedule(&als_work, K_NO_WAIT);
		} else {
			k_work_cancel_delayable(&als_work);
		}
		return 0;
	case WISP_SENSOR_WEAR:
		/* Event-driven: delivered whenever the touch controller reports a change; deliver
		 * the current state at once. */
		if (st->cb && g2_touch_wear(touch) != G2_WEAR_NO_CHANGE) {
			wisp_native_wear(g2_touch_wear(touch), (uint64_t)k_uptime_get());
		}
		return 0;
	default:
		return WISP_HAL_ENOTSUP;
	}
}
