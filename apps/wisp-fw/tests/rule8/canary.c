/*
 * SPDX-License-Identifier: MIT
 *
 * TEST ONLY (CMake option WISP_RULE8_CANARY, used by scripts/test.sh): links the EM9305
 * firmware image from the Ambiq HAL so the test can prove scripts/check_rule8.py rejects it.
 * An image built with this file never passes the build: the post-build gate fails it.
 *
 * Reached from a SYS_INIT entry (kept by the linker script), so --gc-sections can't drop it.
 */

#include <zephyr/init.h>

#include "ble_fw_image_em9305.h"

static int wisp_rule8_canary(void)
{
	volatile uint8_t sink = 0;

	for (unsigned int i = 0; i < IMAGE_RECORDS_SIZE; i++) {
		sink ^= image_records[i]->data[image_records[i]->length - 1];
	}
	(void)sink;
	return 0;
}

SYS_INIT(wisp_rule8_canary, APPLICATION, 99);
