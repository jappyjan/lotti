/*
 * SPDX-License-Identifier: MIT
 *
 * Native power HAL on the nPM1300 (docs/wisp/hardware.md "Power") and the two watchdogs.
 *
 * PMIC watchdog (rung4.md G27): stock arms the nPM1300 timer as a 30.72 s reset watchdog and
 * kicks it every second; the PMIC keeps running across an Apollo reset, so the timer is still
 * armed when Wisp starts after stock or after a loader session. Wisp keeps it armed with stock's
 * exact writes (07 05 0A, 07 08 00 3C 00, 07 03 01, 07 00 01, docs/wisp/recovery.md "The temple's
 * watchdog"; W21 read CONFIG 0x0a and target 00 3c 00 on the left temple) and kicks it every second
 * (07 04 01), as stock does. Its power cycle is the one reset
 * that also clears the Apollo state a software reset keeps, and a hang that stops the kicks ends
 * in the patched loader's boot window after 30.72 s.
 *
 * Apollo watchdog (G7): Wisp Boot arms and locks it (8 s, reset); the app restarts it with a raw
 * RSTRT write, once at PRE_KERNEL_1 and then every second, from the same thread as the PMIC kick.
 * The thread is the highest-priority cooperative thread, started at POST_KERNEL init (before the
 * drivers and long before bt_enable(), whose EM9305 bring-up blocks main for up to 5 s). It feeds
 * unconditionally: native-0 catches scheduler- and interrupt-level hangs, not a stuck main or
 * link thread (a liveness check comes with R4-8). With no Wisp Boot in front (sim,
 * driver test) the WDT is off and the RSTRT write does nothing.
 *
 * Two PMIC modes, chosen by the devicetree:
 *  - drivers (the pmic node enabled; development and driver-test builds): Zephyr's MFD, regulator
 *    and charger drivers own the PMIC; the battery comes from the charger driver.
 *  - observe (the pmic node disabled; hardware images until W21's register snapshot, rung4.md
 *    G12): no Zephyr PMIC driver runs, so nothing writes the rails, the charger, the SHIP/LPRESET
 *    or GPIO configuration. The only PMIC writes are the watchdog's above and the ADC task that
 *    starts one battery-voltage conversion (05 00 01); everything else is a read.
 *
 * Battery percent is a coarse voltage estimate; stock uses Nordic's closed nrf_fuel_gauge.
 */
#include <string.h>

#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/sys_io.h>

#include "wisp_hal.h"
#include "wisp_native.h"

#define PMIC_DRIVERS DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(charger))
#if PMIC_DRIVERS
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/sensor/npm13xx_charger.h>
#endif

LOG_MODULE_REGISTER(wisp_power, CONFIG_LOG_DEFAULT_LEVEL);

/* The PMIC on I2C7, used directly (also when its Zephyr node is disabled). */
static const struct i2c_dt_spec pmic = I2C_DT_SPEC_GET(DT_NODELABEL(pmic));

/* nPM1300 registers: base, offset (16-bit address sent high byte first). */
#define NPM_TIMER_BASE        0x07u
#define NPM_TIMER_EN          0x00u
#define NPM_TIMER_STROBE      0x03u
#define NPM_TIMER_KICK        0x04u
#define NPM_TIMER_CONFIG      0x05u
#define NPM_TIMER_TARGET_HI   0x08u
#define NPM_ADC_BASE          0x05u
#define NPM_ADC_TASK_VBAT     0x00u
#define NPM_ADC_RESULTS       0x10u
#define NPM_CHGR_BASE         0x03u
#define NPM_CHGR_STATUS       0x34u
#define NPM_VBUS_BASE         0x02u
#define NPM_VBUS_STATUS       0x07u

/* Apollo510 WDT restart register and key (hal_ambiq apollo510.h, am_hal_wdt.c). */
#define APOLLO_WDT_RSTRT 0x40024004u
#define APOLLO_WDT_KEY   0xB2u

static int pmic_write(uint8_t base, uint8_t off, const uint8_t *data, size_t n)
{
	uint8_t buf[2 + 3];

	if (n > 3) {
		return -EINVAL;
	}
	buf[0] = base;
	buf[1] = off;
	memcpy(buf + 2, data, n);
	return i2c_write_dt(&pmic, buf, 2 + n);
}

