/* SPDX-License-Identifier: MIT */
/* One kick of the temple's nPM1300 watchdog, from a RAM program the patched loader runs.
 * docs/wisp/recovery.md, "The temple's watchdog: the nPM1300".
 *
 * The stock 2.4.0.24 app arms the nPM1300 PMIC's timer as a watchdog (reset mode, 30.72 s) and
 * kicks it every second. The case relay's reset restarts the Apollo510 but not the PMIC, and
 * neither the bootloader nor drdaeman's loader kicks it, so a held loader session is power-cycled
 * about 30 s after the app's last kick. pmic_kick() is one kick, the way the stock app does it:
 * the I2C write {0x07, 0x04, 0x01} (TIMER base 0x07, TASKWDOGKICK 0x04, value 1) to the PMIC at
 * 0x6B on IOM7. It does not arm, stop or reconfigure anything: a watchdog that is not running stays
 * off, and one that is running keeps its period and its reset action.
 *
 * Valid only with the pinned patched 2.3.2.14 bootloader in MRAM, which every session CRC-checks
 * before the tool runs any of these programs (wisp_w18/session.py). From that bootloader:
 *   - HAL_I2CInit (0x430852) sets up IOM7 for the PMIC bus (GPIO22/23 in their I2C function),
 *     then puts IOM7 in deep sleep with its registers saved in IOM7's HAL handle, 0x200181F8.
 *     The I2C table entry at 0x200003E8 holds {7, that handle}.
 *   - am_hal_iom_power_ctrl (0x42CCD0): WAKE with retain powers IOM7 and restores exactly those
 *     registers; DEEPSLEEP with retain saves them and powers IOM7 off again. pmic_kick() calls it
 *     once each way, so on success IOM7 ends as it started. If the power-down is refused (IOM7
 *     not idle after a failed write: 0x200, 0x400, 0x603), IOM7 stays powered without saved
 *     state, and every later WAKE with retain is refused (0x107) until the temple resets. The
 *     long programs stop at that point (pmic_kick_due) instead of running on unfed.
 *   - xTaskGetTickCount (0x4160E8), 1024 ticks a second: the clock the loader itself uses.
 * Between the two power_ctrl calls this touches IOM7's transfer registers only (the sequence of
 * am_hal_iom_blocking_transfer for a 3-byte write without an offset): writes INTEN, INTCLR,
 * DEVCFG, OFFSETHI, FIFOPUSH, CMD; reads STATUS, FIFOPTR, INTSTAT, INTEN. Nothing else: no other
 * peripheral, no MRAM, no other PMIC register. Every wait is bounded. Any failure returns nonzero
 * and leaves the watchdog unfed, so the PMIC resets the temple, as it does without this code.
 */
#pragma once
#include <stdint.h>

#define PK_IOM7(offset) (*(volatile uint32_t *)(uintptr_t)(0x40057000u + (offset)))
#define PK_HANDLE ((void *)0x200181f8u)
#define PK_TABLE_ENTRY ((const volatile uint32_t *)0x200003e8u)
#define PK_POWER ((uint32_t (*)(void *, uint32_t, uint32_t))0x0042ccd1u)
#define PK_TICK (((uint32_t (*)(void))0x004160e9u)())

enum {
    PK_FIFOPTR = 0x100u, /* FIFO0REM, bits 15:8: free bytes in the write FIFO */
    PK_FIFOPUSH = 0x10cu,
    PK_CMD = 0x120u,
    PK_OFFSETHI = 0x128u,
    PK_INTEN = 0x200u,
    PK_INTSTAT = 0x204u,
    PK_INTCLR = 0x208u,
    PK_STATUS = 0x248u,
    PK_DEVCFG = 0x2c4u,
    PK_IDLE_MASK = 0x6u, /* STATUS: IDLEST (bit 2) set and CMDACT (bit 1) clear = idle */
    PK_IDLE = 0x4u,
    PK_CMDCMP = 0x1u,
    PK_ERRORS = 0x27cu, /* INTSTAT: FUNDFL, FOVFL, NAK, IACC, ICMD, ARB */
    PK_WAKE = 0u,
    PK_DEEPSLEEP = 2u,
    PK_PMIC = 0x6bu,
    PK_KICK = 0x00010407u, /* the FIFO sends the low byte first: 07 04 01 */
    PK_WRITE_3 = (3u << 8) | 1u, /* CMD: WRITE, TSIZE 3, OFFSETCNT 0, no CONT */
    PK_WAIT = 200000u, /* polls; a 4-byte I2C write takes well under 1 ms */
    PK_EVERY = 1024u /* ticks between kicks: one second, as the stock app */
};

