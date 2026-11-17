/*
 * SPDX-License-Identifier: MIT
 *
 * The app's diagnostics on wisp_g2 (rung4.md, "Diagnostics the next image must carry"):
 *
 *  D3  k_sys_fatal_error_handler: the fault (stacked PC, LR, xPSR; CFSR, HFSR, BFAR, MMFAR) goes
 *      into Wisp Boot's record, cleaned from the D-cache, then an SWPOR at once. A fault shows as
 *      a short reboot loop with its PC in the next boot report; only a hang waits for the WDT.
 *  D4  breadcrumbs: SYS_INIT hooks at the start and end of each init level (and between the bus
 *      controllers and the devices on them), plus marks from main, the PMIC thread, the case UART
 *      and the BLE side. Last value wins.
 *  D5  STIMER liveness at the end of PRE_KERNEL_2: the counter must move within a bounded
 *      busy loop. If it does not, the kernel would sleep for ever on its first k_sleep(): instead
 *      the record says so and a fallback loop answers BOOTREP, IDENT and READ on the case UART
 *      itself (Wisp Boot's polled driver), so the temple stays observable. It kicks the nPM1300
 *      watchdog with Wisp Boot's polled IOM7 kick (boot_pmic.c, reviewed and pinned with stage-0;
 *      I2C7's driver has not started yet) every KICK_POLLS polls, and feeds the Apollo WDT only
 *      while those kicks succeed: a failed kick stops the feed, the WDT resets, and Wisp Boot
 *      kicks again (review F1 of PR #87: never feed the Apollo while the PMIC goes unkicked).
 *
 * The record lives in Wisp Boot's RAM (0x20370000, outside the app's RAM; check_image.py keeps the
 * app below it). It is valid only if Wisp Boot started it this boot; without Wisp Boot every mark
 * is a no-op.
 */
#include <string.h>

#include <zephyr/arch/cpu.h>
#include <zephyr/fatal.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>

#include "app_status.h"
#include "app_version.h"
#include "boot_link.h"
#include "boot_pmic.h"
#include "boot_uart.h"
#include "wisp_app_diag.h"
#include "wisp_boot_status.h"
#include "wisp_case_proto.h"

#define WDT_RSTRT 0x40024004u
#define WDT_KEY   0xB2u
#define RSTGEN_SWPOR 0x40000008u
#define SWPOR_KEY    0xD4u

/* Set once a mark names why this boot will end (the feed stopped): later progress marks must not
 * overwrite it, or the next boot's report would show the last progress, not the reason. */
static bool sticky;

void wisp_app_diag_mark(uint16_t stage)
{
	unsigned int key = irq_lock();

	if (!sticky || stage == WISP_DIAG_APP_FAULT || stage == WISP_DIAG_APP_RESET_REQ) {
		wisp_diag_mark(stage); /* seals and cleans the record's lines */
		sticky = sticky || stage == WISP_DIAG_APP_WDT_STARVED;
	}
	irq_unlock(key);
}

const uint8_t *wisp_app_diag_record(void)
{
	static struct wisp_diag_record copy;

	memcpy(&copy, (const void *)wisp_diag(), sizeof(copy));
	return (const uint8_t *)&copy;
}

/* ---- D3 ----------------------------------------------------------------------------------- */

FUNC_NORETURN void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
	uint32_t frame[8] = {0};

	ARG_UNUSED(reason);
	(void)arch_irq_lock();
	if (esf) {
		frame[5] = esf->basic.lr;
		frame[6] = esf->basic.pc;
		frame[7] = esf->basic.xpsr;
	}
	wisp_diag_fault(esf ? frame : NULL, 0, WISP_DIAG_APP_FAULT); /* seals and cleans */
	sys_write32(SWPOR_KEY, RSTGEN_SWPOR);
	for (;;) {
	}
}

/* ---- D4: the init levels -------------------------------------------------------------------- */

#define MARK_AT(name, level, prio, stage)                                                          \
	static int name(void)                                                                      \
	{                                                                                          \
		wisp_app_diag_mark(stage);                                                         \
		return 0;                                                                          \
	}                                                                                          \
	SYS_INIT(name, level, prio)

MARK_AT(mark_pre1, PRE_KERNEL_1, 0, WISP_DIAG_APP_PRE1);
MARK_AT(mark_pre1_end, PRE_KERNEL_1, 99, WISP_DIAG_APP_PRE1_END);
MARK_AT(mark_pre2, PRE_KERNEL_2, 0, WISP_DIAG_APP_PRE2);
MARK_AT(mark_post, POST_KERNEL, 0, WISP_DIAG_APP_POST);
/* After the bus controllers (I2C 50, SPI 70, MSPI 72 by default), before Wisp's drivers (80). */
MARK_AT(mark_post_buses, POST_KERNEL, 75, WISP_DIAG_APP_POST_BUSES);
MARK_AT(mark_post_end, POST_KERNEL, 99, WISP_DIAG_APP_POST_END);

