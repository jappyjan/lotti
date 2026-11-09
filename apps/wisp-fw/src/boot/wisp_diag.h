/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp diagnostics record (rung4.md, "W24 result and analysis", D1) and the boot report (D2).
 *
 * D1: a 64-byte record at a fixed RAM address, the first bytes of Wisp Boot's own RAM, which no
 * reset handler copies or zeroes. Wisp Boot reads the previous boot's record first thing (before
 * its .data/.bss set-up touches anything), keeps a copy in its status block, then starts a fresh
 * one: the reset cause (RSTGEN.STAT), a boot counter, a breadcrumb (the last stage reached and
 * when) and, if a fault handler ran, the fault. Wisp Boot and the app behind it (stage-0) both
 * write breadcrumbs into it. Whether SRAM survives a watchdog reset or an SWPOR on this chip is
 * open (hardware.md); the magic and the CRC tell, and the boot report says whether the previous
 * record was valid.
 *
 * D2: the boot report, one case-UART reply (op 0x04, docs/wisp/case-uart.md): why the previous
 * boot ended and how far it got, in 22 data bytes. Wisp Boot answers it in a short window right
 * after it arms the watchdog; the app answers it too.
 *
 * Shared by Wisp Boot, stage-0 and the host decoders (tests/boot/case_uart.py,
 * apps/wisp-recovery wisp_w18/case_uart.py). Little-endian; the _Static_asserts pin the layout.
 * Header only, no dependencies: the CRC here is a plain bitwise zlib CRC-32.
 */
#ifndef WISP_DIAG_H
#define WISP_DIAG_H

#include <stdint.h>

#define WISP_DIAG_ADDR    0x20370000u /* WISP_BOOT_RAM_BASE: the .noinit slot of boot.ld */
#define WISP_DIAG_MAGIC   0x47414457u /* "WDAG" little-endian */
#define WISP_DIAG_VERSION 1u

/* Apollo510 RSTGEN.STAT (hal_ambiq apollo510.h: RSTGEN_Type, size 0x8860, STAT last). Read only;
 * the HAL itself warns never to write it. */
#define WISP_RSTGEN_STAT_ADDR 0x4000885Cu
#define WISP_RSTGEN_STAT_EXRSTAT  0x0001u /* external reset (the case's reset line) */
#define WISP_RSTGEN_STAT_POASTAT  0x0002u /* power-on */
#define WISP_RSTGEN_STAT_BORSTAT  0x0004u
#define WISP_RSTGEN_STAT_SWRSTAT  0x0008u /* software POR (SWPOR, what Wisp uses) */
#define WISP_RSTGEN_STAT_POIRSTAT 0x0010u
#define WISP_RSTGEN_STAT_DBGRSTAT 0x0020u
#define WISP_RSTGEN_STAT_WDRSTAT  0x0040u /* watchdog */
#define WISP_RSTGEN_STAT_AIRCRSTAT 0x1000u /* SYSRESETREQ */

/* STIMER (the bootloader runs it from the 32 kHz crystal: STCFG CLKSEL 3) */
#define WISP_STIMER_STCFG 0x40008800u
#define WISP_STIMER_STTMR 0x40008804u

