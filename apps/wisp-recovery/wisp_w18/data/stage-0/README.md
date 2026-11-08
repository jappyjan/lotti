# stage-0 (built, not pinned)

The next image for the left temple after W24 (docs/wisp/rung4.md, "W24b: stage-0"): the observe-only Wisp Boot with the W24 diagnostics, and a bare-metal app of about 5 KiB at `0x448000` (`apps/wisp-fw/src/stage0/`, no Zephyr, no Ambiq HAL start-up). It feeds the Apollo watchdog, kicks the nPM1300 watchdog (`07 04 01`, its only PMIC write), answers the case-UART protocol (IDENT, READ blocks 1–4, the boot report, RESET), measures the LFRC against the 32 kHz crystal, and leaves breadcrumbs in the diagnostics record. MIT, our own code; nothing of Even's.

**Not pinned.** `install-wisp` refuses it until an independent review has checked these files and a reviewed commit adds them to `wisp_w18/pins.py` (`WISP_IMAGES`, and its Wisp Boot slot to `WISP_BOOT_PASSED` with the rung-3 results), as W23 did for native-0. The Renode case `wisp-fw:w18-test stage-0` pins it in memory only, to run install-wisp's own gate on these exact files.

| File | SHA-256 | What |
| --- | --- | --- |
| `stage-0.bin` | `fc267e0b0de465f229afa5aab739ea20dc9c8b71856a7b13c65a1d446fe85c40` | the image: Wisp Boot padded to 64 KiB (slot `7a5c399b…`; `wisp_boot.bin` `b54ee856…`, 11,056 B), then stage-0 at `0x448000`. 70,744 B, zlib CRC-32 `96aaf1c7`; ends at `0x449458` (writes bounded by `0x449460`) |
| `stage0.map` | `6df0f5ea055c707b296c9da3f1662b6efbdf8acce15adca3fac02504ac399eaf` | stage-0's linker map, as built (it holds the build checkout's absolute paths) |
| `stage0.elf` | `e1bd148b40fc29793e5e56674c4fb259e7485069a485ae1a8bd78052b161a23d` | stage-0's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | `84d6432e…` | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone addresses from it |
| `manifest.json` | `f9f667c6…` | the build's own manifest (its ELF hashes are of the unstripped ELFs) |

Built on t3-worker from commit `9bfac4d` (clean tree; stage-0 reports rev `9bfac4d2ca`) with `apps/wisp-fw/scripts/build_native.sh stage-0` and copied here by `scripts/package_native.sh stage-0`. The build's gates: `check_image` (Wisp Boot and `--part app`), `check_rule8` on both, `check_no_mram_write` on both, `check_native.py --observe --bare-app-elf`, and wisp-ota's `pack-main` (sendable).

`install-wisp` writes whole 16-byte units, so over the stock 2.4.0.24 main its final CRC over `[0x438000, 0x449460)` is **`19b3e002`** (the pin's `crc32_aligned_over_stock`); `app-check` compares the image's own 70,744 bytes with `96aaf1c7`.

Wisp Boot's rung-3 results with this build (rule 12): docs/wisp/rung4.md, "W24b: stage-0".
