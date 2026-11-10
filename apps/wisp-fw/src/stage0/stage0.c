/*
 * SPDX-License-Identifier: MIT
 *
 * stage-0c — the smallest app behind Wisp Boot (docs/wisp/rung4.md, "W24 result and analysis", fix
 * plan 1, the W24b runbook, "W24d: stage-0b" and "W24e: stage-0c"). stage-0b is stage-0 (pinned at
 * W24b-0, built from commit 9bfac4d) with the three silicon fixes of W24d, which live in the shared
 * code: the case UART is half duplex (boot_uart.c), the record is cleaned out of the D-cache after
 * each breadcrumb (wisp_diag.h), and its Wisp Boot no longer holds MSPI1 in reset and bounds its NOR
 * phase; here only the start-up's SysTick probe gained a bound (0.2.0). stage-0c (0.3.0) is
 * stage-0b with W24e's Wisp Boot, which powers MSPI1 and ungates its IO clock before the NOR phase
 * and puts both back before the hand-off; this file only changes its version. Bare metal: no Zephyr, no Ambiq HAL start-up, no interrupts. It
 * exists to show on silicon what native-0 could not: that the hand-off from Wisp Boot reaches code
 * at 0x448000, that UART2 and IOM7 work with our own register sequences, and how fast the clocks
 * really run. Everything it does:
 *
 *   - feeds the Apollo510 watchdog (Wisp Boot armed and locked it) about once a second;
 *   - kicks the nPM1300 watchdog once a second (boot_pmic.c: 07 04 01, the only PMIC write);
 *   - answers the case-UART protocol on UART2, polled (docs/wisp/case-uart.md, the same codec as the
 *     Zephyr app): IDENT, READ of its status (block 1), Wisp Boot's status block (2), its clock
 *     measurements (3) and this boot's diagnostics record (4), the boot report (BOOTREP) and RESET;
 *   - measures the LFRC (the watchdog's clock) against the 32 kHz crystal (the STIMER) and the core
 *     clock (SysTick): it times 16 watchdog ticks (1,024 LFRC cycles) without feeding, 2 s after
 *     start and every 15 s after that;
 *   - leaves breadcrumbs in the diagnostics record (wisp_diag.h) and records a fault there before
 *     it resets (SWPOR).
 *
 * It contains no MRAM or NOR write code (check_no_mram_write over [0x448000, end)), touches neither
 * the panel nor the EM9305 nor any other PMIC register, and reconfigures no clock: it only reads
 * STCFG and the watchdog's CFG. RAM: the first 64 KiB of DTCM, clear of Wisp Boot's.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "boot_hw.h"
#include "boot_pmic.h"
#include "boot_services.h"
#include "boot_uart.h"
#include "wisp_boot_layout.h"
#include "wisp_boot_status.h"
#include "wisp_case_proto.h"
#include "wisp_diag.h"

#ifndef STAGE0_REV
#define STAGE0_REV "unknown"
#endif
#define STAGE0_KIND 16u /* image kind in IDENT and the status block (native-0 = 0) */
#define STAGE0_STAGE 6u /* app stage "bare-metal" (case-uart.md status block) */
#define STAGE0_MAJOR 0u
#define STAGE0_MINOR 3u /* 0.1.0 = stage-0 (W24b), 0.2.0 = stage-0b (W24d), 0.3.0 = stage-0c (W24e) */
#define STAGE0_PATCH 0u

#define WDT_COUNT REG(0x4002400Cu)
#define SYST_CSR  REG(0xE000E010u)
#define SYST_RVR  REG(0xE000E014u)
#define SYST_CVR  REG(0xE000E018u)
#define SCB_ICSR  REG(0xE000ED04u)

