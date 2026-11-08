/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 (the case link: GPIO42 TX, GPIO44 RX, 1 Mbaud 8N1), polled, no interrupts. Shared by
 * Wisp Boot (its boot-report window) and stage-0. Set up in full every time, never trusting what
 * the loader left: the values are the patched bootloader's own UART2 set-up for its case loader,
 * read from a Renode trace of the real bootloader (PWRCTRL DEVPWREN bit 11; pads 42/44 PINCFG 4 =
 * UART2TX/UART2RX; CR 0x18 = 24 MHz clock enabled, IBRD 1 / FBRD 0x20 = 1 Mbaud, LCRH 0x70 = 8 bits
 * with FIFOs, IFLS 0x12, CR 0x319 = enabled with TX and RX). Every wait is bounded.
 */
#ifndef WISP_BOOT_UART_H
#define WISP_BOOT_UART_H

#include <stdint.h>

/* 0 = up, nonzero = UART2 did not power up. */
int boot_uart_init(void);
/* The next received byte (0..255), -1 if none, -2 for a byte with an error (cleared). */
int boot_uart_getc(void);
void boot_uart_write(const uint8_t *p, uint32_t n);
/* Waits (bounded) until the transmitter is idle. */
void boot_uart_flush(void);

#endif /* WISP_BOOT_UART_H */
