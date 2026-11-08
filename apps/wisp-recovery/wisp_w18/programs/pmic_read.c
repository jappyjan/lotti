/* SPDX-License-Identifier: MIT */
#include "ram_api.h"
#pragma clang diagnostic ignored "-Wunused-function" /* only pmic_kick.h's bindings are used */
#include "pmic_kick.h"

/* A read-only snapshot of the temple's nPM1300 (docs/wisp/rung4.md §4, G3; recovery.md,
 * "pmic_read and peek").
 *
 * Reads every register of the allowlist below, one I2C write-read each: a 2-byte register address
 * (high byte first: the IOM sends OFFSETHI before OFFSETLO), a repeated start, one data byte. The
 * reads never send a data byte to the PMIC. The allowlist is baked into this pinned image, so the
 * host cannot name another register (wisp_w18/pins.py PMIC_READ_REGISTERS lists the same registers
 * in the same order; tests/test_pmic_read.py checks the wire under Unicorn).
 *
 * The only PMIC write is one watchdog kick before the reads: {0x07, 0x04, 0x01} to 0x6B, the write
 * the stock app makes every second and pmic_kick.h makes for feed and dump_fed, with the same
 * register sequence (the same bindings into the pinned bootloader, the same I2C table check). It
 * shares the reads' power window to fit the loader's 512 bytes. The program runs for well under a
 * second (59 short transfers, then four loader exchanges), so one kick keeps the temple fed as
 * dump_fed's once-a-second kicks do.
 *
 * IOM7 is used exactly as the kick uses it: power_ctrl WAKE with retain, the transfer registers
 * only (writes INTEN, INTCLR, DEVCFG, OFFSETHI, FIFOPUSH, CMD; reads STATUS, FIFOPTR, INTSTAT,
 * INTEN, FIFOPOP), power_ctrl DEEPSLEEP with retain. Every wait is bounded.
 *
 * Output: one byte per register, in table order (send() splits it into 16-byte replies).
 * Result: 0 = done; 1 = the send failed; 0x10 = the I2C table is not the pinned bootloader's
 * (nothing called); 0x1nn = the power-up failed (HAL status nn; nothing sent on the bus); 0x6nn =
 * the power-down failed after every transfer succeeded; otherwise (k << 24) | code: transfer k
 * failed (0 = the kick, k >= 1 = the read of table entry k - 1), nothing was sent to the host, and
 * code is 0x200 IOM7 not idle or bytes left in its receive FIFO, 0x300 no room in the write FIFO,
 * 0x400 no completion, 0x5nnnn an I2C error (INTSTAT bits; 0x10 = NAK), 0x800 no byte received.
 */

/* {base << 4 | count, first offset}: count consecutive registers at base:offset. Bases (the ones
 * Zephyr's npm13xx drivers use): 0x02 VBUSIN, 0x03 BCHARGER, 0x04 BUCK, 0x05 ADC, 0x06 GPIOS,
 * 0x07 TIMER, 0x08 LDSW, 0x0B SHIP. */
static const uint8_t ranges[] = {
    0x22, 0x01, /* ILIM, ILIMSTARTUP */
    0x21, 0x05, /* DETECT */
    0x21, 0x07, /* STATUS */
    0x31, 0x04, /* charger enable (EN_SET read back) */
    0x38, 0x08, /* ISET (2), ISET_DISCHG (2), VTERM, VTERM_R, TRICKLE_SEL, ITERM_SEL */
    0x38, 0x10, /* NTC_TEMPS: cold, cool, warm, hot (MSB, LSB) */
    0x31, 0x34, /* CHG_STAT */
    0x31, 0x36, /* ERR_REASON */
    0x31, 0x50, /* VBATLOW_EN */
    0x48, 0x08, /* VOUT_NORM, VOUT_RET of BUCK1 and BUCK2; EN_CTRL, VRET_CTRL, PWM_CTRL, SW_CTRL */
    0x42, 0x10, /* VOUT_STAT BUCK1, BUCK2 */
    0x41, 0x15, /* CTRL0 */
    0x41, 0x34, /* STATUS */
    0x52, 0x09, /* ADC CONFIG, NTCR_SEL */
    0x65, 0x00, /* GPIO0..4 MODE */
    0x61, 0x1e, /* GPIO STATUS */
    0x71, 0x05, /* TIMERCONFIG */
    0x73, 0x08, /* TIMER target HI, MID, LO */
    0x86, 0x04, /* LDSW STATUS, GPISEL1, GPISEL2, CONFIG, LDOSEL1, LDOSEL2 */
    0x82, 0x0c, /* VOUTSEL1, VOUTSEL2 */
    0xb1, 0x04, /* SHIP CONFIG */
    0xb1, 0x06, /* LPCONFIG */
};
enum {
    PR_COUNT = 58, /* registers in the table */
    PR_FIFOPOP = 0x108u,
    PR_READ_1 = (1u << 8) | (2u << 4) | 2u /* CMD: READ, TSIZE 1, OFFSETCNT 2 (OFFSETHI first) */
};

