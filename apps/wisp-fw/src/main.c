/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp native firmware: banner, Bluetooth with the Wisp GATT service, heartbeat.
 *
 * The link (src/ble/, src/link/) carries a wisp-core session; no other driver is behind the
 * core yet. Wisp Boot (src/boot/) is not wired in; the image entry is Zephyr's reset vector at
 * 0x438000.
 */

#include <stdint.h>

#include <zephyr/kernel.h>
#include <zephyr/linker/linker-defs.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>

#include "app_version.h"
#if defined(CONFIG_WISP_BLE)
#include "wisp_ble.h"
#endif

#ifndef WISP_FW_GIT_REV
#define WISP_FW_GIT_REV "unknown"
#endif

int main(void)
{
	printk("\n*** Wisp native " WISP_FW_VERSION " (" WISP_FW_GIT_REV ") ***\n");
#if defined(CONFIG_ARCH_POSIX)
	printk("wisp: board %s, Zephyr %s, Linux process\n", CONFIG_BOARD, KERNEL_VERSION_STRING);
#else
	printk("wisp: board %s, Zephyr %s, image @ %p\n", CONFIG_BOARD, KERNEL_VERSION_STRING,
	       (void *)__rom_region_start);
#endif
#if defined(CONFIG_WISP_BLE)
	printk("wisp: bluetooth: EM9305 update path compiled out (safety rule 8)\n");
	if (wisp_ble_start() == 0) {
		printk("wisp: bluetooth up, Wisp GATT service registered\n");
	} else {
		printk("wisp: bluetooth unavailable, running without a link\n");
	}
#else
	printk("wisp: bluetooth off\n");
#endif

	if (CONFIG_WISP_HEARTBEAT_MS == 0) {
		return 0;
	}
	for (uint32_t beat = 1;; beat++) {
		k_msleep(CONFIG_WISP_HEARTBEAT_MS);
		printk("wisp: heartbeat %u uptime %lld ms\n", beat, k_uptime_get());
	}

	return 0;
}