#define XT_HZ        32768u
#define ASSUMED_CORE 96000000u /* only when the crystal is not running: 96 MHz [I] */
#define SECOND       XT_HZ
#define GAP          (XT_HZ / 50u) /* 20 ms inside a request drops it */
#define MEASURE_FIRST (2u * SECOND)
#define MEASURE_EVERY (15u * SECOND)
#define MEASURE_TICKS 16u /* watchdog ticks per measurement: 16 x 64 = 1,024 LFRC cycles */
#define MEASURE_SETTLE (XT_HZ / 10u) /* after the feed, before the first edge counts */
#define DRAIN_MAX 64u  /* received bytes handled per pass before the watchdogs get their turn */
#define PROBE_POLLS 4000000u /* cap on the start-up's STIMER probe (each poll is several cycles) */

/* ---- time: the STIMER (crystal) if it runs, else SysTick at an assumed clock ---------------- */

static uint64_t cycles;   /* core cycles since start (SysTick, 24 bits, accumulated) */
static uint32_t last_cvr;
static bool xt;           /* the STIMER counts the crystal */
static uint32_t t_start;

static void cycles_update(void)
{
	uint32_t v = SYST_CVR;

	cycles += (last_cvr - v) & 0xFFFFFFu;
	last_cvr = v;
}

/* Ticks at 32768 Hz since start. */
static uint32_t now(void)
{
	cycles_update();
	if (xt) {
		return wisp_stimer_now() - t_start;
	}
	return (uint32_t)(cycles / (ASSUMED_CORE / XT_HZ));
}

/* ---- state ----------------------------------------------------------------------------------- */

static uint32_t reset_cause, feeds, kicks, kick_errors, kick_last;

/* Block 3: the clock measurements (layout in case-uart.md, decoder case_uart.py decode_clock). */
#define CLOCK_VERSION 1u
#define CLOCK_SIZE    52u
static struct {
	uint8_t timebase;      /* 1 = STIMER crystal, 2 = SysTick at an assumed 96 MHz */
	uint8_t count;         /* measurements done (saturating) */
	uint8_t result;        /* last: 0 ok, 1 COUNT never moved, 2 too slow, 3 not yet,
				* 4 implausible (LFRC outside 500-2000 Hz) */
	uint8_t direction;     /* how COUNT moved: 1 down, 2 up, 3 both, 0 not seen (not assumed) */
	uint32_t stcfg;        /* STIMER STCFG as found */
	uint32_t wdt_cfg;      /* the watchdog's CFG (Wisp Boot's, locked) */
	uint32_t stimer_probe; /* STTMR ticks across 2^22 core cycles at start */
	uint32_t xt_ticks;     /* last: STIMER ticks across 1,024 LFRC cycles */
	uint32_t core_cycles;  /* last: core cycles across the same window */
	uint32_t lfrc_mhz;     /* last: LFRC in mHz, taking the crystal as 32768 Hz */
	uint32_t core_hz;      /* last: core clock in Hz, same reference */
	uint32_t wdt_ms;       /* the watchdog's reset period at that LFRC, ms */
	uint32_t lfrc_min, lfrc_max; /* mHz over all measurements */
} clk = {.result = 3};

static uint8_t clock_block[CLOCK_SIZE];

static void clock_encode(void)
{
	uint8_t *b = clock_block;

	memset(b, 0, sizeof(clock_block));
	b[0] = CLOCK_VERSION;
	b[1] = clk.timebase;
	b[2] = clk.count;
	b[3] = clk.result;
	wisp_diag_put32(b + 4, clk.stcfg);
	wisp_diag_put32(b + 8, clk.wdt_cfg);
	wisp_diag_put32(b + 12, clk.stimer_probe);
	wisp_diag_put32(b + 16, clk.xt_ticks);
	wisp_diag_put32(b + 20, clk.core_cycles);
	wisp_diag_put32(b + 24, clk.lfrc_mhz);
	wisp_diag_put32(b + 28, clk.core_hz);
	wisp_diag_put32(b + 32, clk.wdt_ms);
	wisp_diag_put32(b + 36, clk.lfrc_min);
	wisp_diag_put32(b + 40, clk.lfrc_max);
	wisp_diag_put32(b + 44, kick_last);
	b[48] = clk.direction;
}

