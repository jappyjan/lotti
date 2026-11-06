/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — vector table and reset handler. Every fault resets the chip (the boot attempt is
 * already counted when the app can fault; inside Wisp Boot a reset is the only safe answer).
 */
#include <stdint.h>
#include <string.h>

#include "boot_hw.h"

extern uint32_t __stack_top, __data_load, __data_start, __data_end, __bss_start, __bss_end;
_Noreturn void wisp_boot_main(void);

_Noreturn void reset_handler(void)
{
	/* Whatever the bootloader left enabled must not vector through this 16-entry table. */
	__asm volatile("cpsid i" ::: "memory");
	for (int n = 0; n < 8; n++) {
		NVIC_ICER(n) = 0xFFFFFFFFu;
		NVIC_ICPR(n) = 0xFFFFFFFFu;
	}
	memcpy(&__data_start, &__data_load, (size_t)((char *)&__data_end - (char *)&__data_start));
	memset(&__bss_start, 0, (size_t)((char *)&__bss_end - (char *)&__bss_start));
	wisp_boot_main();
}

_Noreturn void fault_handler(void)
{
	hw_log("wisp-boot: fault -> reset\n");
	hw_reset();
}

__attribute__((section(".vectors"), used)) void (*const vectors[16])(void) = {
	(void (*)(void))&__stack_top,
	reset_handler,
	fault_handler, /* NMI */
	fault_handler, /* HardFault */
	fault_handler, /* MemManage */
	fault_handler, /* BusFault */
	fault_handler, /* UsageFault */
	fault_handler, /* SecureFault */
	0, 0, 0,
	fault_handler, /* SVC */
	fault_handler, /* DebugMon */
	0,
	fault_handler, /* PendSV */
	fault_handler, /* SysTick */
};
