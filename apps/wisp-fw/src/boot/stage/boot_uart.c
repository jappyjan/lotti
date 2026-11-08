/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 polled driver. See boot_uart.h.
 */
#include "boot_uart.h"

#include "boot_hw.h"

#define UART2(o) REG(0x4003B000u + (o))
#define GPIO_PINCFG(n) REG(0x40010000u + 4u * (n))

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
};

int boot_uart_init(void)
{
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
	GPIO_PINCFG(42) = 4u;
	GPIO_PINCFG(44) = 4u;
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

void boot_uart_write(const uint8_t *p, uint32_t n)
{
	while (n--) {
		for (uint32_t i = 0; (UART2(FR) & FR_TXFF) && i < WAIT; i++) {
		}
		UART2(DR) = *p++;
	}
}

void boot_uart_flush(void)
{
	for (uint32_t i = 0; (UART2(FR) & FR_BUSY || !(UART2(FR) & FR_TXFE)) && i < WAIT; i++) {
	}
}
