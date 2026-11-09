/*
 * SPDX-License-Identifier: MIT
 *
 * PLACEHOLDER while the stock comparison runs: Zephyr's apollo5x start-up with breadcrumbs.
 */
#include <zephyr/cache.h>
#include <zephyr/init.h>
#include <soc.h>

#include "wisp_app_diag.h"

void soc_early_init_hook(void)
{
	wisp_app_diag_mark(WISP_DIAG_APP_SOC);
	SCB->CCR |= SCB_CCR_LOB_Msk;
	__DSB();
	__ISB();
	am_hal_pwrctrl_low_power_init();
	am_hal_pwrctrl_control(AM_HAL_PWRCTRL_CONTROL_SIMOBUCK_INIT, NULL);
	am_hal_pwrctrl_temp_thresh_t dummy;
	am_hal_pwrctrl_temp_update(25.0f, &dummy);
	sys_cache_instr_enable();
	sys_cache_data_enable();
	wisp_app_diag_mark(WISP_DIAG_APP_SOC_DONE);
}
