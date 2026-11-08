/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — watchdog, reset, debug log, the update-flag write, the jump to the app.
 */
#include "boot_hw.h"

#include "wisp_boot_layout.h"

/* WDT: LFRC/64 = 16 Hz, reset after WISP_BOOT_WDT_TICKS ticks (128 = 8 s) without a feed. The
 * watchdog stays armed and locked for the app, which must feed it (WDT_RSTRT = 0xB2). */
#ifndef WISP_BOOT_WDT_TICKS
#define WISP_BOOT_WDT_TICKS 128u
#endif

void hw_wdt_arm(void)
{
	RSTGEN_CFG |= 2u; /* WDREN */
	WDT_CFG = (2u << 24) | (WISP_BOOT_WDT_TICKS << 8) | (1u << 2) /* RESEN */ | 1u /* WDTEN */;
	WDT_RSTRT = 0xB2u;
	WDT_LOCK = 0x3Au;
}

void hw_wdt_feed(void)
{
	WDT_RSTRT = 0xB2u;
}

/* Debug log on UART1, polled. WISP_BOOT_LOG=0 compiles it out (hardware builds until the
 * UART1 power/pin state after the bootloader's hand-off is confirmed on glasses). */

void hw_log(const char *s)
{
#if WISP_BOOT_LOG
	while (*s) {
		for (uint32_t i = 0; (UART1_FR & 0x20u) && i < 100000u; i++) {
		}
		UART1_DR = (uint8_t)*s++;
	}
#else
	(void)s;
#endif
}

void hw_log_hex(const char *label, uint32_t v)
{
	char b[12] = "0x";

	for (int i = 0; i < 8; i++) {
		b[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 0xFu];
	}
	b[10] = '\n';
	b[11] = 0;
	hw_log(label);
	hw_log(b);
}

_Noreturn void hw_reset(void)
{
	RSTGEN_SWPOR = 0xD4u;
	for (;;) {
	}
}

#if !WISP_BOOT_OBSERVE
/* Boot ROM helper (hal_ambiq am_hal_bootrom_helper.c: nv_program_main2 at 0x0200FF20). */
typedef int (*nv_program_main2_t)(uint32_t key, uint32_t program, uint32_t src, uint32_t word_off,
				  uint32_t words);
#define NV_PROGRAM_MAIN2 ((nv_program_main2_t)(0x0200FF20u + 1u))

static const uint32_t flag_install[4] __attribute__((aligned(16))) = {
	WISP_FLAG_INSTALL, WISP_FLAG_ERASED, WISP_FLAG_ERASED, WISP_FLAG_ERASED};

int hw_flag_set_install(void)
{
	const volatile uint32_t *flag = (const volatile uint32_t *)WISP_FLAG_ADDR;
	uint32_t primask;
	int st;

	PWRCTRL_MEMPWREN |= PWRCTRL_MEM_ROM_EN;
	for (uint32_t i = 0; !(PWRCTRL_MEMPWRSTATUS & PWRCTRL_MEM_ROM_ST) && i < 100000u; i++) {
	}
	__asm volatile("mrs %0, primask\n cpsid i" : "=r"(primask)::"memory");
	st = NV_PROGRAM_MAIN2(WISP_MRAM_PROGRAM_KEY, 1u, (uint32_t)flag_install,
			      (WISP_FLAG_ADDR - WISP_MRAM_BASE) >> 2, 4u);
	__asm volatile("msr primask, %0" ::"r"(primask) : "memory");
	if (st != 0) {
		return -st;
	}
	for (int i = 0; i < 4; i++) {
		if (flag[i] != flag_install[i]) {
			return -100 - i;
		}
	}
	return 0;
}
#endif /* !WISP_BOOT_OBSERVE */

_Noreturn void hw_jump(uint32_t vt)
{
	const volatile uint32_t *v = (const volatile uint32_t *)vt;
	uint32_t sp = v[0], pc = v[1];

	__asm volatile("cpsid i" ::: "memory");
	for (int n = 0; n < 8; n++) { /* hand over a quiet NVIC */
		NVIC_ICER(n) = 0xFFFFFFFFu;
		NVIC_ICPR(n) = 0xFFFFFFFFu;
	}
	SCB_VTOR = vt;
	__asm volatile("dsb\n isb\n msr msp, %0\n cpsie i\n bx %1" ::"r"(sp), "r"(pc) : "memory");
	for (;;) {
	}
}
