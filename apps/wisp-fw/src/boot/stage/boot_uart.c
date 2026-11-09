/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 polled driver, half duplex. See boot_uart.h.
 */
#include "boot_uart.h"

#include "boot_hw.h"
#include "wisp_diag.h"

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
	PAD_UART2 = 4u,  /* FNCSEL 4: UART2TX on pad 42, UART2RX on pad 44 (the loader's pin table) */
	PAD_PARKED = 3u, /* FNCSEL 3 (GPIO), input and output disabled: the pad lets go of the wire */
	SETTLE_TICKS = 197u, /* 6 ms at 32768 Hz: the loader's DELAY(6) before each of its sends */
	SETTLE_POLLS = 200000u, /* cap, whatever the STIMER does */
	DRAIN_MAX = 64u,
};

/* Raw PINCFG writes between PADKEY 0x73 and 0, as the bootloader's GPIO helper does. The pad that
 * stops driving is parked first, so the two are never in UART function at once. */
static void pads_rx(void)
{
	GPIO_PADKEY = 0x73u;
	GPIO_PINCFG(PAD_TX) = PAD_PARKED;
	GPIO_PINCFG(PAD_RX) = PAD_UART2;
	GPIO_PADKEY = 0;
}

static void pads_tx(void)
{
	GPIO_PADKEY = 0x73u;
	GPIO_PINCFG(PAD_RX) = PAD_PARKED;
	GPIO_PINCFG(PAD_TX) = PAD_UART2;
	GPIO_PADKEY = 0;
}

/* Waits (bounded) until the last stop bit has left: TX FIFO empty and not busy. */
static void tx_done(void)
{
	for (uint32_t i = 0; (UART2(FR) & FR_BUSY || !(UART2(FR) & FR_TXFE)) && i < WAIT; i++) {
	}
}

/* Whatever the receiver latched while its pad was parked (or our own turnaround) goes. */
static void rx_drain(void)
{
	for (uint32_t i = 0; !(UART2(FR) & FR_RXFE) && i < DRAIN_MAX; i++) {
		(void)UART2(DR);
	}
	UART2(RSR) = 0;
}

int boot_uart_init(void)
{
	if ((PWRCTRL_DEVPWREN & PWR_UART2) && (UART2(CR) & 1u)) {
		tx_done(); /* the loader's last reply may still be leaving */
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
	pads_rx();
	UART2(CR) = 0x319u;
	rx_drain();
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

void boot_uart_write(const uint8_t *p, uint32_t n)
{
	const uint32_t t0 = wisp_stimer_now();

	/* The other end sent last: give it the loader's 6 ms to stop driving and start listening. */
	for (uint32_t i = 0; wisp_stimer_now() - t0 < SETTLE_TICKS && i < SETTLE_POLLS; i++) {
	}
	pads_tx();
	while (n--) {
		for (uint32_t i = 0; (UART2(FR) & FR_TXFF) && i < WAIT; i++) {
		}
		UART2(DR) = *p++;
	}
	tx_done();
	pads_rx();
	rx_drain();
}

void boot_uart_flush(void)
{
	tx_done();
}
