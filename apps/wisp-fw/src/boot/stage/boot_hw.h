/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — the few Apollo510 registers it touches. Offsets and keys: hal_ambiq CMSIS
 * apollo510.h; usage as in AmbiqSuite (am_hal_wdt.c, am_hal_reset.c, am_hal_mram.c,
 * am_hal_pwrctrl.c). Nothing here has run on glasses (rung 3 is emulation only).
 */
#ifndef WISP_BOOT_HW_H
#define WISP_BOOT_HW_H

#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))

/* RSTGEN */
#define RSTGEN_CFG   REG(0x40000000u) /* bit 1 WDREN: watchdog resets the chip */
#define RSTGEN_SWPOR REG(0x40000008u) /* 0xD4: software POR (what the Even bootloader uses) */

/* PWRCTRL */
#define PWRCTRL_DEVPWREN     REG(0x40021004u)
#define PWRCTRL_DEVPWRSTATUS REG(0x40021008u)
#define PWRCTRL_MEMPWREN     REG(0x40021014u)
#define PWRCTRL_MEMPWRSTATUS REG(0x40021018u)
#define PWRCTRL_DEV_MSPI1    0x8000u
#define PWRCTRL_MEM_ROM_EN   0x20u
#define PWRCTRL_MEM_ROM_ST   0x80u

/* WDT */
#define WDT_CFG   REG(0x40024000u)
#define WDT_RSTRT REG(0x40024004u)
#define WDT_LOCK  REG(0x40024008u)

/* UART1 (debug log) */
#define UART1_DR REG(0x4003A000u)
#define UART1_FR REG(0x4003A018u)

/* SCB / NVIC / SysTick */
#define SCB_ICSR  REG(0xE000ED04u)
#define SCB_ICSR_PENDSVCLR (1u << 27)
#define SCB_ICSR_PENDSTCLR (1u << 25)
#define SCB_VTOR  REG(0xE000ED08u)
#define SYST_CSR  REG(0xE000E010u)
#define NVIC_ICER(n) REG(0xE000E180u + 4u * (n))
#define NVIC_ICPR(n) REG(0xE000E280u + 4u * (n))

/* UART1 debug log: on by default (rung 3 reads it); hardware images build with 0. */
#ifndef WISP_BOOT_LOG
#define WISP_BOOT_LOG 1
#endif

void hw_wdt_arm(void);
void hw_wdt_feed(void);
void hw_log(const char *s);
void hw_log_hex(const char *label, uint32_t v);
_Noreturn void hw_reset(void);
/* Writes the documented update-flag record {0x55555555, ~0, ~0, ~0} at 0x7FE000 through the
 * boot ROM and reads it back. The only MRAM write in Wisp Boot. Returns 0 on success. */
#ifndef WISP_BOOT_OBSERVE
#define WISP_BOOT_OBSERVE 0
#endif
#if !WISP_BOOT_OBSERVE /* the observe-only build has no MRAM write code at all */
int hw_flag_set_install(void);
#endif
/* Hands over the state Zephyr assumes at reset (rung4.md W24 fix plan 3): interrupts masked, a
 * quiet NVIC, SysTick off, no pending PendSV or SysTick, Thread mode on MSP (CONTROL 0) with
 * MSPLIM/PSPLIM 0 and MSP = PSP = the app's initial SP, VTOR at the app; then unmasks and jumps. */
_Noreturn void hw_jump(uint32_t vector_table);

#endif /* WISP_BOOT_HW_H */