/* Stage codes (breadcrumbs). 0x10-0x3F Wisp Boot, 0x40-0x7F stage-0, 0x80-0xFF other apps. */
enum wisp_diag_stage {
	WISP_DIAG_NONE = 0x00,
	WISP_DIAG_BOOT_START = 0x10,    /* Wisp Boot: watchdog armed, record started */
	WISP_DIAG_BOOT_PMIC = 0x11,     /* the nPM1300 watchdog kick returned */
	WISP_DIAG_BOOT_WINDOW = 0x12,   /* the case-UART boot-report window is open */
	WISP_DIAG_BOOT_WINDOW_END = 0x13,
	WISP_DIAG_BOOT_NOR = 0x14,      /* NOR init started */
	WISP_DIAG_BOOT_MOUNTED = 0x15,  /* littlefs mounted */
	WISP_DIAG_BOOT_INPUTS = 0x16,   /* record, staging, rescue.bin, inventory read */
	WISP_DIAG_BOOT_DECIDED = 0x17,
	WISP_DIAG_BOOT_HANDOFF = 0x18,  /* about to jump to the app */
	WISP_DIAG_BOOT_RESET = 0x19,    /* Wisp Boot resets on purpose (rescue, no app) */
	WISP_DIAG_BOOT_FAULT = 0x1F,    /* a fault handler in Wisp Boot ran */
	WISP_DIAG_S0_RESET = 0x40,      /* stage-0: reset handler entered */
	WISP_DIAG_S0_INIT = 0x41,       /* .data/.bss ready */
	WISP_DIAG_S0_UART = 0x42,       /* UART2 set up */
	WISP_DIAG_S0_FEED = 0x43,       /* first Apollo watchdog feed */
	WISP_DIAG_S0_KICK = 0x44,       /* first PMIC watchdog kick returned */
	WISP_DIAG_S0_LOOP = 0x45,       /* main loop running */
	WISP_DIAG_S0_MEASURE = 0x46,    /* measuring LFRC against the crystal (watchdog not fed) */
	WISP_DIAG_S0_RESET_REQ = 0x47,  /* resetting on a case-UART RESET */
	WISP_DIAG_S0_FAULT = 0x4F,      /* a fault handler in stage-0 ran */
	/* The Zephyr app (native-1 on, src/diag/wisp_app_diag.c): last value wins. */
	WISP_DIAG_APP_SOC = 0x80,       /* soc_early_init_hook entered (z_prep_c done) */
	WISP_DIAG_APP_SOC_DONE = 0x81,  /* ... its power, clock and cache set-up returned */
	WISP_DIAG_APP_PRE1 = 0x82,      /* PRE_KERNEL_1 started */
	WISP_DIAG_APP_PRE1_END = 0x83,  /* PRE_KERNEL_1 devices (GPIO, UARTs) done */
	WISP_DIAG_APP_PRE2 = 0x84,      /* PRE_KERNEL_2 started (the system timer comes up here) */
	WISP_DIAG_APP_STIMER_OK = 0x85, /* the STIMER counts (D5) */
	WISP_DIAG_APP_POST = 0x86,      /* POST_KERNEL started: threads run */
	WISP_DIAG_APP_POST_BUSES = 0x87,/* POST_KERNEL: I2C, SPI and MSPI controllers done */
	WISP_DIAG_APP_POST_END = 0x88,  /* POST_KERNEL devices (sensors, panel) done */
	WISP_DIAG_APP_PMIC_THREAD = 0x89, /* the PMIC watchdog thread runs */
	WISP_DIAG_APP_PMIC_ARMED = 0x8A,  /* the nPM1300 watchdog armed with stock's writes */
	WISP_DIAG_APP_MAIN = 0x8B,      /* main() entered */
	WISP_DIAG_APP_CASE = 0x8C,      /* the case-UART thread started */
	WISP_DIAG_APP_HAL = 0x8D,       /* the native HAL is up */
	WISP_DIAG_APP_DISPLAY = 0x8E,   /* the boot screen is drawn (or the panel refused) */
	WISP_DIAG_APP_BT_START = 0x8F,  /* bt_enable() running (the EM9305 bring-up) */
	WISP_DIAG_APP_BT_UP = 0x90,     /* Bluetooth up, advertising */
	WISP_DIAG_APP_BT_FAILED = 0x91, /* Bluetooth unavailable */
	WISP_DIAG_APP_IDLE = 0x92,      /* main's start-up is over */
	WISP_DIAG_APP_SESSION = 0x93,   /* a BLE session completed HELLO */
	WISP_DIAG_APP_SOC_LP = 0x94,    /* soc: am_hal_pwrctrl_low_power_init returned */
	WISP_DIAG_APP_SOC_BUCK = 0x95,  /* soc: SIMOBUCK_INIT returned */
	WISP_DIAG_APP_SOC_TEMP = 0x96,  /* soc: temp_update returned (caches next) */
	WISP_DIAG_APP_STIMER_DEAD = 0x9E, /* D5: the STIMER does not count; the fallback loop runs */
	WISP_DIAG_APP_FAULT = 0x9F,     /* the app's fatal-error handler ran (fault recorded) */
	WISP_DIAG_APP_RESET_REQ = 0xA0, /* resetting on a case-UART RESET */
	WISP_DIAG_APP_WDT_STARVED = 0xA1, /* the liveness check stopped feeding the Apollo WDT */
};

