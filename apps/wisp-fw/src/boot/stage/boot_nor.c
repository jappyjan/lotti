/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — MSPI1 PIO driver for the MX25U25643G. Register use follows AmbiqSuite's
 * am_hal_mspi_blocking_transfer() (hal_ambiq am_hal_mspi.c): INSTR/ADDR, then CTRL with
 * XFERBYTES, TXRX, SENDI, SENDA, START; FIFO words; wait CTRL.STATUS. The device configuration
 * values (DEV0CFG, PADOUTEN) are the ones the stock Even bootloader programs (seen in Renode), with a
 * slower clock (DEV0CFG_WISP, below).
 *
 * Registers that hold more than our settings are read-modify-written, as the HAL does (it only
 * ever sets single fields): above all MSPICFG, whose bits 31/30 are PRSTN/IPRSTN, active-low
 * resets. The W24/W24b Wisp Boot wrote MSPICFG = 0, which holds MSPI1 in reset on Apollo510
 * (rung4.md, "W24d: stage-0b").
 *
 * Power and clock (rung4.md, "W24e: stage-0c"): the Even bootloader wraps every NOR access in
 * am_hal_mspi_power_control(WAKE) / (DEEPSLEEP), so it hands off with MSPI1 powered down
 * (DEVPWREN.PWRENMSPI1 = 0) and its IO clock gated (CLKGEN.MSPIIOCLKCTRL = 0x200: MSPI1IOCLKSEL 8,
 * MSPI1IOCLKEN 0; seen in Renode). stage-0b's Wisp Boot powered MSPI1 but never ungated the clock,
 * and on silicon it never got past its first MSPI1 access (W24d: last stage boot-nor, then the
 * watchdog). nor_init now does what the HAL's WAKE does, in its order: power up and wait for
 * DEVPWRSTATUS (bounded; no MSPI1 access at all if it never comes), then the IO clock (source as
 * stock leaves it, then the enable, then about 10 us), and only then MSPI1's registers. nor_off
 * undoes both before the hand-off, so the app finds MSPI1 as stock leaves it.
 *
 * Every wait spends from the NOR phase's poll budget (nor_budget) and checks its STIMER deadline
 * (nor_deadline); once either is spent every call fails at once, so the whole NOR phase is bounded,
 * not just each word. One transfer may poll at most XFER_POLLS times in all (not per word), so the
 * longest stretch without a watchdog feed is one transfer's bound, far below the 8 s watchdog.
 */
#include "boot_nor.h"

#include "boot_hw.h"
#include "wisp_diag.h"

#define MSPI1 0x40061000u
#define M_CTRL      REG(MSPI1 + 0x000u)
#define M_ADDR      REG(MSPI1 + 0x008u)
#define M_INSTR     REG(MSPI1 + 0x00Cu)
#define M_TXFIFO    REG(MSPI1 + 0x010u)
#define M_RXFIFO    REG(MSPI1 + 0x014u)
#define M_TXENTRIES REG(MSPI1 + 0x018u)
#define M_RXENTRIES REG(MSPI1 + 0x01Cu)
#define M_MSPICFG   REG(MSPI1 + 0x030u)
#define M_PADOUTEN  REG(MSPI1 + 0x044u)
#define M_DEV0CFG   REG(MSPI1 + 0x084u)
#define M_DEV0CFG1  REG(MSPI1 + 0x08Cu)
#define M_DEV0XIP   REG(MSPI1 + 0x090u)
#define M_DMACFG    REG(MSPI1 + 0x100u)
#define M_INTEN     REG(MSPI1 + 0x200u)
#define M_INTCLR    REG(MSPI1 + 0x208u)
#define M_CQCFG     REG(MSPI1 + 0x2A0u)

#define CTRL_START  (1u << 0)
#define CTRL_STATUS (1u << 1)
#define CTRL_SENDA  (1u << 5)
#define CTRL_SENDI  (1u << 6)
#define CTRL_TX     (1u << 7)

/* apollo510.h MSPI0_* field masks (MSPI1 has the same layout) */
#define MSPICFG_PRSTN     (1u << 31) /* active-low resets: 1 = running */
#define MSPICFG_IPRSTN    (1u << 30)
#define MSPICFG_FIFORESET (1u << 29) /* active high */
#define MSPICFG_IOMSEL    (0xFu << 4)
#define MSPICFG_APBCLK    (1u << 0)
#define DEV0XIP_XIPEN     (1u << 0)
#define DMACFG_DMAEN      (3u << 0)
#define CQCFG_CQEN        (1u << 0)
#define DEV0CFG1_SDR250EN (1u << 30) /* the HAL sets it only for 192/250 MHz; Wisp runs 12 MHz */