/* ---- watchdogs ------------------------------------------------------------------------------- */

static void feed(void)
{
	WDT_RSTRT = 0xB2u;
	feeds++;
}

static void kick(void)
{
	kick_last = boot_pmic_kick();
	kicks++;
	kick_errors += kick_last != 0;
}

/* The watchdog's LFRC divider for its CFG.CLKSEL (apollo510.h WDT_CFG_CLKSEL_*), 0 if not LFRC. */
static uint32_t wdt_divider(uint32_t cfg)
{
	switch ((cfg >> 24) & 7u) {
	case 1: return 8u;
	case 2: return 64u;
	case 3: return 1024u;
	case 4: return 16384u;
	default: return 0;
	}
}

/* ---- the LFRC measurement: 16 watchdog ticks, edge to edge, without a feed in between --------- */
/* COUNT may count either way (the header does not say): each change adds the smaller of the two
 * modular distances, so a slow pass that misses a tick still counts it. The PMIC is not kicked
 * during a measurement (at most 3.6 s, against its 30.72 s), so no slow kick sits inside it. The
 * first 100 ms after the feed are not used: the restart may land between ticks. */

static enum { M_IDLE, M_SETTLE, M_SYNC, M_RUN } m_state;
static uint32_t m_next = MEASURE_FIRST, m_deadline, m_t0, m_ticks, m_count;
static uint64_t m_cy0;

static void measure_done(uint8_t result, uint32_t t)
{
	clk.result = result;
	clk.count += clk.count < 255u;
	feed();
	m_state = M_IDLE;
	m_next = t + MEASURE_EVERY;
	wisp_diag_mark(WISP_DIAG_S0_LOOP);
}

static void measure_step(uint32_t t)
{
	uint32_t c;

	switch (m_state) {
	case M_IDLE:
		if ((int32_t)(t - m_next) < 0) {
			return;
		}
		feed(); /* a whole watchdog period (about 9 s) ahead; the window takes about 1.3 s */
		m_deadline = t + MEASURE_SETTLE;
		m_state = M_SETTLE;
		wisp_diag_mark(WISP_DIAG_S0_MEASURE);
		return;
	case M_SETTLE:
		if ((int32_t)(t - m_deadline) >= 0) {
			m_count = WDT_COUNT & 0xFFu;
			m_deadline = t + SECOND / 2u;
			m_state = M_SYNC;
		}
		return;
	case M_SYNC:
		c = WDT_COUNT & 0xFFu;
		if (c != m_count) {
			m_t0 = xt ? wisp_stimer_now() : t;
			m_cy0 = cycles;
			m_count = c;
			m_ticks = 0;
			m_deadline = t + 3u * SECOND;
			m_state = M_RUN;
		} else if ((int32_t)(t - m_deadline) >= 0) {
			measure_done(1, t);
		}
		return;
	case M_RUN:
		c = WDT_COUNT & 0xFFu;
		if (c != m_count) {
			uint32_t down = (m_count - c) & 0xFFu, up = (c - m_count) & 0xFFu;

			clk.direction |= down <= up ? 1u : 2u;
			m_ticks += down <= up ? down : up;
			m_count = c;
			if (m_ticks >= MEASURE_TICKS) {
				uint32_t dt = (xt ? wisp_stimer_now() : t) - m_t0;
				uint64_t lfrc_cycles = (uint64_t)m_ticks * wdt_divider(clk.wdt_cfg);
				uint32_t resval = (clk.wdt_cfg >> 8) & 0xFFu;

				clk.xt_ticks = dt;
				clk.core_cycles = (uint32_t)(cycles - m_cy0);
				clk.lfrc_mhz = dt ? (uint32_t)(lfrc_cycles * XT_HZ * 1000u / dt) : 0;
				clk.core_hz = dt ? (uint32_t)((uint64_t)clk.core_cycles * XT_HZ / dt) : 0;
				clk.wdt_ms = clk.lfrc_mhz ? (uint32_t)((uint64_t)resval * wdt_divider(clk.wdt_cfg) *
								      1000000u / clk.lfrc_mhz)
							  : 0;
				bool plausible = clk.lfrc_mhz >= 500000u && clk.lfrc_mhz <= 2000000u;

				if (plausible && (!clk.lfrc_min || clk.lfrc_mhz < clk.lfrc_min)) {
					clk.lfrc_min = clk.lfrc_mhz;
				}
				if (plausible && clk.lfrc_mhz > clk.lfrc_max) {
					clk.lfrc_max = clk.lfrc_mhz;
				}
				measure_done(plausible ? 0 : 4, t);
			}
		} else if ((int32_t)(t - m_deadline) >= 0) {
			measure_done(2, t);
		}
		return;
	}
}

