/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 polled driver, half duplex. See boot_uart.h.
 */
#include "boot_uart.h"

#include "boot_hw.h"

#define UART2(o) REG(0x4003B000u + (o))
#define GPIO_PINCFG(n) REG(0x40010000u + 4u * (n))
#define GPIO_PADKEY    REG(0x40010400u) /* 0x73 unlocks the PINCFG registers */

enum {
	DR = 0x00u,
	RSR = 0x04u, /* write: clear the latched receive errors (ECR) */
	FR = 0x18u,
	IBRD = 0x24u,
	FBRD = 0x28u,
	LCRH = 0x2Cu,
	CR = 0x30u,
	IFLS = 0x34u,
	IER = 0x38u,
	IEC = 0x44u,
	FR_BUSY = 0x08u,
	FR_RXFE = 0x10u,
	FR_TXFF = 0x20u,
	FR_TXFE = 0x80u,
	DR_ERRORS = 0xF00u, /* FE, PE, BE, OE */
	PWR_UART2 = 0x800u, /* PWRCTRL DEVPWREN/DEVPWRSTATUS bit 11 */
	WAIT = 200000u,
	PAD_TX = 42u,
	PAD_RX = 44u,
	PAD_UART = 4u,   /* FNCSEL 4: UART2TX on pad 42, UART2RX on pad 44 */
	PAD_PARKED = 3u, /* FNCSEL 3 (GPIO), output and input off: the pad lets go of the wire */
	SETTLE_TICKS = 197u,  /* 6 ms at 32768 Hz: the loader's 6-tick wait before it answers */
	SETTLE_POLLS = 60000u, /* the same bound without a counting STIMER (about 6-12 ms) */
};

#define STIMER_STTMR REG(0x40008804u)

/* The case link is one wire: pad 42 drives it only while we send (W24c, rung4.md). */
static void pads(uint32_t tx, uint32_t rx)
{
	GPIO_PADKEY = 0x73u;
	GPIO_PINCFG(PAD_TX) = tx;
	GPIO_PINCFG(PAD_RX) = rx;
	GPIO_PADKEY = 0;
}

int boot_uart_init(void)
{
	if ((PWRCTRL_DEVPWREN & PWR_UART2) && (UART2(CR) & 1u)) {
		boot_uart_flush(); /* the loader's last reply may still be leaving */
	}
	PWRCTRL_DEVPWREN |= PWR_UART2;
	for (uint32_t n = 0; !(PWRCTRL_DEVPWRSTATUS & PWR_UART2); n++) {
		if (n > WAIT) {
			return -1;
		}
	}
	UART2(CR) = 0;
	UART2(CR) = 0x18u;
	UART2(IBRD) = 1u;
	UART2(FBRD) = 0x20u;
	UART2(LCRH) = 0x70u;
	UART2(IFLS) = 0x12u;
	UART2(IER) = 0;
	UART2(IEC) = 0xFFFFFFFFu;
	UART2(RSR) = 0;
	pads(PAD_PARKED, PAD_UART); /* receive: the case owns the wire */
	UART2(CR) = 0x319u;
	return 0;
}

int boot_uart_getc(void)
{
	uint32_t d;

	if (UART2(FR) & FR_RXFE) {
		return -1;
	}
	d = UART2(DR);
	if (d & DR_ERRORS) {
		UART2(RSR) = 0;
		return -2;
	}
	return (int)(d & 0xFFu);
}

/* Like the loader: give the case time to turn its USART round to receive, park the receive pad
 * (it would hear our own bytes), drive pad 42, send, wait until the last stop bit is out, then
 * let go of the wire again. Every wait is bounded. */
void boot_uart_write(const uint8_t *p, uint32_t n)
{
	uint32_t t0 = STIMER_STTMR;

	for (uint32_t i = 0; STIMER_STTMR - t0 < SETTLE_TICKS && i < SETTLE_POLLS; i++) {
	}
	pads(PAD_UART, PAD_PARKED);
	while (n--) {
		for (uint32_t i = 0; (UART2(FR) & FR_TXFF) && i < WAIT; i++) {
		}
		UART2(DR) = *p++;
	}
	boot_uart_flush();
	pads(PAD_PARKED, PAD_UART);
}

void boot_uart_flush(void)
{
	for (uint32_t i = 0; (UART2(FR) & FR_BUSY || !(UART2(FR) & FR_TXFE)) && i < WAIT; i++) {
	}
}
