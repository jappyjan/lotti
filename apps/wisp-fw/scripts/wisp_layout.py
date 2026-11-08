# SPDX-License-Identifier: MIT
"""Apollo510 / Even G2 memory facts the firmware checks rely on (docs/wisp/hardware.md).

Kept in one place so check_image.py, check_rule8.py and the tests agree. wisp-ota keeps its
own copy on purpose (rule 3 wants an independent second implementation).
"""

# MRAM (per temple)
SBL_START = 0x0040_0000          # Ambiq secure bootloader, never written
EVEN_BOOTLOADER_START = 0x0041_0000
PREAMBLE_ADDR = 0x0043_7FE0      # where the 32-byte preamble would sit; the bootloader never writes it
APP_LOAD_ADDR = 0x0043_8000      # the Even bootloader hands off here: Wisp Boot's vector table
WISP_BOOT_SIZE = 0x0001_0000     # Wisp Boot owns [0x438000, 0x448000)
WISP_MAIN_BASE = 0x0044_8000     # the Wisp app's vector table (linked here, entered by Wisp Boot)
APP_END_LIMIT = 0x007F_8000      # hard ceiling for the image end (exclusive)
UPDATE_FLAG_ADDR = 0x007F_E000   # bootloader-owned flag record
MRAM_END = 0x0080_0000

# RAM an initial stack pointer may point into: DTCM 0x20000000-0x20080000 (512 KiB; Zephyr's
# DTS uses only the first 0x7C000) followed by SSRAM 0x20080000-0x20380000 (3 MiB). The
# initial SP is a full-descending top-of-stack, so the end address itself is allowed.
SRAM_START = 0x2000_0000
SRAM_END = 0x2038_0000
# The top 64 KiB of SSRAM belong to Wisp Boot for good (its data, status block and stack, also
# while the app calls confirm()); the app's RAM and initial SP stay below.
WISP_BOOT_RAM_BASE = 0x2037_0000
