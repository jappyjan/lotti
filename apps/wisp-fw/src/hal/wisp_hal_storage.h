/*
 * SPDX-License-Identifier: MIT
 *
 * Storage HAL: files on the NOR littlefs (MX25U25643G, littlefs at 0x1400000). Paths are
 * the stock layout: ota/s200_firmware_ota.bin (staging, read by the Even bootloader),
 * wisp/rescue.bin (stock main image), wisp/res/<app>/... (persisted resources).
 *
 * MRAM is not reachable through this interface. The only MRAM write Wisp ever makes is the
 * documented update-flag value, from Wisp Boot / the update service (safety rule 1).
 */
#ifndef WISP_HAL_STORAGE_H
#define WISP_HAL_STORAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct wisp_file;

int wisp_hal_file_open(struct wisp_file **f, const char *path, bool write);
int wisp_hal_file_read(struct wisp_file *f, void *buf, size_t len, size_t *got);
int wisp_hal_file_write(struct wisp_file *f, const void *buf, size_t len);
int wisp_hal_file_close(struct wisp_file *f);
int wisp_hal_file_remove(const char *path);
int wisp_hal_file_size(const char *path, uint32_t *size);

#endif /* WISP_HAL_STORAGE_H */
