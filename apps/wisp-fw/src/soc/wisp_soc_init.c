/*
 * SPDX-License-Identifier: MIT
 *
 * native-1's SoC start-up (CONFIG_WISP_SOC_INIT; Zephyr patch 0003 makes the fork's apollo5x
 * soc_early_init_hook weak). rung4.md W25 compared native-0's start-up with stock 2.4.0.24's and
 * the patched bootloader's (static analysis; addresses in rung4.md):
 *
 *   - stock's first init-table entry (0x5781BC -> 0x4E9394) makes the same three HAL calls in the
 *     same order: am_hal_pwrctrl_low_power_init (0x4951D0), SIMOBUCK_INIT (0x495588) and
 *     temp_update(25.0) (0x495710), and the bootloader the same at 0x41FA50. Every write native-0
 *     made in them has a stock counterpart with the same value (W25 table), so they stay;
 *   - SIMOBUCK_INIT returns at its first check on silicon: the bootloader leaves the SIMO buck on;
 *   - the bootloader hands off with both caches on; Zephyr's cache enables then return at once;
 *   - stock never sets SCB.CCR.LOB and never writes MCUCTRL.SCRATCH0: native-1 does neither;
 *   - RSTGEN.STAT is captured before low_power_init clears BORSTAT (ERR027), as stock reads it
 *     first (0x5781C2).
 *
 * Breadcrumbs (Wisp Boot's record) go around every call, so a hang names the step. The HAL's
 * internal timer (TIMER15, the SPOT manager's) stays connected by the fork's IRQ_CONNECT in its weak
 * hook: that registration is static, in the ISR table, whichever hook runs.
 */
#include <zephyr/cache.h>
#include <zephyr/init.h>
#include <soc.h>

#include "app_status.h"
#include "wisp_app_diag.h"

void soc_early_init_hook(void)
{
	am_hal_pwrctrl_temp_thresh_t thresholds;

	wisp_app_diag_mark(WISP_DIAG_APP_SOC);
	wisp_app_status.reset_cause = RSTGEN->STAT;

	am_hal_pwrctrl_low_power_init();
	wisp_app_diag_mark(WISP_DIAG_APP_SOC_LP);
	am_hal_pwrctrl_control(AM_HAL_PWRCTRL_CONTROL_SIMOBUCK_INIT, NULL);
	wisp_app_diag_mark(WISP_DIAG_APP_SOC_BUCK);
	am_hal_pwrctrl_temp_update(25.0f, &thresholds);
	wisp_app_diag_mark(WISP_DIAG_APP_SOC_TEMP);

	sys_cache_instr_enable();
	sys_cache_data_enable();
	wisp_app_diag_mark(WISP_DIAG_APP_SOC_DONE);
}