/* ---- the case UART --------------------------------------------------------------------------- */

static const struct wisp_boot_status *boot_status(void)
{
	const struct wisp_boot_services *svc = (const void *)WISP_BOOT_SERVICES_ADDR;
	const struct wisp_boot_status *b;

	if (svc->magic != WISP_BOOT_SERVICES_MAGIC || svc->version < 2u) {
		return NULL;
	}
	b = svc->status;
	if ((uintptr_t)b < WISP_BOOT_RAM_BASE || (uintptr_t)b + sizeof(*b) > WISP_BOOT_RAM_END ||
	    b->magic != WISP_BOOT_STATUS_MAGIC || b->version != WISP_BOOT_STATUS_VERSION ||
	    b->size != sizeof(*b) ||
	    b->crc != wisp_diag_crc32(b, (uint32_t)__builtin_offsetof(struct wisp_boot_status, crc))) {
		return NULL;
	}
	return b;
}

static void fill_status(void *ctx, struct wisp_case_status *s)
{
	const struct wisp_boot_services *svc = (const void *)WISP_BOOT_SERVICES_ADDR;
	const struct wisp_boot_status *b = boot_status();

	(void)ctx;
	s->stage = STAGE0_STAGE;
	s->bt_result = WISP_CASE_BT_NOT_STARTED;
	s->image_kind = STAGE0_KIND;
	s->flags |= svc->magic == WISP_BOOT_SERVICES_MAGIC ? WISP_CASE_F_BOOT_SVC : 0;
	if (b) {
		s->flags |= WISP_CASE_F_BOOT_STATUS;
		s->flags |= (b->build & WISP_BOOT_BUILD_OBSERVE) ? WISP_CASE_F_BOOT_OBSERVE : 0;
		s->boot_block_size = (uint16_t)sizeof(*b);
	}
	s->pmic_last = kick_last ? -5 /* -EIO */ : 0;
	s->reset_cause = reset_cause;
	s->uptime_ms = (uint32_t)(((uint64_t)now() * 125u) >> 12);
	s->pmic_kicks = kicks;
	s->pmic_errors = kick_errors;
	s->apollo_feeds = feeds;
	s->confirm_result = WISP_CASE_NO_CONFIRM;
	memcpy(s->rev, STAGE0_REV, sizeof(STAGE0_REV) - 1 < sizeof(s->rev) ? sizeof(STAGE0_REV) - 1
									    : sizeof(s->rev));
}

static struct wisp_boot_status boot_snapshot;
static bool boot_snapshot_ok;

static const uint8_t *boot_block(void *ctx, size_t offset, size_t *len)
{
	(void)ctx;
	if (offset == 0 || !boot_snapshot_ok) {
		const struct wisp_boot_status *b = boot_status();

		boot_snapshot_ok = b != NULL;
		if (b) {
			memcpy(&boot_snapshot, b, sizeof(boot_snapshot));
		}
	}
	*len = boot_snapshot_ok ? sizeof(boot_snapshot) : 0;
	return boot_snapshot_ok ? (const uint8_t *)&boot_snapshot : NULL;
}

