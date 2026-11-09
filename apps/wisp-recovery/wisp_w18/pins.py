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
STOCK_MAIN_CRC32 = 0x9C66_404B  # zlib CRC-32 of those 3,700,068 bytes: what `app-check` compares

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
    # Ours (MIT, wisp_w18/programs/, built by programs/build.sh with drdaeman's toolchain, which
    # rebuilds the three above byte for byte): they feed the temple's nPM1300 watchdog
    # (pmic_kick.h; recovery.md, "The temple's watchdog"). feed kicks once and returns the status;
    # dump_fed and recover_fed are dump.c and recover.c kicking at most once a second; they stop
    # with result 2 (dump_fed) or 6 (recover_fed) when a kick cannot power IOM7 any more.
    "feed": "bd72c6b14fee4fbeee890d14a9a8e9ccd33a5b8cb071b0f9b1aa00ea7a7409d9",
    "dump_fed": "7ac581fd2028ff167ca0461ea9c844dc3dfd2842cabdfcc1637a332a28aafbc5",
    "recover_fed": "8f5cefb93786f676b8d5c8131b3c6999775dc36bd59b9a4990f2b40678d6f610",
    # Ours (rung4.md §4, G3): a read-only nPM1300 snapshot over the bootloader's IOM7. One kick
    # (the feed's write), then one write-read per register of PMIC_READ_REGISTERS, baked into the
    # image; tests/test_pmic_read.py checks its wire under Unicorn. Its first hardware run needs
    # Jan's own go (a new program on the PMIC bus).
    "pmic_read": "491f98f55dc65a81ff2a1ba88be7233e5c90d93508423b7c0306c5d26e27b989",
}
# What the feeding programs use of the patched 2.3.2.14 bootloader [S: disassembly, and the IOM7
# state read through the loader in Renode], valid only while it is the one in MRAM (every session
# checks its CRC before it runs any program that calls into it):
IOM7_HAL_HANDLE = 0x2001_81F8  # am_hal_iom state of IOM7, saved by HAL_I2CInit (0x430852)
I2C_TABLE_ENTRY_7 = 0x2000_03E8  # the bootloader's I2C table, entry 7: {7, IOM7_HAL_HANDLE, ...}
IOM_POWER_CTRL = 0x0042_CCD1  # am_hal_iom_power_ctrl (Thumb); WAKE/DEEPSLEEP with retain
TICK_COUNT = 0x0041_60E9  # xTaskGetTickCount (Thumb) [D platform.h]; 1024 ticks a second
# The temple's watchdog [S, hardware.md]: the stock app arms the nPM1300 timer (I2C7 = IOM7,
# address 0x6B) in reset mode, 30.72 s, and kicks it every second (TIMER TASKWDOGKICK, 0x0704 = 1).
# An Apollo510 reset does not stop it, and the bootloader and the loader never kick it.
PMIC_WATCHDOG_S = 30.72
PMIC_KICK_WIRE = bytes((0x07, 0x04, 0x01))
# pmic_read.bin's registers, in the order it reads and sends them (programs/pmic_read.c, its
# `ranges`): (16-bit address, name, kind). "config" is what Wisp's DTS and drivers must match and
# what a later snapshot must equal; "status" reflects live state (VBUS, charging, rails) and may
# differ; "watchdog" is the timer's period (rung4.md exit item 5: only the watchdog timer may
# differ). The timer's mode is "config": a watchdog that no longer resets the temple would remove
# the PMIC's power cycle, the fail-safe native-0 keeps (G27). Offsets as Zephyr's npm13xx drivers.
PMIC_READ_REGISTERS = (
    (0x0201, "VBUSIN.ILIM", "config"), (0x0202, "VBUSIN.ILIMSTARTUP", "config"),
    (0x0205, "VBUSIN.DETECT", "status"), (0x0207, "VBUSIN.STATUS", "status"),
    (0x0304, "BCHARGER.ENABLE", "config"),
    (0x0308, "BCHARGER.ISET_MSB", "config"), (0x0309, "BCHARGER.ISET_LSB", "config"),
    (0x030A, "BCHARGER.ISET_DISCHG_MSB", "config"), (0x030B, "BCHARGER.ISET_DISCHG_LSB", "config"),
    (0x030C, "BCHARGER.VTERM", "config"), (0x030D, "BCHARGER.VTERM_R", "config"),
    (0x030E, "BCHARGER.TRICKLE_SEL", "config"), (0x030F, "BCHARGER.ITERM_SEL", "config"),
    (0x0310, "BCHARGER.NTC_COLD_MSB", "config"), (0x0311, "BCHARGER.NTC_COLD_LSB", "config"),
    (0x0312, "BCHARGER.NTC_COOL_MSB", "config"), (0x0313, "BCHARGER.NTC_COOL_LSB", "config"),
    (0x0314, "BCHARGER.NTC_WARM_MSB", "config"), (0x0315, "BCHARGER.NTC_WARM_LSB", "config"),
    (0x0316, "BCHARGER.NTC_HOT_MSB", "config"), (0x0317, "BCHARGER.NTC_HOT_LSB", "config"),
    (0x0334, "BCHARGER.CHG_STAT", "status"), (0x0336, "BCHARGER.ERR_REASON", "status"),
    (0x0350, "BCHARGER.VBATLOW_EN", "config"),
    (0x0408, "BUCK1.VOUT_NORM", "config"), (0x0409, "BUCK1.VOUT_RET", "config"),
    (0x040A, "BUCK2.VOUT_NORM", "config"), (0x040B, "BUCK2.VOUT_RET", "config"),
    (0x040C, "BUCK.EN_CTRL", "config"), (0x040D, "BUCK.VRET_CTRL", "config"),
    (0x040E, "BUCK.PWM_CTRL", "config"), (0x040F, "BUCK.SW_CTRL", "config"),
    (0x0410, "BUCK1.VOUT_STAT", "status"), (0x0411, "BUCK2.VOUT_STAT", "status"),
    (0x0415, "BUCK.CTRL0", "config"), (0x0434, "BUCK.STATUS", "status"),
    (0x0509, "ADC.CONFIG", "config"), (0x050A, "ADC.NTCR_SEL", "config"),
    (0x0600, "GPIO0.MODE", "config"), (0x0601, "GPIO1.MODE", "config"), (0x0602, "GPIO2.MODE", "config"),
    (0x0603, "GPIO3.MODE", "config"), (0x0604, "GPIO4.MODE", "config"), (0x061E, "GPIO.STATUS", "status"),
    (0x0705, "TIMER.CONFIG", "config"),
    (0x0708, "TIMER.TARGET_HI", "watchdog"), (0x0709, "TIMER.TARGET_MID", "watchdog"),
    (0x070A, "TIMER.TARGET_LO", "watchdog"),
    (0x0804, "LDSW.STATUS", "status"), (0x0805, "LDSW1.GPISEL", "config"), (0x0806, "LDSW2.GPISEL", "config"),
    (0x0807, "LDSW.CONFIG", "config"), (0x0808, "LDSW1.LDOSEL", "config"), (0x0809, "LDSW2.LDOSEL", "config"),
    (0x080C, "LDSW1.VOUTSEL", "config"), (0x080D, "LDSW2.VOUTSEL", "config"),
    (0x0B04, "SHIP.CONFIG", "config"), (0x0B06, "SHIP.LPCONFIG", "config"),
)
# recover.bin calls the stock 2.3.2.14 MRAM wrapper at this Thumb address [D recover.c]; it is
# only valid while the patched (2.3.2.14-based) bootloader is the one in MRAM, which every
# loader session proves first (preflight hash of [BOOT_BASE, +PATCHED_BOOTLOADER_BYTES)).
MRAM_WRAPPER_2_3_2_14 = 0x0042_E83D
# The patched bootloader's own `bootloader_error_reset` [S, W20; hardware.md]: writes the clear
# record {~0 x4} to the flag through MRAM_WRAPPER_2_3_2_14 with the ROM key, then RSTGEN SWPOR.
# What G26's flag-clear program will call; nothing in this tool calls it yet.
BOOTLOADER_ERROR_RESET_2_3_2_14 = 0x0042_E157