/* Bounded wait until IOM7 is idle and, with `command`, the command completed or failed. */
static int settle(uint32_t command) {
    for (uint32_t n = 0;
         (command && !(PK_IOM7(PK_INTSTAT) & (PK_CMDCMP | PK_ERRORS))) ||
         (PK_IOM7(PK_STATUS) & PK_IDLE_MASK) != PK_IDLE;)
        if (++n > PK_WAIT)
            return 1;
    return 0;
}

/* One transfer to the PMIC: the kick (a 3-byte write, cmd PK_WRITE_3) or a one-byte register read
 * (cmd PR_READ_1 with the low address byte in OFFSETLO). 0 or a failure code. */
static uint32_t transfer(uint32_t offsethi, uint32_t cmd) {
    uint32_t write = cmd == PK_WRITE_3, fifo;
    if (settle(0) || ((fifo = PK_IOM7(PK_FIFOPTR)) >> 16) & 0xffu)
        return 0x200u;
    if (write && ((fifo >> 8) & 0xffu) < 4u)
        return 0x300u;
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    PK_IOM7(PK_DEVCFG) = PK_PMIC;
    PK_IOM7(PK_OFFSETHI) = offsethi;
    if (write)
        PK_IOM7(PK_FIFOPUSH) = PK_KICK;
    PK_IOM7(PK_CMD) = cmd;
    if (settle(1))
        return 0x400u;
    uint32_t errors = PK_IOM7(PK_INTSTAT) & PK_ERRORS;
    if (errors)
        return 0x50000u | errors;
    if (!write && !((PK_IOM7(PK_FIFOPTR) >> 16) & 0xffu))
        return 0x800u;
    return 0;
}

uint32_t entry(const ram_api *api, uint32_t unused0, uint32_t unused1) {
    (void)unused0;
    (void)unused1;
    uint8_t out[PR_COUNT];
    if (PK_TABLE_ENTRY[0] != 7u || PK_TABLE_ENTRY[1] != (uint32_t)(uintptr_t)PK_HANDLE)
        return 0x10u;
    uint32_t status = PK_POWER(PK_HANDLE, PK_WAKE, 1u), result, k = 0, transfers = 0;
    if (status)
        return 0x100u | (status & 0xffu);
    uint32_t inten = PK_IOM7(PK_INTEN);
    PK_IOM7(PK_INTEN) = 0;
    result = transfer(0, PK_WRITE_3);
    for (const uint8_t *r = ranges; !result && r < ranges + sizeof ranges; r += 2)
        for (uint32_t i = 0; !result && i < (r[0] & 15u); i++) {
            transfers = k + 1;
            result = transfer(r[0] >> 4, ((uint32_t)(r[1] + i) << 24) | PR_READ_1);
            if (!result)
                out[k++] = (uint8_t)PK_IOM7(PR_FIFOPOP);
        }
    if (result)
        result |= transfers << 24;
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    PK_IOM7(PK_INTEN) = inten;
    status = PK_POWER(PK_HANDLE, PK_DEEPSLEEP, 1u);
    if (status && !result)
        result = 0x600u | (status & 0xffu);
    if (result)
        return result;
    return api->send(api->context, out, PR_COUNT) ? 1u : 0u;
}
