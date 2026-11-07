/* SPDX-License-Identifier: MIT */
#include "ram_api.h"
#include "pmic_kick.h"

/* drdaeman's dump.c (g2-bootloader-patch @ 1d22097, MIT) with the temple's nPM1300 watchdog
 * fed (pmic_kick.h). Send a memory range to the host; the host supplies the start address and
 * byte count. The range goes out in send() calls of up to 16 bytes, so each call is one loader
 * exchange. On the wire that is the same as dump.c, whose 128-byte calls send() splits into
 * 16-byte replies. Before each call the watchdog is kicked if a second has passed since the last
 * kick, so a stream of any length keeps the temple from being reset, and a host that stops
 * answering stops the kicks with it. Return 0 on completion, 1 if a send fails (as dump.c), or 2
 * if a kick could not power IOM7 (pmic_kick_due; the stream stops there). A zero-length range
 * sends nothing. The entire range must be readable; invalid addresses can fault the CPU.
 */
uint32_t entry(const ram_api *api, uint32_t address, uint32_t length) {
    uint32_t last = PK_TICK - PK_EVERY;
    while (length) {
        uint32_t n = length > 16u ? 16u : length;
        if (pmic_kick_due(&last))
            return 2;
        if (api->send(api->context, (const void *)(uintptr_t)address, n))
            return 1;
        address += n;
        length -= n;
    }
    return 0;
}
