/*
 * SPDX-License-Identifier: MIT
 *
 * Native power HAL on the nPM1300 (docs/wisp/hardware.md "Power").
 *
 * PMIC watchdog: stock arms the nPM1300 timer as a 30.72 s reset watchdog and kicks it every
 * second. The PMIC keeps running across an Apollo reset, so after stock (or a Wisp image staged
 * by stock's OTA) the timer may still be armed when Wisp starts. Wisp kicks it once at boot and
 * then stops it: hangs are Wisp Boot's watchdog's job (Apollo WDT), and a PMIC timer nobody
 * feeds would power-cycle the temple every 30 s.
 *
 * Battery: voltage, current and charger status from the nPM1300 charger driver; the case is
 * VBUS (stock has no other case-detect line). Percent is a coarse voltage estimate; stock uses
 * Nordic's closed nrf_fuel_gauge, which Wisp does not link.
 */
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/sensor/npm13xx_charger.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/reboot.h>

#include "wisp_hal.h"
#include "wisp_native.h"

LOG_MODULE_REGISTER(wisp_power, CONFIG_LOG_DEFAULT_LEVEL);

static const struct device *const charger = DEVICE_DT_GET(DT_NODELABEL(charger));
static const struct device *const pmic_wdt = DEVICE_DT_GET(DT_NODELABEL(pmic_wdt));

int wisp_native_power_init(void)
{
	if (!device_is_ready(pmic_wdt)) {
		LOG_ERR("PMIC not ready: its watchdog may still be armed");
		return WISP_HAL_EIO;
	}
	(void)wdt_feed(pmic_wdt, 0);
	if (wdt_disable(pmic_wdt)) {
		LOG_ERR("PMIC watchdog stop failed");
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

int wisp_hal_battery(struct wisp_battery *out)
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
	out->mv = (uint16_t)(v.val1 * 1000 + v.val2 / 1000);
	out->percent = percent(out->mv);
	/* CHARGER STATUS bits 2..4: trickle, constant current, constant voltage (nPM1300 PS). */
	out->charging = (status.val1 & 0x1C) != 0;
	/* VBUS STATUS bit 0: VBUS present (nPM1300 PS). */
	out->in_case = (vbus.val1 & 0x01) != 0;
	return 0;
}

uint64_t wisp_hal_uptime_ms(void)
{
	return (uint64_t)k_uptime_get();
}

void wisp_hal_watchdog_feed(void)
{
	/* The Apollo WDT is armed and locked by Wisp Boot; feeding it comes with the services
	 * table (src/boot/stage/boot_services.h) when the app runs behind Wisp Boot. */
}

void wisp_hal_reset(void)
{
	sys_reboot(SYS_REBOOT_COLD);
}
