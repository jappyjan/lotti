/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp native firmware, milestone M0: banner + heartbeat on the debug UART.
 *
 * Nothing here touches a peripheral beyond the console. Wisp Boot (src/boot/) is not wired in
 * yet; the image entry is Zephyr's reset vector at 0x438000.
 */

#include <stdint.h>

#include <zephyr/kernel.h>
#include <zephyr/linker/linker-defs.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>

#include "app_version.h"

#ifndef WISP_FW_GIT_REV
#define WISP_FW_GIT_REV "unknown"
#endif

int main(void)
{
	printk("\n*** Wisp native " WISP_FW_VERSION " (" WISP_FW_GIT_REV ") ***\n");
	printk("wisp: board %s, Zephyr %s, image @ %p\n", CONFIG_BOARD, KERNEL_VERSION_STRING,
	       (void *)__rom_region_start);
	printk("wisp: M0 skeleton, bluetooth off (safety rule 8)\n");

	for (uint32_t beat = 1;; beat++) {
		k_msleep(CONFIG_WISP_HEARTBEAT_MS);
		printk("wisp: heartbeat %u uptime %lld ms\n", beat, k_uptime_get());
	}

	return 0;
}