# --- Reads the loader tools may make (`peek`; rung4.md §4, G3) ----------------------------------
# name -> (address, length, what): the patched (2.3.2.14-based) bootloader's RAM and MRAM only,
# read with dump/dump_fed after the bootloader CRC check. Addresses from W20's static analysis
# (hardware.md, "The patched bootloader's RAM"), checked by running its start-up under Unicorn.
PEEK_REGIONS = {
    "nor": (0x2000_023C, 4, "NOR ops record chosen by the RDID classifier (0x41FE0A): 0x4336A0 MX25U25643G, "
                            "0x4336B0 GD25LE256H; an unknown ID keeps the default, which is the MX record"),
    "board": (0x2002_7018, 8, "board detect over the GPIO16 ADC strap (0x430440): u8 class, u16 code, i16 mV "
                              "(raw x 1190 >> 12, the app's hw_version bins: 100-250 mV = 5, 950-1050 mV = 6)"),
    "uart2": (0x2000_0490, 28, "the bootloader's UART2 table entry, what the loader's precondition reads "
                               "(during the hold its awake byte is 1: the loader woke UART2)"),
    "power-callbacks": (0x2002_6E44, 8, "power pre/post callbacks; the loader requires both zero"),
    "flag": (0x007F_E000, 16, "the update-flag record"),
    "nor-records": (0x0043_36A0, 32, "the bootloader's two NOR ops records (MRAM)"),
    # rung4.md W24 D1 and "W24b results": what the last Wisp boot left in RAM, read in a held loader
    # after the case reset that started the session. Read only if PWRCTRL says SSRAM group 2 (the top
    # MiB, Wisp Boot's RAM) is powered (PEEK_SSRAM_GATE). The patched bootloader's only SSRAM use is
    # its heap, [0x20081000, 0x2013C800) (memset + heap init at 0x41FD70; no literal points higher).
    "ssram-power": (0x4002_1028, 4, "PWRCTRL.SSRAMPWRST: bit 0/1/2 = SSRAM group 0/1/2 (1 MiB each) powered; "
                                    "group 2 holds Wisp Boot's RAM and its record"),
    "rstgen-stat": (0x4000_885C, 4, "RSTGEN.STAT as the held loader sees it: the cause of the reset that "
                                    "started this session (the case reset: external), unless STAT accumulates"),
    "wisp-record": (0x2037_0000, 64, "Wisp's diagnostics record (wisp_diag.h): the last boot's cause, boot "
                                     "counter, last stage and its time, fault; written by Wisp Boot and the app"),
    "wisp-boot-status": (0x2037_5330, 692, "Wisp Boot's status block v2 (`st`) of the stage-0 Wisp Boot "
                                           "(slot 7a5c399b..., b54ee856...) only: its `prev` is the record of "
                                           "the boot before the last one"),
}
# Regions in SSRAM group 2: read only after "ssram-power" shows that group powered.
PEEK_SSRAM_GATED = ("wisp-record", "wisp-boot-status")
PEEK_SSRAM_GROUP2 = 0x4
PEEK_NOR = {0x0043_36A0: "MX25U25643G (or an unknown ID: the classifier's default)", 0x0043_36B0: "GD25LE256H"}

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
# MRAM through the loader: only inside the main-app region, and only up to the end of the image
# being written: the pinned stock main bytes (`recover`), or a pinned Wisp image (`install-wisp`,
# below), never anything else.
RECOVER_BASE = APP_BASE
RECOVER_END = APP_BASE + ((STOCK_MAIN_BYTES + 15) & ~15)
APP_END_CEILING = 0x007F_8000  # no image may end past it (rule 3; wisp-ota APP_END_CEILING)
APP_REGION_END = 0x007F_E000  # update-flag record; never written
SIDES = ("left", "right")

