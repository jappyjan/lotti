/*
 * SPDX-License-Identifier: MIT
 *
 * The app's side of Wisp Boot. See boot_link.h.
 */
#include "boot_link.h"

#include <errno.h>
#include <stddef.h>

#include <zephyr/irq.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/crc.h>

#include "app_status.h"
#include "boot_services.h"
#include "wisp_boot_layout.h"

static const struct wisp_boot_services *services(void)
{
	const struct wisp_boot_services *s = (const void *)WISP_BOOT_SERVICES_ADDR;
	uintptr_t fn = (uintptr_t)s->confirm;

	if (s->magic != WISP_BOOT_SERVICES_MAGIC || s->version < 1) {
		return NULL;
	}
	/* confirm() is Thumb code inside Wisp Boot's slot. */
	if (!(fn & 1u) || (fn & ~1u) < WISP_APP_BASE || (fn & ~1u) >= WISP_MAIN_BASE) {
		return NULL;
	}
	return s;
}

int wisp_boot_link_present(void)
{
	return services() != NULL;
}

const struct wisp_boot_status *wisp_boot_link_status(void)
{
	const struct wisp_boot_services *s = services();
	const struct wisp_boot_status *b;
	uintptr_t p;

	if (!s || s->version < 2) {
		return NULL;
	}
	b = s->status;
	p = (uintptr_t)b;
	if (p < WISP_BOOT_RAM_BASE || p + sizeof(*b) > WISP_BOOT_RAM_END || (p & 3u)) {
		return NULL;
	}
	if (b->magic != WISP_BOOT_STATUS_MAGIC || b->version != WISP_BOOT_STATUS_VERSION ||
	    b->size != sizeof(*b)) {
		return NULL;
	}
	if (crc32_ieee((const uint8_t *)b, offsetof(struct wisp_boot_status, crc)) != b->crc) {
		return NULL;
	}
	return b;
}

int wisp_boot_link_confirm(void)
{
	const struct wisp_boot_services *s = services();
	unsigned int key;
	int err;

	if (!s) {
		err = -ENOENT;
	} else {
		/* Wisp Boot runs on its own RAM and drives MSPI1 itself (the app keeps MSPI1 off). */
		key = irq_lock();
		err = s->confirm();
		irq_unlock(key);
	}
	wisp_app_status.confirm_calls++;
	wisp_app_status.confirm_result = (int16_t)err;
	return err;
}