static __maybe_unused int pmic_read(uint8_t base, uint8_t off, uint8_t *data, size_t n)
{
	const uint8_t addr[2] = {base, off};

	return i2c_write_read_dt(&pmic, addr, sizeof(addr), data, n);
}

/* ---- watchdogs ---------------------------------------------------------------------------- */

static struct wisp_watchdog_stats wdt_stats;

static void apollo_wdt_feed(void)
{
	sys_write32(APOLLO_WDT_KEY, APOLLO_WDT_RSTRT);
}

static int pmic_kick(void)
{
	int err = pmic_write(NPM_TIMER_BASE, NPM_TIMER_KICK, (const uint8_t[]){1}, 1);

	wdt_stats.pmic_last = (int8_t)err;
	if (err) {
		wdt_stats.pmic_errors++;
	} else {
		wdt_stats.pmic_kicks++;
	}
	return err;
}

/* Stock 2.4.0.24's own arming sequence, byte for byte (seen in Renode, recovery.md). */
static int pmic_wdt_arm(void)
{
	int err = pmic_kick();

	err = err ? err : pmic_write(NPM_TIMER_BASE, NPM_TIMER_CONFIG, (const uint8_t[]){0x0A}, 1);
	err = err ? err : pmic_write(NPM_TIMER_BASE, NPM_TIMER_TARGET_HI, (const uint8_t[]){0x00, 0x3C, 0x00}, 3);
	err = err ? err : pmic_write(NPM_TIMER_BASE, NPM_TIMER_STROBE, (const uint8_t[]){1}, 1);
	err = err ? err : pmic_write(NPM_TIMER_BASE, NPM_TIMER_EN, (const uint8_t[]){1}, 1);
	wdt_stats.pmic_armed = err == 0;
	return err;
}

static void watchdog_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	bool tried = false;

	/* Started from POST_KERNEL init, possibly before I2C7's driver: arm (stock's sequence)
	 * once the bus is ready, kick every second after that. */
	for (;;) {
		apollo_wdt_feed();
		wdt_stats.apollo_feeds++;
		if (device_is_ready(pmic.bus)) {
			if (!tried) {
				tried = true;
				if (pmic_wdt_arm()) {
					LOG_ERR("PMIC watchdog arm failed (%d)", wdt_stats.pmic_last);
				}
			} else {
				(void)pmic_kick();
			}
		}
		k_sleep(K_MSEC(tried ? 1000 : 10));
	}
}

K_THREAD_STACK_DEFINE(watchdog_stack, 1024);
static struct k_thread watchdog_tcb;

void wisp_native_watchdogs_start(void)
{
	static bool started;

	if (started) {
		return;
	}
	started = true;
	k_thread_create(&watchdog_tcb, watchdog_stack, K_THREAD_STACK_SIZEOF(watchdog_stack),
			watchdog_thread, NULL, NULL, NULL, K_HIGHEST_THREAD_PRIO, 0, K_NO_WAIT);
	k_thread_name_set(&watchdog_tcb, "wisp_wdt");
}

const struct wisp_watchdog_stats *wisp_native_watchdog_stats(void)
{
	return &wdt_stats;
}

/* Restart Wisp Boot's 8 s watchdog before the kernel and the drivers come up, and start the
 * watchdog thread as soon as threads exist (POST_KERNEL), not only in main(): a slow driver init
 * must not starve the feed. */
static int early_feed(void)
{
	apollo_wdt_feed();
	return 0;
}
SYS_INIT(early_feed, PRE_KERNEL_1, 0);

static int early_watchdogs(void)
{
	wisp_native_watchdogs_start();
	return 0;
}
SYS_INIT(early_watchdogs, POST_KERNEL, 0);

/* ---- battery ------------------------------------------------------------------------------ */

int wisp_native_power_init(void)
{
	wisp_native_watchdogs_start();
	if (!device_is_ready(pmic.bus)) {
		LOG_ERR("I2C7 not ready: no PMIC");
		return WISP_HAL_EIO;
	}
	return 0;
}

