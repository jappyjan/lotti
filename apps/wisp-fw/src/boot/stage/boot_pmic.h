/*
 * SPDX-License-Identifier: MIT
 *
 * One kick of the nPM1300's watchdog, bare metal (rung4.md, "W24 result and analysis", fix plan
 * 3: kick the PMIC watchdog first thing at every boot). Shared by Wisp Boot and stage-0.
 *
 * The only PMIC write this code can make is the 3-byte I2C write 07 04 01 (TIMER base 0x07,
 * TASKWDOGKICK 0x04, value 1) to the nPM1300 at 0x6B on IOM7: the bytes stock kicks with and
 * feed.bin has sent in every case session since W18 F1d. There is no function that takes other
 * bytes. A watchdog that is not running stays off; one that runs keeps its period and action.
 *
 * Register values: what the patched bootloader's own IOM7 HAL (HAL_I2CInit, which works on
 * silicon: every feed.bin kick goes through it) writes, read from a Renode trace of the real
 * bootloader: IOM7 FIFOTHR 0x1010, MI2CCFG 0x3F270, CLKCFG 0x1D0E2301, SUBMODCTRL 0x10 (the I2C
 * submodule on), pads 22/23 PINCFG 0x4200 (function 0 = M7SCL/M7SDA, open drain, pull-up);
 * IOM7 is powered by PWRCTRL DEVPWREN bit 8. The transfer is pmic_kick.h's (the HAL's blocking
 * transfer of a 3-byte write). IOM7 is powered down again afterwards, as the bootloader leaves it.
 * Every wait is bounded; any failure returns nonzero and leaves the watchdog unfed.
 */
#ifndef WISP_BOOT_PMIC_H
#define WISP_BOOT_PMIC_H

#include <stdint.h>

/* 0 = kicked. 0x1nn: IOM7 did not power up. 0x200: IOM7 busy before the write. 0x300: no FIFO
 * room. 0x400: the write did not finish. 0x5nnnn: the write failed (INTSTAT bits nnnn: 0x10 NAK,
 * 0x200 arbitration lost, ...). Same codes as pmic_kick.h where they overlap. */
uint32_t boot_pmic_kick(void);

#endif /* WISP_BOOT_PMIC_H */
