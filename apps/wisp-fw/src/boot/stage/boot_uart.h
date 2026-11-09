/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 (the case link: GPIO42 TX, GPIO44 RX, 1 Mbaud 8N1), polled, no interrupts. Shared by
 * Wisp Boot (its boot-report window) and stage-0. Set up in full every time, never trusting what
 * the loader left: the values are the patched bootloader's own UART2 set-up for its case loader,
 * read from a Renode trace of the real bootloader (PWRCTRL DEVPWREN bit 11; PINCFG 4 = UART2TX on
 * pad 42 / UART2RX on pad 44, written between GPIO PADKEY 0x73 and 0 as the bootloader does;
 * before the reset, a transmission the loader left running is let finish; then
 * CR 0x18 = 24 MHz clock enabled, IBRD 1 / FBRD 0x20 = 1 Mbaud, LCRH 0x70 = 8 bits
 * with FIFOs, IFLS 0x12, CR 0x319 = enabled with TX and RX). Every wait is bounded.
 *
 * Half duplex (rung4.md W24c): the pogo link is one wire. Like stock (its UART2 init parks pad 42
 * as GPIO function 3 with the output off and puts pad 44 on UART2RX; every send swaps them and
 * swaps back) and drdaeman's loader (`direction()`, after a 6-tick wait), the pads sit in receive
 * and boot_uart_write() alone drives pad 42: about 6 ms after it is called, for as long as the
 * bytes take, then it parks pad 42 again.
 */
#ifndef WISP_BOOT_UART_H
#define WISP_BOOT_UART_H

#include <stdint.h>

/* 0 = up, nonzero = UART2 did not power up. */
int boot_uart_init(void);
/* The next received byte (0..255), -1 if none, -2 for a byte with an error (cleared). */
int boot_uart_getc(void);
/* Turns the wire round, sends, waits until the last bit is out and turns it back (bounded). */
void boot_uart_write(const uint8_t *p, uint32_t n);
/* Waits (bounded) until the transmitter is idle. */
void boot_uart_flush(void);

#endif /* WISP_BOOT_UART_H */
