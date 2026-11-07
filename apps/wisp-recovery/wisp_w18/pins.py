# SPDX-License-Identifier: MIT
"""Pinned facts for W18 (docs/wisp/recovery.md, "W18 procedure"). Every hash here was
reproduced on t3-worker; nothing that is Even's code is stored in this repository.

Sources (MIT; see ../NOTICE.md):
  [D] drdaeman/g2-bootloader-patch @ 1d22097: tools/g2patch/firmware.py, recovery.py,
      link.py, protocol.py, handshake.py, src/platform.h, tests/test_tools.py (BuildPins)
  [S] our own static analysis of the stock 2.4.0.24 main app and bootloaders
"""

from __future__ import annotations

# --- Stock inputs (git-ignored .wisp-cache/stock/, fetched by `wisp-ota fetch`) ----------------
BUNDLE_2_3_2_14_SHA256 = "26b6067665a441b779c47f6b95427b8b4bb5f502aaf527466dadce628aeb00b2"  # [D Makefile]
BUNDLE_2_4_0_24_SHA256 = "363198f8d543a5c1181d8a213e9077285cb865700a1885c8dc7c1b9324fd0e05"  # catalog.ts
STOCK_BOOTLOADER_SHA256 = "22a2b98e606b4d296e957a3a8b600a2158497638d79485c817c2025536329ba7"  # 2.3.2.14 [D]
STOCK_BOOTLOADER_BYTES = 149_760
CASE_FIRMWARE_SHA256 = "773b6d4cfdaf0a5a74a557e3babe8222a0ae813436b76a7437c1096d2c60d677"  # box 1.2.57, payload[32:]
# The image `recover` writes: stock 2.4.0.24 main app, payload[32:] (vector table first), i.e.
# exactly the bytes the Even bootloader itself programs at 0x438000.
STOCK_MAIN_VERSION = "2.4.0.24"
STOCK_MAIN_SHA256 = "df8cfddf3bd29a8351129a8364a8e0dafb347ffc7bfcbca5b52fdd973a7cce4a"
STOCK_MAIN_BYTES = 3_700_068
STOCK_MAIN_PAYLOAD_SHA256 = "33f9eb7a47f996b8bcf34ac9df8bc2f7b698a6512cbf370d25b3215ad0dde298"

# --- The patched bootloader [D firmware.py, boot.ld] -------------------------------------------
BOOT_BASE = 0x0041_0000
APP_BASE = 0x0043_8000
BOOT_PART_BYTES = APP_BASE - BOOT_BASE
PAGE_BYTES = 4096
HOOK_OFFSET = 0x0042_E656 - BOOT_BASE  # the DFU task's call of is_need_updata_image
HOOK_OLD = bytes.fromhex("fff789ff")  # bl 0x42e56c (stock)
HOOK_NEW = bytes.fromhex("06f061fd")  # bl 0x43511c boot_task_then_flag (patch)
PATCH_BASE = 0x0043_4900  # = BOOT_BASE + STOCK_BOOTLOADER_BYTES
PATCH_BIN_SHA256 = "d62460d24839a4ab80251dda208811a15b552076293f74ced0be4351fbf8af09"  # [D BuildPins]
# Output of drdaeman's `make patch FIRMWARE=<2.3.2.14 bundle>` (reproduced, clang 21.1.8, his
# flake), and of image.build_patched_bootloader(): 38 pages, raw 154,476 bytes + 0xFF padding.
PATCHED_BOOTLOADER_SHA256 = "87e2d4e0a7a673ae68fdf47f022b2c1f45dbcb49844e5c88f8a0b1b91bd525c2"
PATCHED_BOOTLOADER_BYTES = 155_648
PATCHED_RAW_SHA256 = "7e328d72485c3fde82eeddeb1400e7e69dc642813b5117ca757e2487eb860e1b"
PATCHED_RAW_BYTES = 154_476
AUTH_KEY = b"DEFAULTNOTSECRET"  # drdaeman's public default, compiled into patch.bin

# --- RAM programs run by the loader (MIT, built from [D] src/examples) -------------------------
PROGRAMS = {
    "checksum": "4bbd4bfbd4f403b9da4967da4a88b23d61f99f00e523cd527262ce10347fc4ac",
    "dump": "93caf00914220b16a2d1c1995215e42e9a253be5cf451d9bbe92fac9f6d205bb",
    "recover": "f046754b6ecba4dd4e3c8e7aa568a713e0961e7f286e98a6f96f955882408732",
}
# recover.bin calls the stock 2.3.2.14 MRAM wrapper at this Thumb address [D recover.c]; it is
# only valid while the patched (2.3.2.14-based) bootloader is the one in MRAM, which every
# loader session proves first (preflight hash of [BOOT_BASE, +PATCHED_BOOTLOADER_BYTES)).
MRAM_WRAPPER_2_3_2_14 = 0x0042_E83D