/* Status codes: feed.bin defines PK_DETAIL before including this file and returns every code
 * below to the host. The long programs (which must fit in the loader's 512 bytes) only learn of
 * the failures after which no later kick can work, as 1: the I2C table check (PK_FATAL) and a
 * refused power-up, which is also what every kick after a refused power-down gets. Other failures
 * (PK_CODE: a NAK, a timeout) count as 0 there and are simply retried a second later. */
#ifdef PK_DETAIL
#define PK_FATAL(code) (code)
#define PK_CODE(code) (code)
#else
#define PK_FATAL(code) 1u
#define PK_CODE(code) 0u
#endif

/* 0 = kicked. 0x10: the I2C table is not the pinned bootloader's. 0x1nn: power-up failed (HAL
 * status nn). 0x200: IOM7 busy before the write. 0x300: no FIFO room. 0x400: the write did not
 * finish. 0x5nnnn: the write failed (INTSTAT bits nnnn: 0x10 NAK, 0x200 arbitration lost, ...).
 * 0x6nn: the write went out but the power-down failed (HAL status nn). */
static uint32_t pmic_kick(void) {
    if (PK_TABLE_ENTRY[0] != 7u || PK_TABLE_ENTRY[1] != (uint32_t)(uintptr_t)PK_HANDLE)
        return PK_FATAL(0x10u);
    uint32_t status = PK_POWER(PK_HANDLE, PK_WAKE, 1u), result = 0, n = 0;
    if (status)
        return PK_FATAL(0x100u | (status & 0xffu));
    while ((PK_IOM7(PK_STATUS) & PK_IDLE_MASK) != PK_IDLE)
        if (++n > PK_WAIT) {
            result = PK_CODE(0x200u);
            goto sleep;
        }
    uint32_t inten = PK_IOM7(PK_INTEN);
    PK_IOM7(PK_INTEN) = 0;
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    if (((PK_IOM7(PK_FIFOPTR) >> 8) & 0xffu) < 4u) {
        result = PK_CODE(0x300u);
        goto restore;
    }
    PK_IOM7(PK_DEVCFG) = PK_PMIC;
    PK_IOM7(PK_OFFSETHI) = 0;
    PK_IOM7(PK_FIFOPUSH) = PK_KICK;
    PK_IOM7(PK_CMD) = PK_WRITE_3;
    /* Done when the command completed or failed and the IOM is idle again. */
    for (n = 0; !(PK_IOM7(PK_INTSTAT) & (PK_CMDCMP | PK_ERRORS)) ||
                (PK_IOM7(PK_STATUS) & PK_IDLE_MASK) != PK_IDLE;)
        if (++n > PK_WAIT) {
            result = PK_CODE(0x400u);
            goto restore;
        }
    uint32_t errors = PK_IOM7(PK_INTSTAT) & PK_ERRORS;
    if (errors)
        result = PK_CODE(0x50000u | errors);
restore:
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    PK_IOM7(PK_INTEN) = inten;
sleep:
    status = PK_POWER(PK_HANDLE, PK_DEEPSLEEP, 1u);
    if (status && !result)
        result = PK_CODE(0x600u | (status & 0xffu));
    return result;
}

/* Kick if at least PK_EVERY ticks passed since the last attempt (start with *last = PK_TICK -
 * PK_EVERY, so that the first call kicks). Returns 0, or nonzero when the kick could not even
 * power IOM7: no later kick can work then, and the caller stops cleanly with its own result code
 * rather than carry on until the unfed PMIC power-cycles the temple in the middle of a write. */
__attribute__((unused)) static uint32_t pmic_kick_due(uint32_t *last) {
    uint32_t now = PK_TICK;
    if ((uint32_t)(now - *last) < PK_EVERY)
        return 0;
    *last = now;
    return pmic_kick();
}
