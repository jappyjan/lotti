/*
 * SPDX-License-Identifier: MIT
 *
 * Case-UART status protocol on UART2 (docs/wisp/case-uart.md): the observation channel when BLE
 * does not come up (rung4.md G10). One low-priority thread polls the receiver every
 * CONFIG_WISP_CASE_UART_POLL_MS and answers complete requests; it never sends anything unasked.
 * A gap of more than 20 ms inside a request drops it. The codec is wisp_case_proto.c.
 */
#include <string.h>

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/sys_io.h>

#include "app_status.h"
#include "app_version.h"
#include "boot_link.h"
#include "wisp_case_proto.h"
#include "wisp_hal.h"
#include "wisp_native.h"

LOG_MODULE_REGISTER(wisp_case, CONFIG_LOG_DEFAULT_LEVEL);

#ifndef WISP_FW_GIT_REV
#define WISP_FW_GIT_REV "unknown"
#endif

#define GAP_MS 20

static const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(uart2));

static void fill_status(void *ctx, struct wisp_case_status *s)
{
	const struct wisp_watchdog_stats *w = wisp_native_watchdog_stats();
	const struct wisp_boot_status *b = wisp_boot_link_status();
	uint8_t chg = 0, vbus = 0;
	uint16_t mv = 0;

	ARG_UNUSED(ctx);
	s->stage = wisp_app_status.stage;
	s->bt_result = wisp_app_status.bt_result;
	s->sensors = wisp_app_status.sensors;
	s->image_kind = (uint8_t)CONFIG_WISP_IMAGE_KIND;
	if (wisp_native_battery_raw(&mv, &chg, &vbus) == 0) {
		s->flags |= WISP_CASE_F_BATTERY;
		s->battery_mv = mv;
		s->charger_status = chg;
		s->vbus_status = vbus;
		/* VBUS STATUS bit 0 = present; CHARGER STATUS bits 2..4 = trickle / CC / CV. */
		s->flags |= (vbus & 0x01) ? WISP_CASE_F_VBUS : 0;
		s->flags |= (chg & 0x1C) ? WISP_CASE_F_CHARGING : 0;
	}
	s->flags |= w->pmic_armed ? WISP_CASE_F_PMIC_WDT : 0;
	s->flags |= wisp_boot_link_present() ? WISP_CASE_F_BOOT_SVC : 0;
	if (b) {
		s->flags |= WISP_CASE_F_BOOT_STATUS;
		s->flags |= (b->build & WISP_BOOT_BUILD_OBSERVE) ? WISP_CASE_F_BOOT_OBSERVE : 0;
		s->boot_block_size = (uint16_t)sizeof(*b);
	}
	s->flags |= wisp_app_status.session_up ? WISP_CASE_F_SESSION : 0;
	s->pmic_last = w->pmic_last;
	s->reset_cause = wisp_app_status.reset_cause;
	s->uptime_ms = (uint32_t)k_uptime_get();
	s->pmic_kicks = w->pmic_kicks;
	s->pmic_errors = w->pmic_errors;
	s->apollo_feeds = w->apollo_feeds;
	s->sessions = wisp_app_status.sessions;
	s->confirm_calls = wisp_app_status.confirm_calls;
	s->confirm_result = wisp_app_status.confirm_result;
	memcpy(s->rev, WISP_FW_GIT_REV, MIN(sizeof(WISP_FW_GIT_REV) - 1, sizeof(s->rev)));
}

/* A copy taken when a READ starts at offset 0, so a dump spanning a confirm() (which reseals
 * the block from another thread) stays one consistent, CRC-correct block. */
static struct wisp_boot_status boot_snapshot;
static bool boot_snapshot_ok;

static const uint8_t *boot_block(void *ctx, size_t offset, size_t *len)
{
	ARG_UNUSED(ctx);
	if (offset == 0 || !boot_snapshot_ok) {
		const struct wisp_boot_status *b = wisp_boot_link_status();

		boot_snapshot_ok = b != NULL;
		if (b) {
			memcpy(&boot_snapshot, b, sizeof(boot_snapshot));
		}
	}
	*len = boot_snapshot_ok ? sizeof(boot_snapshot) : 0;
	return boot_snapshot_ok ? (const uint8_t *)&boot_snapshot : NULL;
}

static void case_thread(void *a, void *b, void *c)
{
	static struct wisp_case_rx rx;
	static uint8_t out[WISP_CASE_MAX_FRAME];
	static const struct wisp_case_ops ops = {.status = fill_status, .boot_block = boot_block};
	/* WISP_FW_VERSION is "major.minor.patch[-tag]" */
	struct wisp_case_version ver = {.image_kind = (uint8_t)CONFIG_WISP_IMAGE_KIND, .hw = 0};
	unsigned int parts[3] = {0};
	int part = 0;
	int64_t last = 0;
	unsigned char ch;

	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);
	for (const char *p = WISP_FW_VERSION; *p && *p != '-'; p++) {
		if (*p == '.') {
			part = part < 2 ? part + 1 : part;
		} else if (*p >= '0' && *p <= '9') {
			parts[part] = parts[part] * 10u + (unsigned int)(*p - '0');
		}
	}
	ver.major = (uint8_t)parts[0];
	ver.minor = (uint8_t)parts[1];
	ver.patch = (uint8_t)parts[2];
	wisp_case_rx_init(&rx);

	for (;;) {
		bool got = false;

		for (;;) {
			int r = uart_poll_in(uart, &ch);
			bool reset = false;
			size_t n;

			if (r < 0) {
				break; /* nothing received */
			}
			got = true;
			if (r > 0) {
				/* A byte with a framing, parity or overrun error. The PL011 latches the
				 * error in RSR until ECR is written, and Zephyr never writes it: clear
				 * it, or every later byte would come back flagged. */
				sys_write32(0, DT_REG_ADDR(DT_NODELABEL(uart2)) + 0x04);
				wisp_case_rx_init(&rx);
				continue;
			}
			if (rx.len && k_uptime_get() - last > GAP_MS) {
				wisp_case_rx_init(&rx);
			}
			last = k_uptime_get();
			n = wisp_case_rx_byte(&rx, ch, &ver, &ops, out, &reset);
			for (size_t i = 0; i < n; i++) {
				uart_poll_out(uart, out[i]);
			}
			if (reset) {
				LOG_INF("reset requested over the case UART");
				k_msleep(50); /* the reply leaves the FIFO */
				sys_reboot(SYS_REBOOT_COLD);
			}
		}
		k_msleep(got ? 0 : CONFIG_WISP_CASE_UART_POLL_MS);
	}
}

K_THREAD_STACK_DEFINE(case_stack, 1536);
static struct k_thread case_tcb;

int wisp_case_start(void)
{
	int err;

	if (!device_is_ready(uart)) {
		LOG_ERR("case UART (UART2) not ready");
		return -ENODEV;
	}
	/* Every device starts runtime-suspended (PM_DEVICE_RUNTIME_DEFAULT_ENABLE): UART2 stays
	 * resumed for good, the receiver must be on to hear a request. */
	err = pm_device_runtime_get(uart);
	if (err < 0) {
		LOG_ERR("case UART resume failed (%d)", err);
		return err;
	}
	k_thread_create(&case_tcb, case_stack, K_THREAD_STACK_SIZEOF(case_stack), case_thread, NULL,
			NULL, NULL, K_LOWEST_APPLICATION_THREAD_PRIO - 1, 0, K_NO_WAIT);
	k_thread_name_set(&case_tcb, "wisp_case");
	return 0;
}
