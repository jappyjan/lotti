/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — MSPI1 PIO driver for the MX25U25643G. Register use follows AmbiqSuite's
 * am_hal_mspi_blocking_transfer() (hal_ambiq am_hal_mspi.c): INSTR/ADDR, then CTRL with
 * XFERBYTES, TXRX, SENDI, SENDA, START; FIFO words; wait CTRL.STATUS. The device configuration
 * values (DEV0CFG, PADOUTEN) are the ones the stock Even bootloader programs (seen in Renode).
 *
 * MSPICFG holds two active-low resets (PRSTN bit 31, IPRSTN bit 30; hal_ambiq only ever
 * read-modify-writes it). Writing the whole register 0, as this driver did up to stage-0, holds
 * MSPI1 in reset on silicon (rung4.md W24c): it is now left as the bootloader set it, with both
 * resets released. Every block read feeds the watchdog, so littlefs's loops (which only call
 * bd_read) cannot starve it.
 */
#include "boot_nor.h"

#include "boot_hw.h"

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
#define M_DEV0XIP   REG(MSPI1 + 0x090u)
#define M_DMACFG    REG(MSPI1 + 0x100u)
#define M_INTEN     REG(MSPI1 + 0x200u)
#define M_INTCLR    REG(MSPI1 + 0x208u)
#define M_CQCFG     REG(MSPI1 + 0x2A0u)

#define MSPICFG_PRSTN  (1u << 31) /* active low: 0 holds the MSPI in reset */
#define MSPICFG_IPRSTN (1u << 30)

#define CTRL_START  (1u << 0)
#define CTRL_STATUS (1u << 1)
#define CTRL_SENDA  (1u << 5)
#define CTRL_SENDI  (1u << 6)
#define CTRL_TX     (1u << 7)

#define TIMEOUT 2000000u

static int wait_status(void)
{
	for (uint32_t i = 0; i < TIMEOUT; i++) {
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
			while ((M_TXENTRIES & 0x1Fu) >= 16u && ++t < TIMEOUT) {
			}
		} else {
			while ((M_RXENTRIES & 0x1Fu) == 0 && ++t < TIMEOUT) {
			}
			uint32_t v = M_RXFIFO;
			__builtin_memcpy((uint8_t *)w + 4u * i, &v, (n - 4u * i) < 4u ? n - 4u * i : 4u);
		}
		if (t >= TIMEOUT) {
			return -2;
		}
	}
	return wait_status();
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

	for (uint32_t i = 0; i < TIMEOUT; i++) {
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

int nor_init(uint32_t *rdid)
{
	uint32_t id = 0;

	PWRCTRL_DEVPWREN |= PWRCTRL_DEV_MSPI1;
	for (uint32_t i = 0; !(PWRCTRL_DEVPWRSTATUS & PWRCTRL_DEV_MSPI1) && i < 100000u; i++) {
	}
	M_INTEN = 0;
	M_CQCFG = 0;
	M_DMACFG = 0;
	M_DEV0XIP = 0;
	M_MSPICFG |= MSPICFG_PRSTN | MSPICFG_IPRSTN;
	M_PADOUTEN = 0x10Fu;      /* CLK + D0..D3, as stock */
	M_DEV0CFG = 0x01010860u;  /* stock: serial CE0, 4-byte address, 1-byte instr, TXNEG */
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

int nor_read(uint32_t addr, void *buf, uint32_t n)
{
	uint8_t *p = buf;

	while (n) {
		uint32_t c = n > 4096u ? 4096u : n;

		hw_wdt_feed();
		if (pio(0x13, 1, addr, 0, p, c) != 0) {
			return -20;
		}
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
