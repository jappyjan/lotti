/*
 * SPDX-License-Identifier: MIT
 *
 * UART2 (the case link: GPIO42 TX, GPIO44 RX, 1 Mbaud 8N1), polled, no interrupts. Shared by
 * Wisp Boot (its boot-report window) and stage-0b. Set up in full every time, never trusting what
 * the loader left: the values are the patched bootloader's own UART2 set-up for its case loader,
 * read from a Renode trace of the real bootloader (PWRCTRL DEVPWREN bit 11; CR 0x18 = 24 MHz clock
 * enabled, IBRD 1 / FBRD 0x20 = 1 Mbaud, LCRH 0x70 = 8 bits with FIFOs, IFLS 0x12, CR 0x319 =
 * enabled with TX and RX); before the reset, a transmission the loader left running is let finish.
 *
 * Half duplex (rung4.md, "W24d: stage-0b"): pads 42 and 44 sit on ONE pogo wire. Like stock
 * (UART2 init 0x5A196A, send 0x57B292) and the patched loader (`direction()`, pin table 0x434210:
 * pads 42/44, function 4 each, park function 3), the driver listens by default (pad 44 UART2RX,
 * pad 42 parked: GPIO, output off) and turns the wire round only to send: wait the loader's 6 ms
 * for the other end to let go, park 44, pad 42 UART2TX, send, wait (bounded) until the last stop
 * bit has left, park 42, 44 UART2RX, drop what the receiver latched meanwhile. Pad writes go between
 * GPIO PADKEY 0x73 and 0, as the bootloader's own. The W24/W24b driver put both pads in UART
 * function for good, so the TX pad drove the wire while the case was sending. Every wait is bounded.
 */
#ifndef WISP_BOOT_UART_H
#define WISP_BOOT_UART_H

#include <stdint.h>

/* 0 = up, nonzero = UART2 did not power up. */
int boot_uart_init(void);
/* The next received byte (0..255), -1 if none, -2 for a byte with an error (cleared). */
int boot_uart_getc(void);
/* Sends n bytes, turning the wire round as above; returns listening. */
void boot_uart_write(const uint8_t *p, uint32_t n);
/* Waits (bounded) until the transmitter is idle. */
void boot_uart_flush(void);

#endif /* WISP_BOOT_UART_H */