# --- The case relay (case SRAM, loaded through the STM32 ROM like step 0) [D link.py] ----------
# drdaeman's case.bin: the webflasher bridge + his reset/claim/relay extension + Even's 372-byte
# temple-reset waveform from case 1.2.57 flash (relocated). The waveform is Even's code, so the
# repository holds case_relay_template.bin with those 372 bytes zeroed; relay_image.py fills
# them from the cached case firmware at run time and must reproduce these hashes.
RELAY_TEMPLATE_SHA256 = "366c7f67ffb3b7c384c159cb1af6d3da824325086a93d3eb8f372b6fee83365a"
RELAY_BYTES = 5508
RELAY_WAVEFORM_OFFSET = 0x1400
RELAY_WAVEFORM_BYTES = 372
RELAY_WAVEFORM_SOURCE = (0xB678, 0xB7EC)  # offsets into the raw case firmware
RELAY_WAVEFORM_SHA256 = "34f63e97a7d40c1bcf0f3bf11f314e3d34f1b95dfb4ac5cef7043acf6a53fcf7"  # [D case.json]
RELAY_BL_TARGETS = {  # case-flash call targets inside the waveform -> relay addresses [D artifacts.py]
    0x0800_4E9E: 0x2001_1574,  # reset_gpio stub
    0x0800_A7A2: 0x2001_157C,  # reset_spin stub
    0x0800_A7B0: 0x2001_09E0,  # case_reset_delay_ms
}
RELAY_BL_COUNT = 39
RELAY_SHA256 = {
    "reviewed-22": "7749131ea0c69ab7ca385649ca11559b0bf8dbe2d7367745f625e3e418847c58",  # [D BuildPins]
    # Same bytes 1670/1680/1690/1700 patched 0x22 -> 0x33 as the step-0 observed-33 bridge
    # (the relay embeds the bridge at offset 0; Jan's case has YHM register 8 = 0x33).
    "observed-33": "6beb9a5e131e3ac171a20dcf53630b26d60a732f36f30f98ba64eef263b7edc8",
    # observed-33 plus our YHM4005 feed (relay_feed.py, data/case_relay_feed.S; MIT): six
    # 4-byte sites re-pointed and 300 bytes appended at 0x20011584, 5,808 bytes in all. The case
    # watchdog reset every relay session about 20 s in without it (recovery.md).
    "observed-33-feed": "4c7475fada40e748e64d2a47d5d60fa8a189f23d7afd74f7cecd8f95844047d5",
}
RELAY_FEED_SUFFIX = "-feed"
# The relay the tool loads unless told otherwise, for both temples (one case).
DEFAULT_CASE_PROFILE = "observed-33-feed"
RELAY_ADDRESS = 0x2001_0000
RELAY_BANNER = b"G2_POGO_BRIDGE_V1\n"
RELAY_SEQUENCE = 31
CASE_PRE_CHECKS = (  # (address, length, sha256) read through the ROM before loading [D case.json]
    (134245504, 64, "4797c2aa323467327c437d8ea48e492844e62dd3bf293a5f4c4a52e66fb4baa0"),
    (134245624, 64, "6dc75420b4ceb0769fc0f8aa05118e152698442a7d5dc4264af8af8e732addb5"),
    (134233008, 64, "8f65d392b63490a3c595c7d29b024b1a25d6ac729387d13d32cba4cc6812289b"),
    (134237488, 64, "6cadb7479c74d6a0f57679587396793caabb7a7a39869f7544082132e0e4c376"),
    (134237854, 48, "4c2d9a60f4c0c935778ebc042659bf597728016c149b979e599a92b1906fb96e"),
    (134260642, 14, "ba9af254a9ad99b2e1deb621bff84a9b5916a89a5dd9c7879f77d7284ea478fb"),
    (134264440, 372, RELAY_WAVEFORM_SHA256),
)

# --- What may ever be written ------------------------------------------------------------------
# Bootloader region: only through the stock BLE OTA (type 1, storage 3, ota/s200_bootloader.bin),
# only PATCHED_BOOTLOADER_SHA256, once per temple (safety.md rule 1, W18 exception).
OTA_BOOT_FILENAME = b"ota/s200_bootloader.bin"
OTA_BOOT_TYPE = 1
OTA_STORAGE_LITTLEFS = 3
# MRAM through the loader: only the stock main app region, only the pinned stock main bytes
# (or the backup taken in the same session, never anything else).
RECOVER_BASE = APP_BASE
RECOVER_END = APP_BASE + ((STOCK_MAIN_BYTES + 15) & ~15)
APP_REGION_END = 0x007F_E000  # update-flag record; never written
SIDES = ("left", "right")


def go_token(side: str) -> str:
    """The token `bootloader-install --go` requires: names the side and the image."""
    return f"W18-{side.upper()}-{PATCHED_BOOTLOADER_SHA256[:12]}"
