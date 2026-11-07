/* SPDX-License-Identifier: MIT */
#include "ram_api.h"
#define PK_DETAIL /* the status codes, for the host */
#include "pmic_kick.h"

/* Kick the temple's nPM1300 watchdog once and return pmic_kick()'s status (0 = kicked). The tool
 * runs it right after it has checked the bootloader at the start of every session, and before
 * every program that does not kick (checksum) and every idle G2TX. The arguments are not used.
 */
uint32_t entry(const ram_api *api, uint32_t unused0, uint32_t unused1) {
    (void)api;
    (void)unused0;
    (void)unused1;
    return pmic_kick();
}