# --- Wisp native images through the loader (docs/wisp/rung4.md §3, decision R4-1) -------------
# `install-wisp` writes only an image listed in WISP_IMAGES, and only while R4_1_APPROVED is True.
# Jan approved R4-1 on 2026-11-08 (rule 1's W18 exception extended to pinned Wisp images; commit
# 9181c94). W23 pinned native-0 after its independent review: the build of commit 8374f9a, rebuilt
# on t3-worker and byte-identical to the reviewed one (image and app map); the committed files are
# in data/native-0/ (README.md there). W24b-0 pinned stage-0 the same way after its independent
# review: the build of commit 9bfac4d, rebuilt on t3-worker byte-identical (image, stripped ELFs,
# Wisp Boot); the committed files are in data/stage-0/. Every other image is refused before the
# case is touched.
R4_1_APPROVED = True
WISP_BOOT_SLOT_BYTES = 0x1_0000  # Wisp Boot padded to 64 KiB at [0x438000, 0x448000)
# Wisp Boot builds that passed rung 3, by the SHA-256 of the padded 64 KiB slot, with the suites
# they passed (wisp-fw:boot-test, `.wisp-cache/rung3/<bootloader>/report.md`). R4-1 asks for both
# suites in WISP_BOOT_SUITES; the observe-only build has its own suite with its own outcomes.
# The fallback build that passed 26/26 on 2026-11-06 (wisp_boot.bin 8dd8fd69ef4b...) ran on the
# stock 2.2.6.10 and 2.4.0.24 bootloaders only, and is not listed.
WISP_BOOT_SUITES = ("stock-2.4.0.24", "patched-87e2d4e0")
WISP_BOOT_PASSED: dict[str, dict] = {
    # native-0's observe-only Wisp Boot (wisp_boot.bin d793a93e02ba18f7..., 8,256 B, padded with
    # 0xFF to 64 KiB). `wisp-fw:boot-test --suite observe`, PR #77 (rung4.md "native-0 status").
    "16616d9d82ebc934f1460112b5ac62c481c66ed57a8881d1837dcf59e7c27816": {
        "build": "observe-only (-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF)",
        "wisp_boot_bin_sha256": "d793a93e02ba18f7e1fb087f3a1f00452de1aef6a9267bd84ff42d78e954f334",
        "suites": {
            "stock-2.4.0.24": "observe suite 6/6 pass",
            "patched-87e2d4e0": "observe suite 6/6 pass",
        },
    },
    # stage-0's observe-only Wisp Boot with the W24b diagnostics (D1 record, PMIC kick, D2 window;
    # wisp_boot.bin b54ee856faaf9b82..., 11,056 B, padded with 0xFF to 64 KiB). `wisp-fw:boot-test
    # --suite observe` (8 cases, obs-diag-wdt and obs-stage-0 new), PR #81 (rung4.md "W24b").
    "7a5c399bdfeb05a0683f8ef9fba4452cc4147e22b57de55e2c9754227117b185": {
        "build": "observe-only (-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF), commit 9bfac4d",
        "wisp_boot_bin_sha256": "b54ee856faaf9b82de4f4d743d279ca824d9da0038262783e48689e4ac1668f9",
        "suites": {
            "stock-2.4.0.24": "observe suite 8/8 pass",
            "patched-87e2d4e0": "observe suite 8/8 pass",
        },
    },
}
# Post-link gates a Wisp image's build must have passed (rung4.md R4-1): the rule-8 gate and the
# no-MRAM-write gate over [0x448000, end) (G13).
WISP_GATES = ("check_rule8", "no-mram-write")
# name -> {"image_sha256", "image_bytes", "elf_sha256", "map_sha256", "gates": (...)}, plus
# optionally "crc32" (zlib CRC-32 of the image's own bytes), which `app-check` compares with the
# app region's CRC over image_bytes.
WISP_IMAGES: dict[str, dict] = {
    # W23: native-0 at commit 8374f9a (wisp-fw:build-native). The ELF is the app's zephyr.elf after
    # `objcopy --strip-debug` (no paths; every loaded section unchanged), the map the build's own
    # (it holds the reviewed checkout's absolute paths, so it is pinned as built, not rebuilt).
    "native-0": {
        "commit": "8374f9a",
        "image_sha256": "5d373fd8874275a3a59d18306536a4b73a4f4361e92050ee22583faedfd60bba",
        "image_bytes": 230_428,
        "elf_sha256": "4411c3ada90ea09a40c97986c8f957b6ba7419676b9da893e723e78312877510",
        "map_sha256": "28fcb218edaeb3302c1bc226b3483fa64393760d4eaf03e92491f87a4d4647c0",
        "gates": ("check_rule8", "no-mram-write"),
        "crc32": 0xC0DD_9DC0,
        # install-wisp's final CRC (crc_after) is over the 16-byte-aligned region [0x438000,
        # 0x470420), whose last 4 bytes keep what MRAM held there. Written over the stock 2.4.0.24
        # main (W24 on the left temple) it reads efde0857: the value the W24 report must show.
        "crc32_aligned_over_stock": 0xEFDE_0857,
        "wisp_boot_slot_sha256": "16616d9d82ebc934f1460112b5ac62c481c66ed57a8881d1837dcf59e7c27816",
    },
    # W24b-0: stage-0 at commit 9bfac4d (wisp-fw:build-native stage-0): the observe-only Wisp Boot
    # above and the bare-metal app of src/stage0/. The ELF is stage0.elf after `objcopy
    # --strip-debug`, the map the build's own (absolute paths, pinned as built). The build ran
    # check_rule8 and check_no_mram_write over the app; the review reran the no-MRAM-write gate
    # over all 70,744 bytes, Wisp Boot's slot included.
    "stage-0": {
        "commit": "9bfac4d",
        "image_sha256": "fc267e0b0de465f229afa5aab739ea20dc9c8b71856a7b13c65a1d446fe85c40",
        "image_bytes": 70_744,
        "elf_sha256": "e1bd148b40fc29793e5e56674c4fb259e7485069a485ae1a8bd78052b161a23d",
        "map_sha256": "6df0f5ea055c707b296c9da3f1662b6efbdf8acce15adca3fac02504ac399eaf",
        "gates": ("check_rule8", "no-mram-write"),
        "crc32": 0x96AA_F1C7,
        # Over [0x438000, 0x449460): the image and the 8 bytes of the stock 2.4.0.24 main after it.
        "crc32_aligned_over_stock": 0x19B3_E002,
        "wisp_boot_slot_sha256": "7a5c399bdfeb05a0683f8ef9fba4452cc4147e22b57de55e2c9754227117b185",
    },
}
BATTERY_MIN_PERCENT = 80
BATTERY_MIN_MV = 3900  # rung4.md R4-4, while native (Wisp's status reports mV)


def go_token(side: str) -> str:
    """The token `bootloader-install --go` requires: names the side and the image."""
    return f"W18-{side.upper()}-{PATCHED_BOOTLOADER_SHA256[:12]}"