/* DEV0CFG: stock's 0x01010860 (serial CE0, 4-byte address, 1-byte instruction, TXNEG, turnaround 8)
 * with CLKDIV 8 instead of 1. With the HFRC 192 MHz IO clock that is SCK 12 MHz (HAL: 96 MHz =
 * CLKDIV 1, 12 MHz = CLKDIV 8). Stock runs 96 MHz after its 36-setting timing scan; Wisp Boot does
 * no scan and uses the plain READ4B (0x13, no dummy cycles), which SPI NOR parts specify at a lower
 * clock than their fast reads. 12 MHz is far inside that, and fast enough: about 1.5 MB/s. */
#define DEV0CFG_WISP      0x01080860u
#define TIMEOUT 2000000u     /* polls of one wait */
#define XFER_POLLS 2000000u  /* polls of one whole transfer */
#define POWER_POLLS 100000u  /* DEVPWRSTATUS reads, power up or down */
#define CLOCK_SETTLE 2000u   /* CLKGEN reads after the IO clock enable: >= 10 us at any core clock */
#define DEADLINE_EVERY 1024u /* polls between two STIMER deadline checks */

static uint32_t budget; /* polls left in this NOR phase (nor_budget) */
static uint32_t dl_t0, dl_ticks, dl_count; /* the phase's STIMER deadline (nor_deadline), 0 = none */

void nor_budget(uint32_t polls)
{
	budget = polls;
}

void nor_deadline(uint32_t t0, uint32_t ticks)
{
	dl_t0 = t0;
	dl_ticks = ticks;
	dl_count = 0;
}

uint32_t nor_budget_left(void)
{
	return budget;
}

/* One poll from the budget; 0 when it is spent. */
static int spend(void)
{
	if (budget == 0) {
		return 0;
	}
	if (dl_ticks && ++dl_count >= DEADLINE_EVERY) {
		dl_count = 0;
		if (wisp_stimer_now() - dl_t0 > dl_ticks) {
			budget = 0;
			return 0;
		}
	}
	budget--;
	return 1;
}

static int wait_status(uint32_t *polls)
{
	for (uint32_t i = 0; i < TIMEOUT && *polls < XFER_POLLS && spend(); i++, (*polls)++) {
		if (M_CTRL & CTRL_STATUS) {
			return 0;
		}
	}
	return -1;
}

/* One PIO transfer of n bytes (n <= 4096, multiple of 4 except the last word). */
static int pio(uint8_t op, int send_addr, uint32_t addr, int tx, void *buf, uint32_t n)
{
	uint32_t *w = buf;
	uint32_t polls = 0; /* of this transfer, all words and the final wait */

	if (budget == 0) {
		return -5;
	}
	M_INTCLR = 0xFFFFFFFFu;
	M_INSTR = op;
	if (send_addr) {
		M_ADDR = addr;
	}
	M_CTRL = (n << 16) | (tx ? CTRL_TX : 0) | CTRL_SENDI | (send_addr ? CTRL_SENDA : 0) |
		 CTRL_START;
	for (uint32_t i = 0; i < (n + 3u) / 4u; i++) {
		uint32_t t = 0;

		if (tx) {
			uint32_t v;
			__builtin_memcpy(&v, (uint8_t *)w + 4u * i, (n - 4u * i) < 4u ? n - 4u * i : 4u);
			M_TXFIFO = v;
			while ((M_TXENTRIES & 0x1Fu) >= 16u && ++t < TIMEOUT && ++polls < XFER_POLLS && spend()) {
			}
		} else {
			while ((M_RXENTRIES & 0x1Fu) == 0 && ++t < TIMEOUT && ++polls < XFER_POLLS && spend()) {
			}
			uint32_t v = M_RXFIFO;
			__builtin_memcpy((uint8_t *)w + 4u * i, &v, (n - 4u * i) < 4u ? n - 4u * i : 4u);
		}
		if (t >= TIMEOUT || polls >= XFER_POLLS || budget == 0) {
			return -2;
		}
	}
	return wait_status(&polls);
}

#if !WISP_BOOT_OBSERVE
static int cmd(uint8_t op)
{
	return pio(op, 0, 0, 1, 0, 0);
}
#endif

static int wait_ready(void)
{
	uint32_t sr = 0;

	for (uint32_t i = 0; i < TIMEOUT && spend(); i++) {
		if (pio(0x05, 0, 0, 0, &sr, 1) != 0) {
			return -3;
		}
		if (!(sr & 1u)) {
			return 0;
		}
		hw_wdt_feed();
	}
	return -4;
}

