/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp native firmware: banner, native HAL bring-up, heartbeat on the debug UART.
 *
 * The drivers start suspended (panel unpowered, IMU rail off, ALS shut down); nothing is powered
 * until the core asks for it. Wisp Boot (src/boot/) is not wired in yet; the image entry is
 * Zephyr's reset vector at 0x438000.
 *
 * CONFIG_WISP_DRIVER_SELFTEST (scripts/drivers_test.sh only): after bring-up, compose test frames
 * with wisp-core's compositor, send them through the flush path to the panel, read each sensor
 * once and service one touch report, then print "selftest: done". The Renode panel and I2C models
 * record what reached the buses, and tests/drivers/check_drivers.py checks it.
 */

#include <stdint.h>

#include <zephyr/kernel.h>
#include <zephyr/linker/linker-defs.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>

#include "app_version.h"
#include "wisp_hal.h"
#include "wisp_native.h"

#if defined(CONFIG_WISP_DRIVER_SELFTEST)
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/pm/device_runtime.h>

#include "g2_touch.h"
#include "uled.h"
#include "wisp_flush.h"
#if !defined(WISP_WITH_CORE)
#error "the driver self-test composes with wisp-core: build with -DWISP_WITH_CORE=ON"
#endif
#include <wisp/display.h>
#endif

#ifndef WISP_FW_GIT_REV
#define WISP_FW_GIT_REV "unknown"
#endif

static void bring_up(void)
{
	static const struct {
		const char *name;
		int (*init)(void);
	} parts[] = {
		{"power", wisp_native_power_init},
		{"display", wisp_native_display_init},
		{"input", wisp_native_input_init},
		{"sensors", wisp_native_sensors_init},
	};

	for (size_t i = 0; i < ARRAY_SIZE(parts); i++) {
		int err = parts[i].init();

		printk("wisp: hal %s %s (%d)\n", parts[i].name, err ? "FAILED" : "ok", err);
	}
	printk("wisp: sensors present 0x%02x\n", wisp_hal_sensors_present());
}

#if defined(CONFIG_WISP_DRIVER_SELFTEST)

#define ST_GFX_BYTES (WISP_DISPLAY_STRIDE * WISP_DISPLAY_HEIGHT + 32u * 64u + 4096u)

static uint8_t st_gfx[ST_GFX_BYTES] __aligned(8);
static uint8_t st_tables[24 * 1024] __aligned(8);

static int fill(wisp_display *d, uint8_t layer, uint8_t v, int32_t x, int32_t y, int32_t w, int32_t h)
{
	return wisp_display_fill(d, layer, v, x, y, w, h);
}

static void selftest_display(void)
{
	static wisp_pool pool;
	static wisp_display d;
	const struct wisp_flush *fl = wisp_native_flush();
	size_t mem = wisp_display_mem(640, 480, 4, 16);
	int err;

	if (mem > sizeof(st_tables)) {
		printk("selftest: display tables need %u bytes\n", (unsigned)mem);
		return;
	}
	wisp_pool_init(&pool, st_gfx, sizeof(st_gfx));
	wisp_display_init(&d, st_tables, 640, 480, 4, 16, &pool, wisp_native_present, NULL);

	err = wisp_hal_display_power(true);
	printk("selftest: display power on (%d)\n", err);
	if (err) {
		return;
	}

	/* Frame 1: layer 0 = 16 vertical bands of 40 px, values 0..15; layer 1 = a 64x32 box of 15
	 * at (100, 200) on top. */
	wisp_display_layer_set_req_t bg = {.layer = 0, .z = 0, .flags = 1, .alpha = 15,
					   .w = 640, .h = 480};
	wisp_display_layer_set_req_t box = {.layer = 1, .z = 1, .flags = 1, .alpha = 15,
					    .x = 100, .y = 200, .w = 64, .h = 32};
	err = wisp_display_layer_set(&d, &bg);
	err = err ? err : wisp_display_layer_set(&d, &box);
	for (int b = 0; b < 16 && !err; b++) {
		err = fill(&d, 0, (uint8_t)b, b * 40, 0, 40, 480);
	}
	err = err ? err : fill(&d, 1, 15, 0, 0, 64, 32);
	wisp_display_commit(&d);
	wisp_native_frame_done(NULL, 1);
	printk("selftest: frame 1 composed (%d), flush frames %u writes %u rows %u\n", err,
	       fl->frames, fl->writes, fl->rows_sent);

	/* Frame 2: the box turns to 7 -> only rows 200..231 change: one partial update. */
	err = fill(&d, 1, 7, 0, 0, 64, 32);
	wisp_display_commit(&d);
	wisp_native_frame_done(NULL, 2);
	printk("selftest: frame 2 composed (%d), flush frames %u writes %u rows %u\n", err,
	       fl->frames, fl->writes, fl->rows_sent);

	err = wisp_hal_display_brightness(255);
	printk("selftest: brightness (%d)\n", err);
	err = uled_check(DEVICE_DT_GET(DT_NODELABEL(uled)));
	printk("selftest: panel health (%d)\n", err);
	err = wisp_hal_display_power(false);
	printk("selftest: display power off (%d)\n", err);
}

