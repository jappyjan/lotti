/* SPDX-License-Identifier: MIT */
#include "ram_api.h"
#pragma clang diagnostic ignored "-Wunused-function" /* only pmic_kick.h's bindings are used */
#include "pmic_kick.h"

/* Turns the temple's nPM1300 charger back on with the stock 2.4.0.24 settings (recovery.md,
 * "charge_on"). For a temple whose PMIC was power-cycled to its reset values (charger off,
 * rung4.md W24 (b)) and whose installed image never programs the charger, so it cannot charge in
 * the case on its own.
 *
 * Every transfer is a 3-byte I2C write {base, offset, value} to 0x6B, sent exactly as pmic_kick.h
 * sends the watchdog kick (the same IOM7 registers and checks, power_ctrl WAKE and DEEPSLEEP with
 * retain once each). The first is the kick itself; then the stock values of the left temple's
 * snapshot (W21, apps/wisp-fw/images/pmic-baseline-w21.json), in the order Zephyr's npm13xx
 * charger driver programs them: NTC resistor and thresholds, termination voltages, charge and
 * discharge currents, VBUS limit (and its update task), low-battery charging, clear the charger
 * errors, enable. On a PMIC that already holds stock's settings every write leaves the register as
 * it is. No rail, timer, ship or GPIO register is written. It sends nothing to the host: the tool
 * runs pmic_read.bin next, in the same session, to read every register back.
 *
 * Result: 0 = done; 0x10 = the I2C table is not the pinned bootloader's (nothing called); 0x1nn =
 * the power-up failed (HAL status nn; nothing sent on the bus); 0x6nn = the power-down failed
 * after every write succeeded; otherwise (k << 24) | code: write k failed (0 = the kick, k >= 1 =
 * pins.CHARGE_ON_WRITES[k - 1]) and none after it was sent, code 0x200 IOM7 not idle, 0x300 no
 * room in the write FIFO, 0x400 no completion, 0x5nnnn an I2C error (INTSTAT bits; 0x10 = NAK).
 */

/* {base, offset, value}: the kick, then pins.CHARGE_ON_WRITES. */
static const uint8_t writes[] = {
    0x07, 0x04, 0x01, /* TIMER TASKWDOGKICK: the kick */
    0x05, 0x0a, 0x03, /* ADC NTCR_SEL: 100 kOhm NTC */
    0x03, 0x10, 0xc9, 0x03, 0x11, 0x01, /* NTC cold */
    0x03, 0x12, 0xae, 0x03, 0x13, 0x01, /* NTC cool */
    0x03, 0x14, 0x4a, 0x03, 0x15, 0x01, /* NTC warm */
    0x03, 0x16, 0x2e, 0x03, 0x17, 0x03, /* NTC hot */
    0x03, 0x0c, 0x0d, /* VTERM 4.45 V */
    0x03, 0x0d, 0x06, /* VTERM_R (warm) 4.10 V */
    0x03, 0x08, 0x18, 0x03, 0x09, 0x00, /* ISET 96 mA */
    0x03, 0x0a, 0x9b, 0x03, 0x0b, 0x00, /* ISET_DISCHG 1000 mA */
    0x02, 0x01, 0x05, /* VBUSIN ILIM 500 mA */
    0x02, 0x00, 0x01, /* VBUSIN TASKUPDATEILIMSW */
    0x03, 0x50, 0x01, /* VBATLOW_EN: charge a low battery */
    0x03, 0x00, 0x01, /* ERR_CLR */
    0x03, 0x04, 0x01, /* EN_SET: charging on */
    0x00, /* padding: an even image size; not a write (the loop takes whole triplets) */
};

/* One 3-byte write {w[0], w[1], w[2]} to the PMIC, as pmic_kick(). 0 or a failure code. */
static uint32_t write3(const uint8_t *w) {
    uint32_t n = 0;
    while ((PK_IOM7(PK_STATUS) & PK_IDLE_MASK) != PK_IDLE)
        if (++n > PK_WAIT)
            return 0x200u;
    if (((PK_IOM7(PK_FIFOPTR) >> 8) & 0xffu) < 4u)
        return 0x300u;
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    PK_IOM7(PK_DEVCFG) = PK_PMIC;
    PK_IOM7(PK_OFFSETHI) = 0;
    PK_IOM7(PK_FIFOPUSH) = w[0] | (uint32_t)w[1] << 8 | (uint32_t)w[2] << 16;
    PK_IOM7(PK_CMD) = PK_WRITE_3;
    /* Done when the command completed or failed and the IOM is idle again. */
    for (n = 0; !(PK_IOM7(PK_INTSTAT) & (PK_CMDCMP | PK_ERRORS)) ||
                (PK_IOM7(PK_STATUS) & PK_IDLE_MASK) != PK_IDLE;)
        if (++n > PK_WAIT)
            return 0x400u;
    uint32_t errors = PK_IOM7(PK_INTSTAT) & PK_ERRORS;
    return errors ? 0x50000u | errors : 0;
}

uint32_t entry(const ram_api *api, uint32_t unused0, uint32_t unused1) {
    (void)api;
    (void)unused0;
    (void)unused1;
    if (PK_TABLE_ENTRY[0] != 7u || PK_TABLE_ENTRY[1] != (uint32_t)(uintptr_t)PK_HANDLE)
        return 0x10u;
    uint32_t status = PK_POWER(PK_HANDLE, PK_WAKE, 1u), result = 0, k = 0;
    if (status)
        return 0x100u | (status & 0xffu);
    uint32_t inten = PK_IOM7(PK_INTEN);
    PK_IOM7(PK_INTEN) = 0;
    for (; k < sizeof writes / 3; k++)
        if ((result = write3(writes + 3 * k)) != 0) {
            result |= k << 24;
            break;
        }
    PK_IOM7(PK_INTCLR) = 0xffffffffu;
    PK_IOM7(PK_INTEN) = inten;
    status = PK_POWER(PK_HANDLE, PK_DEEPSLEEP, 1u);
    if (status && !result)
        result = 0x600u | (status & 0xffu);
    return result;
}