/* Voltage -> percent for a 4.45 V LiPo (stock's VTERM), resting, coarse [I]. */
static uint8_t percent(uint16_t mv)
{
	static const uint16_t curve[][2] = {{3400, 0}, {3600, 5}, {3700, 15}, {3800, 35},
					    {3900, 50}, {4000, 62}, {4100, 74}, {4200, 84},
					    {4300, 92}, {4400, 98}, {4450, 100}};

	if (mv <= curve[0][0]) {
		return 0;
	}
	for (size_t i = 1; i < ARRAY_SIZE(curve); i++) {
		if (mv <= curve[i][0]) {
			uint32_t span = curve[i][0] - curve[i - 1][0];

			return (uint8_t)(curve[i - 1][1] +
					 (curve[i][1] - curve[i - 1][1]) * (mv - curve[i - 1][0]) / span);
		}
	}
	return 100;
}

#if PMIC_DRIVERS
static const struct device *const charger = DEVICE_DT_GET(DT_NODELABEL(charger));

static int battery_read(uint16_t *mv, uint8_t *chg_status, uint8_t *vbus_status)
{
	struct sensor_value v, status, vbus;

	if (!device_is_ready(charger) || sensor_sample_fetch(charger)) {
		return WISP_HAL_EIO;
	}
	if (sensor_channel_get(charger, SENSOR_CHAN_GAUGE_VOLTAGE, &v) ||
	    sensor_channel_get(charger, (enum sensor_channel)SENSOR_CHAN_NPM13XX_CHARGER_STATUS,
			       &status) ||
	    sensor_channel_get(charger, (enum sensor_channel)SENSOR_CHAN_NPM13XX_CHARGER_VBUS_STATUS,
			       &vbus)) {
		return WISP_HAL_EIO;
	}
	*mv = (uint16_t)(v.val1 * 1000 + v.val2 / 1000);
	*chg_status = (uint8_t)status.val1;
	*vbus_status = (uint8_t)vbus.val1;
	return 0;
}
#else
/* Observe mode: one VBAT conversion (the ADC task, no configuration), then reads only. */
static int battery_read(uint16_t *mv, uint8_t *chg_status, uint8_t *vbus_status)
{
	static K_MUTEX_DEFINE(adc_lock);
	uint8_t r[6];
	int err;

	if (!device_is_ready(pmic.bus)) {
		return WISP_HAL_EIO;
	}
	k_mutex_lock(&adc_lock, K_FOREVER);
	err = pmic_write(NPM_ADC_BASE, NPM_ADC_TASK_VBAT, (const uint8_t[]){1}, 1);
	if (!err) {
		k_sleep(K_MSEC(2)); /* one conversion takes 250 us (PS) */
		/* RESULTS: IBATSTAT, VBAT MSB, NTC MSB, DIE MSB, VSYS MSB, LSBs A (VBAT bits 1:0). */
		err = pmic_read(NPM_ADC_BASE, NPM_ADC_RESULTS, r, sizeof(r));
	}
	k_mutex_unlock(&adc_lock);
	err = err ? err : pmic_read(NPM_CHGR_BASE, NPM_CHGR_STATUS, chg_status, 1);
	err = err ? err : pmic_read(NPM_VBUS_BASE, NPM_VBUS_STATUS, vbus_status, 1);
	if (err) {
		return WISP_HAL_EIO;
	}
	*mv = (uint16_t)((((uint32_t)r[1] << 2) | (r[5] & 0x3u)) * 5000u / 1024u);
	return 0;
}
#endif

int wisp_native_battery_raw(uint16_t *mv, uint8_t *chg_status, uint8_t *vbus_status)
{
	return battery_read(mv, chg_status, vbus_status);
}

int wisp_hal_battery(struct wisp_battery *out)
{
	uint8_t status, vbus;
	int err = battery_read(&out->mv, &status, &vbus);

	if (err) {
		return err;
	}
	out->percent = percent(out->mv);
	/* CHARGER STATUS bits 2..4: trickle, constant current, constant voltage (nPM1300 PS). */
	out->charging = (status & 0x1C) != 0;
	/* VBUS STATUS bit 0: VBUS present (nPM1300 PS). */
	out->in_case = (vbus & 0x01) != 0;
	return 0;
}

uint64_t wisp_hal_uptime_ms(void)
{
	return (uint64_t)k_uptime_get();
}

void wisp_hal_watchdog_feed(void)
{
	/* Both watchdogs are fed by the watchdog thread above (rung4.md G7, G27). */
}

void wisp_hal_reset(void)
{
	sys_reboot(SYS_REBOOT_COLD);
}
