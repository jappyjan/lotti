/*
 * SPDX-License-Identifier: MIT
 *
 * One nPM1300 watchdog kick over IOM7, polled. See boot_pmic.h.
 */
#include "boot_pmic.h"

#include "boot_hw.h"

#define IOM7(o) REG(0x40057000u + (o))
#define GPIO_PINCFG(n) REG(0x40010000u + 4u * (n))
#define GPIO_PADKEY    REG(0x40010400u) /* 0x73 unlocks the PINCFG registers */

enum {
	FIFOTHR = 0x104u,
	FIFOCTRL = 0x110u, /* FIFORSTN bit 1: 0 holds the FIFOs in reset */
	FIFOPTR = 0x100u, /* FIFO0REM, bits 15:8: free bytes in the write FIFO */
	FIFOPUSH = 0x10Cu,
	CLKCFG = 0x118u,
	SUBMODCTRL = 0x11Cu,
	CMD = 0x120u,
	OFFSETHI = 0x128u,
	INTEN = 0x200u,
	INTSTAT = 0x204u,
	INTCLR = 0x208u,
	STATUS = 0x248u,
	MI2CCFG = 0x2C0u,
	DEVCFG = 0x2C4u,
	IDLE_MASK = 0x6u, /* STATUS: IDLEST set and CMDACT clear = idle */
	IDLE = 0x4u,
	CMDCMP = 0x1u,
	ERRORS = 0x27Cu, /* INTSTAT: FUNDFL, FOVFL, NAK, IACC, ICMD, ARB */
	PMIC = 0x6Bu,
	KICK = 0x00010407u,       /* the FIFO sends the low byte first: 07 04 01 */
	WRITE_3 = (3u << 8) | 1u, /* CMD: WRITE, TSIZE 3, no offset, no CONT */
	WAIT = 200000u,
	PWR_IOM7 = 0x100u,        /* PWRCTRL DEVPWREN/DEVPWRSTATUS bit 8 */
};

uint32_t boot_pmic_kick(void)
{
	uint32_t result = 0, n;

	GPIO_PADKEY = 0x73u;
	GPIO_PINCFG(22) = 0x4200u;
	GPIO_PINCFG(23) = 0x4200u;
	GPIO_PADKEY = 0;
	if (PWRCTRL_DEVPWREN & PWR_IOM7) {
		/* Someone left IOM7 on: start from its reset state. (DEVPWRSTATUS reports power
		 * domains, IOM4-7 together, so it cannot show IOM7 alone going off: wait a while. The
		 * wait is a guess; if the domain is still going down, the kick below fails with 0x200
		 * or 0x400 and sends nothing. Neither the bootloader nor Wisp leaves IOM7 on.) */
		PWRCTRL_DEVPWREN &= ~PWR_IOM7;
		for (volatile uint32_t i = 0; i < 2000u; i++) {
		}
	}
	PWRCTRL_DEVPWREN |= PWR_IOM7;
	for (n = 0; !(PWRCTRL_DEVPWRSTATUS & PWR_IOM7); n++) {
		if (n > WAIT) {
			result = 0x100u;
			goto off;
		}
	}
	IOM7(FIFOTHR) = 0x1010u;
	IOM7(MI2CCFG) = 0x3F270u;
	IOM7(CLKCFG) = 0x1D0E2301u;
	IOM7(SUBMODCTRL) = 0x10u;
	for (n = 0; (IOM7(STATUS) & IDLE_MASK) != IDLE; n++) {
		if (n > WAIT) {
			result = 0x200u;
			goto disable;
		}
	}
	IOM7(INTEN) = 0;
	IOM7(INTCLR) = 0xFFFFFFFFu;
	/* FIFORSTN pulsed. Simpler than the HAL's reset (am_hal_iom.c internal_iom_reset_on_error
	 * also stops the submodule and forces the IO clock on), so it may not take effect; the
	 * empty-FIFO check below is what guarantees that nothing goes out ahead of the kick. */
	IOM7(FIFOCTRL) &= ~2u;
	IOM7(FIFOCTRL) |= 2u;
	if ((IOM7(FIFOPTR) & 0xFFu) != 0 || ((IOM7(FIFOPTR) >> 8) & 0xFFu) < 4u) {
		result = 0x300u;
		goto disable;
	}
	IOM7(DEVCFG) = PMIC;
	IOM7(OFFSETHI) = 0;
	IOM7(FIFOPUSH) = KICK;
	IOM7(CMD) = WRITE_3;
	for (n = 0; !(IOM7(INTSTAT) & (CMDCMP | ERRORS)) || (IOM7(STATUS) & IDLE_MASK) != IDLE; n++) {
		if (n > WAIT) {
			result = 0x400u;
			goto disable;
		}
	}
	if (IOM7(INTSTAT) & ERRORS) {
		result = 0x50000u | (IOM7(INTSTAT) & ERRORS);
	}
disable:
	IOM7(INTCLR) = 0xFFFFFFFFu;
	IOM7(SUBMODCTRL) = 0;
off:
	PWRCTRL_DEVPWREN &= ~PWR_IOM7;
	return result;
}
