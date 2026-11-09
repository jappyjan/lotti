/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — vector table and reset handler. Every fault resets the chip (the boot attempt is
 * already counted when the app can fault; inside Wisp Boot a reset is the only safe answer). The
 * fault is recorded in the diagnostics record first (wisp_diag.h), so the next boot reports it.
 */
#include <stdint.h>
#include <string.h>

#include "boot_hw.h"
#include "wisp_diag.h"

extern uint32_t __stack_top, __data_load, __data_start, __data_end, __bss_start, __bss_end;
_Noreturn void wisp_boot_main(void);

/* The diagnostics record: first in Wisp Boot's RAM (boot.ld), never copied or zeroed. */
__attribute__((section(".noinit"), used)) struct wisp_diag_record wisp_diag_slot;

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

__attribute__((used)) _Noreturn void fault_record(uint32_t msp, uint32_t psp, uint32_t exc_return)
{
	wisp_diag_fault(wisp_diag_frame(msp, psp, exc_return), exc_return, WISP_DIAG_BOOT_FAULT);
	hw_log("wisp-boot: fault -> reset\n");
	hw_reset();
}

/* r0 = MSP, r1 = PSP, r2 = EXC_RETURN; the C part never returns. */
__attribute__((naked)) _Noreturn void fault_handler(void)
{
	__asm volatile("mrs r0, msp\n"
		       "mrs r1, psp\n"
		       "mov r2, lr\n"
		       "b fault_record\n");
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