static struct wisp_diag_record diag_snapshot;

static const uint8_t *extra_block(void *ctx, uint8_t block, size_t offset, size_t *len)
{
	(void)ctx;
	if (block == WISP_CASE_BLOCK_CLOCK) {
		if (offset == 0) {
			clock_encode();
		}
		*len = sizeof(clock_block);
		return clock_block;
	}
	if (block == WISP_CASE_BLOCK_DIAG) {
		if (offset == 0) {
			memcpy(&diag_snapshot, (const void *)wisp_diag(), sizeof(diag_snapshot));
		}
		*len = sizeof(diag_snapshot);
		return (const uint8_t *)&diag_snapshot;
	}
	*len = 0;
	return NULL;
}

static int boot_report(void *ctx, uint8_t *out)
{
	const struct wisp_boot_status *b = boot_status();

	(void)ctx;
	if (!b) {
		return -1;
	}
	wisp_boot_report_fill(out, WISP_REPORT_SRC_APP, b);
	return 0;
}

static _Noreturn void reset_now(void)
{
	wisp_diag_mark(WISP_DIAG_S0_RESET_REQ);
	RSTGEN_SWPOR = 0xD4u;
	for (;;) {
	}
}

/* ---- start ----------------------------------------------------------------------------------- */

extern uint32_t __data_load, __data_start, __data_end, __bss_start, __bss_end;

static _Noreturn void stage0_main(void)
{
	static struct wisp_case_rx rx;
	static uint8_t out[WISP_CASE_MAX_FRAME];
	static const struct wisp_case_ops ops = {.status = fill_status,
						 .boot_block = boot_block,
						 .boot_report = boot_report,
						 .extra_block = extra_block};
	static const struct wisp_case_version ver = {STAGE0_MAJOR, STAGE0_MINOR, STAGE0_PATCH,
						     STAGE0_KIND, 0};
	uint32_t last_feed, last_kick, last_byte = 0, s0, drained = 0;
	bool uart_ok;

	/* SysTick as a free-running cycle counter, no interrupt (PendSV/SysTick pends cleared). */
	SYST_CSR = 0;
	SCB_ICSR = (1u << 27) | (1u << 25); /* PENDSVCLR, PENDSTCLR */
	SYST_RVR = 0xFFFFFFu;
	SYST_CVR = 0;
	SYST_CSR = 5u; /* ENABLE, CLKSOURCE = core */
	last_cvr = SYST_CVR;

	feed();
	wisp_diag_mark(WISP_DIAG_S0_FEED);
	reset_cause = REG(WISP_RSTGEN_STAT_ADDR);
	clk.stcfg = REG(WISP_STIMER_STCFG);
	clk.wdt_cfg = WDT_CFG;

	uart_ok = boot_uart_init() == 0;
	if (uart_ok) {
		wisp_diag_mark(WISP_DIAG_S0_UART);
	}

	/* Does the STIMER count? 2^22 core cycles is 17-44 ms at 96-250 MHz. Bounded by a poll count
	 * too, in case SysTick does not count in the state the hand-off leaves (W24b-0 review, 1). */
	s0 = wisp_stimer_now();
	for (uint64_t c0 = cycles, i = 0; cycles - c0 < (1u << 22) && i < PROBE_POLLS; i++) {
		cycles_update();
	}
	clk.stimer_probe = wisp_stimer_now() - s0;
	xt = (clk.stcfg & 0xFu) == 3u && clk.stimer_probe != 0;
	clk.timebase = xt ? 1u : 2u;
	t_start = wisp_stimer_now();
	cycles = 0;

	kick();
	wisp_diag_mark(WISP_DIAG_S0_KICK);
	last_feed = last_kick = now();
	wisp_case_rx_init(&rx);
	wisp_diag_mark(WISP_DIAG_S0_LOOP);

	for (;;) {
		uint32_t t = now();
		/* No UART: nothing to poll (an unpowered FR could read "data ready" for ever). A steady
		 * stream of bytes gets DRAIN_MAX per pass, then the watchdogs are served. */
		int ch = uart_ok && drained < DRAIN_MAX ? boot_uart_getc() : -1;

		if (ch == -2) {
			wisp_case_rx_init(&rx);
		} else if (ch >= 0) {
			bool reset = false;
			size_t n;

			if (rx.len && t - last_byte > GAP) {
				wisp_case_rx_init(&rx);
			}
			last_byte = t;
			n = wisp_case_rx_byte(&rx, (uint8_t)ch, &ver, &ops, out, &reset);
			if (n) {
				boot_uart_write(out, (uint32_t)n);
			}
			if (reset) {
				boot_uart_flush();
				reset_now();
			}
			drained++;
			continue; /* drain the receive FIFO first */
		}
		drained = 0;
		if (m_state == M_IDLE && t - last_feed >= SECOND) {
			feed();
			last_feed = t;
		}
		if (m_state == M_IDLE && t - last_kick >= SECOND) {
			kick();
			last_kick = t;
		}
		measure_step(t);
	}
}