/* MSPI1 power and IO clock, in the HAL's order (am_hal_mspi_power_control WAKE: periph enable and
 * its DEVPWRSTATUS wait, then mspi_clkgen_ctrl: source, enable, 10 us). Every register is
 * read-modify-written. Returns 0, or -12 if MSPI1's power never showed in DEVPWRSTATUS: then
 * nothing touches MSPI1 (a powered-down block may stall the bus). */
static int mspi1_up(void)
{
	uint32_t i;

	PWRCTRL_DEVPWREN |= PWRCTRL_DEV_MSPI1;
	for (i = 0; !(PWRCTRL_DEVPWRSTATUS & PWRCTRL_DEV_MSPI1) && i < POWER_POLLS; i++) {
	}
	if (!(PWRCTRL_DEVPWRSTATUS & PWRCTRL_DEV_MSPI1)) {
		return -12;
	}
	wisp_diag_mark(WISP_DIAG_BOOT_NOR_POWER);
	/* The HAL changes the source only with the gate closed. */
	CLKGEN_MSPIIOCLKCTRL &= ~CLKGEN_MSPI1IOCLKEN;
	CLKGEN_MSPIIOCLKCTRL = (CLKGEN_MSPIIOCLKCTRL & ~CLKGEN_MSPI1IOCLKSEL) | CLKGEN_MSPI1IOCLKSEL_HFRC_192MHZ;
	CLKGEN_MSPIIOCLKCTRL |= CLKGEN_MSPI1IOCLKEN;
	for (i = 0; i < CLOCK_SETTLE; i++) {
		(void)CLKGEN_MSPIIOCLKCTRL;
	}
	wisp_diag_mark(WISP_DIAG_BOOT_NOR_CLOCK);
	return 0;
}

int nor_init(uint32_t *rdid)
{
	uint32_t id = 0;
	int e = mspi1_up();

	if (e != 0) {
		return e;
	}
	M_INTEN = 0;              /* interrupt enables only */
	M_CQCFG &= ~CQCFG_CQEN;   /* no command queue, no DMA, no XIP: PIO only */
	M_DMACFG &= ~DMACFG_DMAEN;
	M_DEV0XIP &= ~DEV0XIP_XIPEN;
	/* No continuous APB clock, IOMSEL 0 (unused: no command queue), resets and FIFO released. */
	M_MSPICFG = (M_MSPICFG & ~(MSPICFG_APBCLK | MSPICFG_IOMSEL | MSPICFG_FIFORESET)) | MSPICFG_PRSTN |
		    MSPICFG_IPRSTN;
	M_DEV0CFG1 &= ~DEV0CFG1_SDR250EN;
	M_PADOUTEN = 0x10Fu;      /* CLK + D0..D3, as stock */
	M_DEV0CFG = DEV0CFG_WISP;
	wisp_diag_mark(WISP_DIAG_BOOT_NOR_ID);
	if (pio(0x9F, 0, 0, 0, &id, 3) != 0) {
		return -10;
	}
	*rdid = id & 0xFFFFFFu;
	if ((id & 0xFFFFFFu) != 0x3925C2u) {
		hw_log_hex("wisp-boot: NOR id ", id);
		return -11;
	}
	return wait_ready();
}

int nor_powered(void)
{
	return (PWRCTRL_DEVPWREN & PWRCTRL_DEV_MSPI1) != 0;
}

void nor_off(void)
{
	/* The HAL's DEEPSLEEP order: power off, then close the gate (the source stays, as stock's). */
	PWRCTRL_DEVPWREN &= ~PWRCTRL_DEV_MSPI1;
	for (uint32_t i = 0; (PWRCTRL_DEVPWRSTATUS & PWRCTRL_DEV_MSPI1) && i < POWER_POLLS; i++) {
	}
	CLKGEN_MSPIIOCLKCTRL &= ~CLKGEN_MSPI1IOCLKEN;
}

int nor_read(uint32_t addr, void *buf, uint32_t n)
{
	uint8_t *p = buf;

	while (n) {
		uint32_t c = n > 4096u ? 4096u : n;

		if (pio(0x13, 1, addr, 0, p, c) != 0) {
			return -20;
		}
		hw_wdt_feed(); /* per 4 KiB block; the phase's budget bounds how many */
		p += c;
		addr += c;
		n -= c;
	}
	return 0;
}

#if !WISP_BOOT_OBSERVE
int nor_prog(uint32_t addr, const void *buf, uint32_t n)
{
	if (cmd(0x06) != 0 || pio(0x12, 1, addr, 1, (void *)buf, n) != 0) {
		return -30;
	}
	return wait_ready();
}

int nor_erase_4k(uint32_t addr)
{
	if (cmd(0x06) != 0 || pio(0x21, 1, addr, 1, 0, 0) != 0) {
		return -40;
	}
	return wait_ready();
}
#endif /* !WISP_BOOT_OBSERVE */