#define WISP_DIAG_F_FAULT 0x0001u /* the fault fields are set */

struct wisp_diag_record {
	uint32_t magic;        /* WISP_DIAG_MAGIC */
	uint16_t version;      /* WISP_DIAG_VERSION */
	uint16_t size;         /* sizeof(struct wisp_diag_record) */
	uint32_t boots;        /* this boot's number: previous valid record's + 1, else 1 */
	uint32_t rstgen_stat;  /* RSTGEN.STAT as Wisp Boot read it at the start of this boot */
	uint32_t stimer_start; /* STTMR when Wisp Boot started */
	uint16_t stage;        /* the last breadcrumb (enum wisp_diag_stage) */
	uint16_t flags;        /* WISP_DIAG_F_* */
	uint32_t stage_ticks;  /* STTMR - stimer_start at the last breadcrumb */
	uint32_t fault_pc;     /* stacked PC, LR, xPSR of the faulting context */
	uint32_t fault_lr;
	uint32_t fault_xpsr;
	uint32_t cfsr;         /* SCB CFSR, HFSR, BFAR, MMFAR at the fault */
	uint32_t hfsr;
	uint32_t bfar;
	uint32_t mmfar;
	uint32_t exc_return;   /* the handler's LR */
	uint32_t crc;          /* zlib CRC-32 of every byte before it */
};

_Static_assert(sizeof(struct wisp_diag_record) == 64, "diag record layout");
_Static_assert(__builtin_offsetof(struct wisp_diag_record, stage) == 20, "diag record layout");
_Static_assert(__builtin_offsetof(struct wisp_diag_record, fault_pc) == 28, "diag record layout");
_Static_assert(__builtin_offsetof(struct wisp_diag_record, crc) == 60, "diag record layout");

/* The boot report (case-UART op 0x04): 22 data bytes. */
#define WISP_BOOT_REPORT_SIZE 22u
#define WISP_REPORT_SRC_BOOT 0u /* answered by Wisp Boot in its window */
#define WISP_REPORT_SRC_APP  1u /* answered by the app */
/* flags */
#define WISP_REPORT_F_PREV_VALID 0x01u /* the previous boot's record had a valid magic and CRC */
#define WISP_REPORT_F_PREV_FAULT 0x02u /* ... and a fault recorded */
#define WISP_REPORT_F_KICK_OK    0x04u /* this boot's PMIC watchdog kick by Wisp Boot succeeded */
#define WISP_REPORT_F_STIMER_XT  0x08u /* the STIMER runs from the crystal (STCFG CLKSEL 3) */

/*
 *  0  u8   source (WISP_REPORT_SRC_*)
 *  1  u8   flags (WISP_REPORT_F_*)
 *  2  u8   this boot's number, low byte
 *  3  u8   the previous boot's last stage
 *  4  u32  RSTGEN.STAT at the start of this boot (why the previous boot ended)
 *  8  u16  the previous boot's last stage time, ms after its Wisp Boot start (0xFFFF = later)
 * 10  u32  the previous boot's fault PC (0 = none)
 * 14  u32  ... LR
 * 18  u32  ... CFSR
 */

