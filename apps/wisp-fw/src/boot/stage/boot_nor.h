/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — MX25U25643G on MSPI1 CE0, PIO only, 1-1-1 SPI with the 4-byte-address opcodes
 * (READ4B 0x13, PP4B 0x12, SE4B 0x21), so it works whether or not the device is in 4-byte mode.
 * The observe-only build (WISP_BOOT_OBSERVE=1) has no program or erase: its only NOR commands
 * are RDID (0x9F), RDSR (0x05) and READ4B (0x13).
 */
#ifndef WISP_BOOT_NOR_H
#define WISP_BOOT_NOR_H

#include <stdint.h>

#ifndef WISP_BOOT_OBSERVE
#define WISP_BOOT_OBSERVE 0
#endif

/* The NOR phase's poll budget: every poll of every wait spends one; at 0 every call fails at once
 * (-5 from a transfer). Set it before each phase (boot_main.c nor_phase). */
void nor_budget(uint32_t polls);
uint32_t nor_budget_left(void);
/* Powers MSPI1, reads the RDID into *rdid (3 bytes, byte 0 = manufacturer) and checks it. */
int nor_init(uint32_t *rdid);
int nor_read(uint32_t addr, void *buf, uint32_t n);
#if !WISP_BOOT_OBSERVE
int nor_prog(uint32_t addr, const void *buf, uint32_t n); /* within one 256-byte page */
int nor_erase_4k(uint32_t addr);
#endif

#endif /* WISP_BOOT_NOR_H */
