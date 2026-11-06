/*
 * SPDX-License-Identifier: MIT
 *
 * Rung-3 fault-injection app: stands in for the Wisp app at 0x448000 behind Wisp Boot.
 * One build per behaviour (CMake -DFAULT_<MODE>=1):
 *
 *   GOOD         prints, feeds the watchdog, confirms the boot through Wisp Boot's services,
 *                keeps feeding and printing heartbeats
 *   HANG         prints once, then spins without feeding (watchdog reset)
 *   CRASH_RESET  faults on its first instruction (reset handler = udf); its fault handler spins
 *   ERASED       not an app: the slot is all 0xFF (built from this file only to get a size)
 *   CRASH_AFTER  runs and feeds for FAULT_AFTER_MS, then calls through a bad pointer; its fault
 *                handler spins (watchdog reset)
 *   NO_FEED      runs normally with heartbeats but never feeds the watchdog
 *
 * Timing is by busy loops at Renode's 250 MIPS (about 1 ms per 83k iterations of 3 instr).
 */
#include <stdint.h>

#include "boot_services.h"

#define UART1_DR  (*(volatile uint32_t *)0x4003A000u)
#define UART1_FR  (*(volatile uint32_t *)0x4003A018u)
#define WDT_RSTRT (*(volatile uint32_t *)0x40024004u)

#ifndef FAULT_AFTER_MS
#define FAULT_AFTER_MS 300
#endif

__attribute__((unused)) static void put(const char *s)
{
	while (*s) {
		while (UART1_FR & 0x20u) {
		}
		UART1_DR = (uint8_t)*s++;
	}
}

__attribute__((unused)) static void feed(void)
{
	WDT_RSTRT = 0xB2u;
}

__attribute__((unused)) static void delay_ms(uint32_t ms)
{
	for (volatile uint32_t i = 0; i < ms * 83000u; i++) {
	}
}

_Noreturn static void spin(void)
{
	for (;;) {
	}
}

__attribute__((used)) _Noreturn void app_fault(void)
{
	put("wisp-app: FAULT handler, spinning\n");
	spin();
}

_Noreturn void app_main(void)
{
#if defined(FAULT_GOOD)
	const struct wisp_boot_services *svc = (const void *)WISP_BOOT_SERVICES_ADDR;

	put("wisp-app: up (good)\n");
	feed();
	delay_ms(100);
	feed();
	if (svc->magic == WISP_BOOT_SERVICES_MAGIC && svc->confirm() == 0) {
		put("wisp-app: boot confirmed\n");
	} else {
		put("wisp-app: confirm FAILED\n");
	}
	for (;;) {
		feed();
		delay_ms(200);
		put("wisp-app: heartbeat\n");
	}
#elif defined(FAULT_HANG)
	put("wisp-app: up (hang)\n");
	spin();
#elif defined(FAULT_CRASH_AFTER)
	put("wisp-app: up (crash after " "300" " ms)\n");
	for (uint32_t t = 0; t < FAULT_AFTER_MS; t += 50) {
		feed();
		delay_ms(50);
	}
	put("wisp-app: crashing now\n");
	((void (*)(void))0x00000000u)(); /* bit 0 clear: INVSTATE usage fault */
	spin();
#elif defined(FAULT_NO_FEED)
	put("wisp-app: up (never feeds the watchdog)\n");
	for (;;) {
		delay_ms(500);
		put("wisp-app: heartbeat (no feed)\n");
	}
#else
	spin();
#endif
}

#if defined(FAULT_CRASH_RESET)
/* The reset handler faults on its first instruction; the fault handler spins, as a real app's
 * would (a fault inside the fault handler locks the core up on silicon, which Renode does not
 * model, see README "What Renode lacks"). */
__attribute__((naked, noreturn)) void app_reset(void)
{
	__asm volatile("udf #0");
}
#define HANDLER app_fault
#else
_Noreturn void app_reset(void)
{
	app_main();
}
#define HANDLER app_fault
#endif

extern uint32_t __app_stack;

__attribute__((section(".vectors"), used)) void (*const app_vectors[16])(void) = {
	(void (*)(void))&__app_stack, app_reset, HANDLER, HANDLER, HANDLER, HANDLER, HANDLER,
	HANDLER, 0, 0, 0, HANDLER, HANDLER, 0, HANDLER, HANDLER,
};
