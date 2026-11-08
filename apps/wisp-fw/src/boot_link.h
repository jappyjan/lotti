/*
 * SPDX-License-Identifier: MIT
 *
 * The app's side of Wisp Boot (src/boot/stage/boot_services.h): the services table at 0x438200,
 * its status block, confirm(). Every pointer is checked before use: an image whose Wisp Boot is
 * missing or older simply has no services (NULL / -ENOENT).
 */
#ifndef WISP_BOOT_LINK_H
#define WISP_BOOT_LINK_H

#include "wisp_boot_status.h"

/* Wisp Boot's status block for this boot, or NULL (no services table, version < 2, a pointer
 * outside Wisp Boot's RAM, or a block whose magic, size or CRC is wrong). */
const struct wisp_boot_status *wisp_boot_link_status(void);

/* The services table looks like Wisp Boot's (magic, version, pointers in range). */
int wisp_boot_link_present(void);

/* confirm() through the services table, with interrupts locked (boot_services.h). Records the
 * call in wisp_app_status. Returns its result, or -ENOENT without a services table. */
int wisp_boot_link_confirm(void);

#endif /* WISP_BOOT_LINK_H */