static inline void wisp_diag_put16(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static inline void wisp_diag_put32(uint8_t *p, uint32_t v)
{
	wisp_diag_put16(p, v);
	wisp_diag_put16(p + 2, v >> 16);
}

static inline uint32_t wisp_diag_crc32(const void *data, uint32_t n)
{
	const uint8_t *p = data;
	uint32_t crc = 0xFFFFFFFFu;

	while (n--) {
		crc ^= *p++;
		for (int k = 0; k < 8; k++) {
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
		}
	}
	return ~crc;
}

static inline volatile struct wisp_diag_record *wisp_diag(void)
{
	return (volatile struct wisp_diag_record *)WISP_DIAG_ADDR;
}

static inline void wisp_diag_seal(volatile struct wisp_diag_record *r)
{
	r->crc = wisp_diag_crc32((const void *)r, __builtin_offsetof(struct wisp_diag_record, crc));
}

static inline int wisp_diag_valid(const volatile struct wisp_diag_record *r)
{
	return r->magic == WISP_DIAG_MAGIC && r->version == WISP_DIAG_VERSION &&
	       r->size == sizeof(struct wisp_diag_record) &&
	       r->crc == wisp_diag_crc32((const void *)r,
					 __builtin_offsetof(struct wisp_diag_record, crc));
}

static inline uint32_t wisp_stimer_now(void)
{
	return *(volatile uint32_t *)WISP_STIMER_STTMR;
}

/* D-cache (rung4.md, "W24d: stage-0b"): the Even bootloader enables the I- and D-caches in its board
 * set-up and hands off with them on, and SRAM is write-back cacheable by default. A record or status
 * block still in a dirty line when the watchdog resets the chip never reaches SRAM. So every update
 * of the record (wisp_diag_mark, wisp_diag_fault, Wisp Boot's diag_begin) and of Wisp Boot's status
 * block (status_seal) ends with a clean of its lines to SRAM: SCB DCCMVAC (0xE000EF68, D-cache clean
 * by address to the point of coherency), one write per 32-byte line (the Cortex-M55's line size),
 * then DSB. With the D-cache off the writes do nothing. Cleaning was chosen over an MPU region: it
 * changes no state the app inherits, and it is local to the writers. noipa (no inlining, no clone
 * with the arguments folded in): the Renode harness hooks every copy by its symbol, reading the
 * range from r0/r1 (its D-cache model keeps only cleaned lines across a reset). */
#define WISP_DCACHE_LINE 32u
#define WISP_SCB_DCCMVAC 0xE000EF68u

static __attribute__((noipa, unused)) void wisp_dcache_clean(const volatile void *p, uint32_t n)
{
#if defined(__arm__)
	uint32_t a = (uint32_t)p & ~(WISP_DCACHE_LINE - 1u);
	const uint32_t end = (uint32_t)p + n;

	__asm volatile("dsb" ::: "memory");
	for (; a < end; a += WISP_DCACHE_LINE) {
		*(volatile uint32_t *)WISP_SCB_DCCMVAC = a;
	}
	__asm volatile("dsb" ::: "memory");
#else
	(void)p; /* host builds of the codec: no cache */
	(void)n;
#endif
}

/* A breadcrumb: last value wins. Only on a valid record (Wisp Boot started it this boot). */
static inline void wisp_diag_mark(uint16_t stage)
{
	volatile struct wisp_diag_record *r = wisp_diag();

	if (r->magic != WISP_DIAG_MAGIC) {
		return;
	}
	r->stage = stage;
	r->stage_ticks = wisp_stimer_now() - r->stimer_start;
	wisp_diag_seal(r);
	wisp_dcache_clean(r, sizeof(*r));
}

/* Fault capture for a handler: `frame` is the stacked exception frame (or 0 when it could not be
 * trusted), `exc_return` the handler's LR. Reads the fault registers and seals the record. */
static inline void wisp_diag_fault(const uint32_t *frame, uint32_t exc_return, uint16_t stage)
{
	volatile struct wisp_diag_record *r = wisp_diag();

	if (r->magic != WISP_DIAG_MAGIC) {
		return;
	}
	if (frame) {
		r->fault_lr = frame[5];
		r->fault_pc = frame[6];
		r->fault_xpsr = frame[7];
	}
	r->cfsr = *(volatile uint32_t *)0xE000ED28u;
	r->hfsr = *(volatile uint32_t *)0xE000ED2Cu;
	r->mmfar = *(volatile uint32_t *)0xE000ED34u;
	r->bfar = *(volatile uint32_t *)0xE000ED38u;
	r->exc_return = exc_return;
	r->flags |= WISP_DIAG_F_FAULT;
	r->stage = stage;
	r->stage_ticks = wisp_stimer_now() - r->stimer_start;
	wisp_diag_seal(r);
	wisp_dcache_clean(r, sizeof(*r));
}

/* The stacked frame of a fault, or 0 if the stack pointer it names is not plausible SRAM. */
static inline const uint32_t *wisp_diag_frame(uint32_t msp, uint32_t psp, uint32_t exc_return)
{
	uint32_t sp = (exc_return & 4u) ? psp : msp;

	return (sp >= 0x20000000u && sp <= 0x20380000u - 32u && !(sp & 3u)) ? (const uint32_t *)sp
									     : (const uint32_t *)0;
}

#endif /* WISP_DIAG_H */