__attribute__((used)) _Noreturn void stage0_start(void)
{
	wisp_diag_mark(WISP_DIAG_S0_RESET);
	memcpy(&__data_start, &__data_load, (size_t)((char *)&__data_end - (char *)&__data_start));
	memset(&__bss_start, 0, (size_t)((char *)&__bss_end - (char *)&__bss_start));
	wisp_diag_mark(WISP_DIAG_S0_INIT);
	SCB_VTOR = WISP_MAIN_BASE;
	stage0_main();
}

/* Whatever stack and mode the hand-off left: MSP and PSP onto our own stack, Thread mode on MSP,
 * stack limits off, interrupts masked (stage-0 polls everything). */
__attribute__((naked, noreturn)) void stage0_reset(void)
{
	__asm volatile("cpsid i\n"
		       "ldr r0, =__stack_top\n"
		       "msr msp, r0\n"
		       "msr psp, r0\n"
		       "movs r0, #0\n"
		       "msr control, r0\n"
		       "isb\n"
		       "msr msplim, r0\n"
		       "msr psplim, r0\n"
		       "b stage0_start\n");
}

__attribute__((used)) _Noreturn void stage0_fault_record(uint32_t msp, uint32_t psp, uint32_t exc_return)
{
	wisp_diag_fault(wisp_diag_frame(msp, psp, exc_return), exc_return, WISP_DIAG_S0_FAULT);
	RSTGEN_SWPOR = 0xD4u;
	for (;;) {
	}
}

__attribute__((naked, noreturn)) void stage0_fault(void)
{
	__asm volatile("mrs r0, msp\n"
		       "mrs r1, psp\n"
		       "mov r2, lr\n"
		       "b stage0_fault_record\n");
}

/* Interrupts stay masked; a pended PendSV or SysTick that gets through anyway just returns. */
static void stage0_ignore(void)
{
}

extern uint32_t __stack_top;

__attribute__((section(".vectors"), used)) void (*const stage0_vectors[16])(void) = {
	(void (*)(void))&__stack_top,
	stage0_reset,
	stage0_fault, /* NMI */
	stage0_fault, /* HardFault */
	stage0_fault, /* MemManage */
	stage0_fault, /* BusFault */
	stage0_fault, /* UsageFault */
	stage0_fault, /* SecureFault */
	0, 0, 0,
	stage0_fault, /* SVC */
	stage0_fault, /* DebugMon */
	0,
	stage0_ignore, /* PendSV */
	stage0_ignore, /* SysTick */
};
