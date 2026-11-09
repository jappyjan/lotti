/*
 * SPDX-License-Identifier: MIT
 *
 * Case-UART status protocol on UART2 (docs/wisp/case-uart.md): the observation channel when BLE
 * does not come up (rung4.md G10). One low-priority thread polls the receiver every
 * CONFIG_WISP_CASE_UART_POLL_MS and answers complete requests; it never sends anything unasked.
 * A gap of more than 20 ms inside a request drops it. The codec is wisp_case_proto.c.
 *
 * Half duplex (rung4.md W24c): the pogo link is one wire, shared by the temple's pad 42 (TX) and
 * pad 44 (RX). The pinctrl default (boards/even/wisp_g2/wisp_g2-pinctrl.dtsi) parks pad 42 as a
 * GPIO with its output off and puts pad 44 on UART2RX, as stock's UART2 init does. Only a reply
 * turns the wire round, the way stock and drdaeman's loader do: about 6 ms after the request
 * (the loader's wait, so the case has turned its USART to receive), pad 44 parked and pad 42 on
 * UART2TX, the bytes, a bounded wait until the last stop bit is out, then back to receive.
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
#include "wisp_app_diag.h"
#include "wisp_case_proto.h"
#include "wisp_hal.h"
#include "wisp_native.h"

LOG_MODULE_REGISTER(wisp_case, CONFIG_LOG_DEFAULT_LEVEL);

#ifndef WISP_FW_GIT_REV
#define WISP_FW_GIT_REV "unknown"
#endif

#define GAP_MS 20
#define SETTLE_MS 6

static const struct device *const uart = DEVICE_DT_GET(DT_NODELABEL(uart2));

/* Raw pad and UART registers for the turn-round (hal_ambiq apollo510.h). */
#define CASE_UART2 DT_REG_ADDR(DT_NODELABEL(uart2))
#define UART_FR    0x18u
#define UART_FR_BUSY 0x08u
#define UART_FR_TXFE 0x80u
#define GPIO_PINCFG(n) (0x40010000u + 4u * (n))
#define GPIO_PADKEY    0x40010400u
#define PAD_TX 42u
#define PAD_RX 44u
#define PAD_UART   4u /* FNCSEL 4: UART2TX on pad 42, UART2RX on pad 44 (stock, the loader) */
#define PAD_PARKED 3u /* FNCSEL 3 (GPIO), output and input off */

static void pads(uint32_t tx, uint32_t rx)
{
	unsigned int key = irq_lock(); /* PADKEY must not be relocked under us */

	sys_write32(0x73u, GPIO_PADKEY);
	sys_write32(tx, GPIO_PINCFG(PAD_TX));
	sys_write32(rx, GPIO_PINCFG(PAD_RX));
	sys_write32(0, GPIO_PADKEY);
	irq_unlock(key);
}

static void send(const uint8_t *p, size_t n)
{
	k_msleep(SETTLE_MS);
	pads(PAD_UART, PAD_PARKED);
	for (size_t i = 0; i < n; i++) {
		uart_poll_out(uart, p[i]);
	}
	/* 32 bytes take 320 us at 1 Mbaud; the bound is generous and never blocks for long. */
	for (int i = 0; i < 2000; i++) {
		uint32_t fr = sys_read32(CASE_UART2 + UART_FR);

		if (!(fr & UART_FR_BUSY) && (fr & UART_FR_TXFE)) {
			break;
		}
		k_busy_wait(1);
	}
	pads(PAD_PARKED, PAD_UART);
}

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
	s->display = wisp_app_status.display;
	s->display_err = wisp_app_status.display_err;
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

/* BOOTREP from the app (source 1): Wisp Boot's report, for a host that missed its window. */
static int boot_report(void *ctx, uint8_t *out)
{
	const struct wisp_boot_status *b = wisp_boot_link_status();

	ARG_UNUSED(ctx);
	if (!b) {
		return 1;
	}
	wisp_boot_report_fill(out, WISP_REPORT_SRC_APP, b);
	return 0;
}

/* READ block 4: this boot's diagnostics record as it stands (the app's breadcrumbs), as stage-0. */
static const uint8_t *extra_block(void *ctx, uint8_t block, size_t offset, size_t *len)
{
	static uint8_t rec[sizeof(struct wisp_diag_record)];

	ARG_UNUSED(ctx);
	if (block != 4 || !wisp_boot_link_status()) {
		*len = 0;
		return NULL;
	}
	if (offset == 0) {
		memcpy(rec, wisp_app_diag_record(), sizeof(rec));
	}
	*len = sizeof(rec);
	return rec;
}

static void case_thread(void *a, void *b, void *c)
{
	static struct wisp_case_rx rx;
	static uint8_t out[WISP_CASE_MAX_FRAME];
	static const struct wisp_case_ops ops = {.status = fill_status,
						 .boot_block = boot_block,
						 .boot_report = boot_report,
						 .extra_block = extra_block};
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
			if (n) {
				send(out, n);
			}
			if (reset) {
				wisp_app_diag_mark(WISP_DIAG_APP_RESET_REQ);
				k_msleep(50);
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
	wisp_app_diag_mark(WISP_DIAG_APP_CASE);
	return 0;
}