static void selftest_sensors(void)
{
	const struct device *imu = DEVICE_DT_GET(DT_NODELABEL(imu));
	const struct device *als = DEVICE_DT_GET(DT_NODELABEL(als));
	const struct device *touch = DEVICE_DT_GET(DT_NODELABEL(touch));
	struct sensor_value v[3];
	int err;

	if (device_is_ready(imu) && pm_device_runtime_get(imu) == 0) {
		struct sensor_value odr = {.val1 = 100};

		err = sensor_attr_set(imu, SENSOR_CHAN_ACCEL_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &odr);
		err = err ? err : sensor_sample_fetch(imu);
		err = err ? err : sensor_channel_get(imu, SENSOR_CHAN_ACCEL_XYZ, v);
		printk("selftest: imu accel %d.%06d %d.%06d %d.%06d m/s2 (%d)\n", v[0].val1,
		       v[0].val2, v[1].val1, v[1].val2, v[2].val1, v[2].val2, err);
		odr.val1 = 0;
		(void)sensor_attr_set(imu, SENSOR_CHAN_ACCEL_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &odr);
		(void)pm_device_runtime_put(imu);
		printk("selftest: imu suspended\n");
	} else {
		printk("selftest: imu not ready\n");
	}
	if (device_is_ready(als) && pm_device_runtime_get(als) == 0) {
		err = sensor_sample_fetch(als);
		err = err ? err : sensor_channel_get(als, SENSOR_CHAN_LIGHT, v);
		printk("selftest: light %d.%02d lux (%d)\n", v[0].val1, v[0].val2 / 10000, err);
		(void)pm_device_runtime_put(als);
	} else {
		printk("selftest: light not ready\n");
	}
	if (device_is_ready(touch)) {
		printk("selftest: touch fw %08x\n", g2_touch_version(touch));
		err = g2_touch_service(touch);
		printk("selftest: touch report (%d) wear %u\n", err, g2_touch_wear(touch));
	} else {
		printk("selftest: touch not ready\n");
	}
	struct wisp_battery bat;

	err = wisp_hal_battery(&bat);
	printk("selftest: battery %u mV %u%% charging %d in_case %d (%d)\n", bat.mv, bat.percent,
	       bat.charging, bat.in_case, err);
}

#endif /* CONFIG_WISP_DRIVER_SELFTEST */

int main(void)
{
	printk("\n*** Wisp native " WISP_FW_VERSION " (" WISP_FW_GIT_REV ") ***\n");
	printk("wisp: board %s, Zephyr %s, image @ %p\n", CONFIG_BOARD, KERNEL_VERSION_STRING,
	       (void *)__rom_region_start);
	printk("wisp: bluetooth off (safety rule 8)\n");
	bring_up();

#if defined(CONFIG_WISP_DRIVER_SELFTEST)
	selftest_display();
	selftest_sensors();
	printk("selftest: done\n");
#endif

	for (uint32_t beat = 1;; beat++) {
		k_msleep(CONFIG_WISP_HEARTBEAT_MS);
		printk("wisp: heartbeat %u uptime %lld ms\n", beat, k_uptime_get());
	}

	return 0;
}
