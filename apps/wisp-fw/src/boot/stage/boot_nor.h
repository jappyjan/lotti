/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — MX25U25643G on MSPI1 CE0, PIO only, 1-1-1 SPI with the 4-byte-address opcodes
 * (READ4B 0x13, PP4B 0x12, SE4B 0x21), so it works whether or not the device is in 4-byte mode.
 */
#ifndef WISP_BOOT_NOR_H
#define WISP_BOOT_NOR_H

#include <stdint.h>

int nor_init(void);
int nor_read(uint32_t addr, void *buf, uint32_t n);
int nor_prog(uint32_t addr, const void *buf, uint32_t n); /* within one 256-byte page */
int nor_erase_4k(uint32_t addr);

#endif /* WISP_BOOT_NOR_H */
