/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — fixed layout facts shared by Wisp Boot, its host tests and the rung-3 tools.
 * Sources: docs/wisp/hardware.md (MRAM map, update flag, NOR littlefs), each value re-checked
 * against the stock 2.2.6.10 bootloader in Renode (apps/wisp-fw/README.md "Rung 3").
 */
#ifndef WISP_BOOT_LAYOUT_H
#define WISP_BOOT_LAYOUT_H

/* MRAM */
#define WISP_MRAM_BASE        0x00400000u
#define WISP_MRAM_END         0x00800000u
#define WISP_APP_BASE         0x00438000u /* image entry: Wisp Boot's vector table */
#define WISP_APP_CEILING      0x007F8000u /* end of anything an install may write */
#define WISP_BOOT_SIZE        0x00010000u /* Wisp Boot owns [0x438000, 0x448000) */
#define WISP_MAIN_BASE        (WISP_APP_BASE + WISP_BOOT_SIZE) /* the Wisp app's vector table */

/* Update-flag record (bootloader-owned, 16 bytes). Only word 0 is read by the bootloader. */
#define WISP_FLAG_ADDR        0x007FE000u
#define WISP_FLAG_INSTALL     0x55555555u /* word 0: install ota/s200_firmware_ota.bin */
#define WISP_FLAG_ERASED      0xFFFFFFFFu /* words 1..3 always, word 0 when cleared */
#define WISP_MRAM_PROGRAM_KEY 0x12344321u /* AM_HAL_MRAM_PROGRAM_KEY */

/* Main-app preamble of a staged image (32 bytes, see hardware.md "Image formats"). */
#define WISP_PREAMBLE_SIZE    32u
#define WISP_PREAMBLE_FLAGS   0x04u
#define WISP_PREAMBLE_TYPE    0xCBu

/* NOR: MX25U25643G, 32 MiB; littlefs v2 (disk 2.1) at 0x1400000, stock geometry. */
#define WISP_NOR_SIZE         0x02000000u
#define WISP_LFS_BASE         0x01400000u
#define WISP_LFS_READ_SIZE    16u
#define WISP_LFS_PROG_SIZE    256u
#define WISP_LFS_BLOCK_SIZE   4096u
#define WISP_LFS_BLOCK_COUNT  3008u
#define WISP_LFS_BLOCK_CYCLES 500
#define WISP_LFS_CACHE_SIZE   4096u
#define WISP_LFS_LOOKAHEAD    256u

/* Files */
#define WISP_PATH_STAGING     "ota/s200_firmware_ota.bin" /* the bootloader installs this */
#define WISP_PATH_RESCUE      "wisp/rescue.bin"           /* pristine stock main image */
#define WISP_PATH_RECORD      "wisp/boot.rec"             /* the boot record */
#define WISP_PATH_DIR         "wisp"

#endif /* WISP_BOOT_LAYOUT_H */
