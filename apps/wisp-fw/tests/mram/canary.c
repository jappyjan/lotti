/*
 * SPDX-License-Identifier: MIT
 *
 * TEST ONLY (CMake option WISP_MRAM_CANARY, used by scripts/test.sh): links hal_ambiq's MRAM
 * program path so the test can prove scripts/check_no_mram_write.py (rung4.md G13) rejects it.
 * Never runs: the call sits behind a volatile false, and an image built with this file never
 * passes the build.
 */

#include <zephyr/init.h>

#include <am_mcu_apollo.h>

static volatile int never;

static int wisp_mram_canary(void)
{
	static const uint32_t word = 0xFFFFFFFFu;

	if (never) {
		(void)am_hal_mram_main_program(AM_HAL_MRAM_PROGRAM_KEY, (uint32_t *)&word,
					       (uint32_t *)0x7F0000u, 1);
	}
	return 0;
}

SYS_INIT(wisp_mram_canary, APPLICATION, 99);
