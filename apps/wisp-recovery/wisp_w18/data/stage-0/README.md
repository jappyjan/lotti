# stage-0 (built, not pinned)

The next image for the left temple after W24 (docs/wisp/rung4.md, "W24b: stage-0"): the observe-only Wisp Boot with the W24 diagnostics, and a bare-metal app of about 5 KiB at `0x448000` (`apps/wisp-fw/src/stage0/`, no Zephyr, no Ambiq HAL start-up). It feeds the Apollo watchdog, kicks the nPM1300 watchdog (`07 04 01`, its only PMIC write), answers the case-UART protocol (IDENT, READ blocks 1–4, the boot report, RESET), measures the LFRC against the 32 kHz crystal, and leaves breadcrumbs in the diagnostics record. MIT, our own code; nothing of Even's.

**Not pinned.** `install-wisp` refuses it until an independent review has checked these files and a reviewed commit adds them to `wisp_w18/pins.py` (`WISP_IMAGES`, and its Wisp Boot slot to `WISP_BOOT_PASSED` with the rung-3 results), as W23 did for native-0. The Renode case `wisp-fw:w18-test stage-0` pins it in memory only, to run install-wisp's own gate on these exact files.

| File | SHA-256 | What |
| --- | --- | --- |
| `stage-0.bin` | `59c36559c2c20e23fd305e3a1deea0610ba4f4e615d4f3f80dab3f1c901cac81` | the image: Wisp Boot padded to 64 KiB (slot `7a5c399b…`; `wisp_boot.bin` `b54ee856…`, 11,056 B), then stage-0 at `0x448000`. 70,728 B, zlib CRC-32 `9e3a9a99`; ends at `0x449448` (writes bounded by `0x449450`) |
| `stage0.map` | `eb185077e7eb91f47f27c004f9d00c5ca69fa3345537d39dd01d9a0bf36b1152` | stage-0's linker map, as built (it holds the build checkout's absolute paths) |
| `stage0.elf` | `e5221cc60dfb267e7c133c157bd4e698c99895fe2d8ec6ab7ca990f6729225d9` | stage-0's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | `84d6432e…` | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone addresses from it |
| `manifest.json` | `1937b1d4…` | the build's own manifest (its ELF hashes are of the unstripped ELFs) |

Built on t3-worker from commit `f0e9458` (clean tree; stage-0 reports rev `f0e9458ce1`) with `apps/wisp-fw/scripts/build_native.sh stage-0` and copied here by `scripts/package_native.sh stage-0`. The build's gates: `check_image` (Wisp Boot and `--part app`), `check_rule8` on both, `check_no_mram_write` on both, `check_native.py --observe --bare-app-elf`, and wisp-ota's `pack-main` (sendable).

`install-wisp` writes whole 16-byte units, so over the stock 2.4.0.24 main its final CRC over `[0x438000, 0x449450)` is **`3571f525`** (the pin's `crc32_aligned_over_stock`); `app-check` compares the image's own 70,728 bytes with `9e3a9a99`.

Wisp Boot's rung-3 results with this build (rule 12): docs/wisp/rung4.md, "W24b: stage-0".