/* ---- D5 ----------------------------------------------------------------------------------- */

/* About 2-20 ms at the hand-off clocks; the crystal ticks every 30.5 us. */
#define STIMER_POLLS 200000u
/* The fallback loop's polls between PMIC kicks: a poll is a few tens of cycles, so this is well
 * under a second at the hand-off's 96 MHz and under 10 s even at a few MHz, against the PMIC
 * watchdog's 30.72 s. */
#define KICK_POLLS 1000000u

static void wdt_feed(void)
{
	sys_write32(WDT_KEY, WDT_RSTRT);
}

static void fallback_status(void *ctx, struct wisp_case_status *s)
{
	ARG_UNUSED(ctx);
	s->stage = wisp_app_status.stage;
	s->bt_result = wisp_app_status.bt_result;
	s->image_kind = (uint8_t)CONFIG_WISP_IMAGE_KIND;
	s->reset_cause = wisp_app_status.reset_cause;
	s->flags |= wisp_boot_link_present() ? WISP_CASE_F_BOOT_SVC : 0;
	s->flags |= wisp_boot_link_status() ? WISP_CASE_F_BOOT_STATUS : 0;
}

static int fallback_report(void *ctx, uint8_t *out)
{
	const struct wisp_boot_status *b = wisp_boot_link_status();

	ARG_UNUSED(ctx);
	if (!b) {
		return 1;
	}
	wisp_boot_report_fill(out, WISP_REPORT_SRC_APP, b);
	return 0;
}

static const uint8_t *fallback_extra(void *ctx, uint8_t block, size_t offset, size_t *len)
{
	ARG_UNUSED(ctx);
	ARG_UNUSED(offset);
	if (block != 4) {
		*len = 0;
		return NULL;
	}
	*len = sizeof(struct wisp_diag_record);
	return wisp_app_diag_record();
}

/* The kernel cannot sleep without the STIMER: stay here, fed and observable, until the case
 * resets the temple (or a case-UART RESET). Polled, interrupts locked. */
static FUNC_NORETURN void stimer_dead(void)
{
	static struct wisp_case_rx rx;
	static uint8_t out[WISP_CASE_MAX_FRAME];
	static const struct wisp_case_ops ops = {.status = fallback_status,
						 .boot_report = fallback_report,
						 .extra_block = fallback_extra};
	const struct wisp_case_version ver = {.image_kind = (uint8_t)CONFIG_WISP_IMAGE_KIND};

	bool kick_ok = boot_pmic_kick() == 0;

	(void)arch_irq_lock();
	wisp_app_diag_mark(WISP_DIAG_APP_STIMER_DEAD);
	(void)boot_uart_init();
	wisp_case_rx_init(&rx);
	for (uint32_t idle = 0, polls = 0;; idle++, polls++) {
		int ch = boot_uart_getc();
		bool reset = false;

		if (polls >= KICK_POLLS) {
			polls = 0;
			kick_ok = kick_ok && boot_pmic_kick() == 0;
		}
		if (kick_ok) {
			wdt_feed();
		}
		if (ch == -2 || (ch == -1 && rx.len && idle > 400000u)) {
			wisp_case_rx_init(&rx); /* an error, or a request cut by a long gap */
		}
		if (ch < 0) {
			continue;
		}
		idle = 0;
		size_t n = wisp_case_rx_byte(&rx, (uint8_t)ch, &ver, &ops, out, &reset);

		if (n) {
			boot_uart_write(out, (uint32_t)n);
		}
		if (reset) {
			wisp_app_diag_mark(WISP_DIAG_APP_RESET_REQ);
			sys_write32(SWPOR_KEY, RSTGEN_SWPOR);
		}
	}
}

static int stimer_check(void)
{
	uint32_t t0 = wisp_stimer_now();

	for (uint32_t i = 0; i < STIMER_POLLS; i++) {
		if (wisp_stimer_now() != t0) {
			wisp_app_diag_mark(WISP_DIAG_APP_STIMER_OK);
			return 0;
		}
	}
	stimer_dead();
}
/* Last in PRE_KERNEL_2, after the system timer's own init. */
SYS_INIT(stimer_check, PRE_KERNEL_2, 99);
