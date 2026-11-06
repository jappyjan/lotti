/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot services: a fixed table inside Wisp Boot that the Wisp app calls. It sits at
 * WISP_BOOT_SERVICES_ADDR, right after Wisp Boot's vector table, and never moves.
 *
 * confirm(): the app's "this boot is good" (BLE advertising + phone HELLO done). Rewrites the
 * boot record with attempts = 0 and rescue_tries = 0, using Wisp Boot's own NOR + littlefs code
 * and its own RAM (WISP_BOOT_RAM_*). Call it with interrupts that touch the NOR or that RAM
 * disabled, while nothing else drives MSPI1, and before the app mounts littlefs itself (or with
 * it unmounted): both sides cache filesystem metadata. Returns 0 on success, negative on failure.
 */
#ifndef WISP_BOOT_SERVICES_H
#define WISP_BOOT_SERVICES_H

#include <stdint.h>

#define WISP_BOOT_SERVICES_ADDR  0x00438200u
#define WISP_BOOT_SERVICES_MAGIC 0x31534257u /* "WBS1" */

/* RAM Wisp Boot owns for good (its data, bss and stack, also while confirm() runs): the top
 * 64 KiB of SSRAM. The Wisp app must leave it alone. */
#define WISP_BOOT_RAM_BASE 0x20370000u
#define WISP_BOOT_RAM_END  0x20380000u

struct wisp_boot_services {
	uint32_t magic;
	uint32_t version;
	int (*confirm)(void);
};

#endif /* WISP_BOOT_SERVICES_H */
