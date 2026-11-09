# native-1 (NOT pinned)

The MVP image for the left temple (docs/wisp/rung4.md, "W25: native-1 (MVP)"): the observe-only Wisp Boot with the W24c fixes (half-duplex case UART, MSPICFG's resets kept, the record and status block cleaned from the D-cache, the hardened hand-off) and the full Wisp app at `0x448000`: no console, the watchdog fed from a timer while the PMIC thread lives, breadcrumbs and a fatal-error handler in Wisp Boot's record, the half-duplex case UART (IDENT, READ blocks 1, 2 and 4, BOOTREP, RESET), BLE with the Wisp GATT service and a wisp-core session, and the boot screen on the JBD4010 through the gated rail switches. MIT, our own code; nothing of Even's.

**Not pinned.** `wisp_w18/pins.py` does not list it, so `install-wisp` refuses it (`tests/test_native1.py` checks that, and that the whole gate accepts these files once they are pinned). Pinning is a separate, reviewed step, as W23 and W24b-0 were: an independent review of these files and the tree they were built from, then `pins.WISP_IMAGES["native-1"]` (image, stripped ELF and map hashes, both gates, `crc32`) and its Wisp Boot slot in `pins.WISP_BOOT_PASSED` with both observe suites (rung4.md W25, "Evidence"). The review must also give Jan's go for the four new PMIC task writes (the panel's rails, rung4.md W25).

| File | What |
| --- | --- |
| `native-1.bin` | the image: Wisp Boot padded to 64 KiB, then the app at `0x448000` |
| `zephyr.map` | the app's linker map, as built (it holds the build checkout's absolute paths, so it is pinned as built) |
| `zephyr.elf` | the app's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone addresses from it |
| `manifest.json` | the build's own manifest (image, Wisp Boot binary and slot, app binary, unstripped ELFs and maps: SHA-256; the image's CRC-32; the gates that ran) |

The image: **`47c5f9515cc3ca0a687e2d8c74f8bfbb468cc98fbd50b7baf27001aaacd1fd85`**, 244,628 B, zlib CRC-32 `85c12561`, ending at `0x473b94`; Wisp Boot `wisp_boot.bin` `ef1a967feb938061…` (11,584 B, stage-0b's W24d Wisp Boot plus the hardened hand-off), slot `34e401fbf2c90950…`; the app `874c6cfa14f2dfe4…` (179,092 B). Built from commit `c7d09ad` (the app reports that revision). The SHA-256 of every file is in `manifest.json` (the ELFs there are the unstripped ones). Built on t3-worker with `apps/wisp-fw/scripts/build_native.sh native-1` from a clean, committed tree and copied here by `scripts/package_native.sh native-1`. The build's gates: `check_image` (Wisp Boot and `--part app`), `check_rule8` and `check_no_mram_write` on both, the hardware-image gate (no console, no nPM13xx node, the panel only through the gated rails, BUCK1 expecting W21's code 0x01), `check_native.py --observe`, and wisp-ota's `pack-main` (sendable). The app embeds its git revision, so a rebuild of a later commit differs in those bytes.

`install-wisp` writes whole 16-byte units, so its final CRC covers the image and the bytes after it up to the next 16-byte boundary, which keep what MRAM held there: the value depends on what was installed before (stock, stage-0, native-0). `app-check` compares the image's own bytes with the manifest's `image_crc32`.
