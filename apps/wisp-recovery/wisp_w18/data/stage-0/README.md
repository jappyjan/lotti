# stage-0 (pinned, W24b-0)

The next image for the left temple after W24 (docs/wisp/rung4.md, "W24b: stage-0"): the observe-only Wisp Boot with the W24 diagnostics, and a bare-metal app of about 5 KiB at `0x448000` (`apps/wisp-fw/src/stage0/`, no Zephyr, no Ambiq HAL start-up). It feeds the Apollo watchdog, kicks the nPM1300 watchdog (`07 04 01`, its only PMIC write), answers the case-UART protocol (IDENT, READ blocks 1–4, the boot report, RESET), measures the LFRC against the 32 kHz crystal, and leaves breadcrumbs in the diagnostics record. MIT, our own code; nothing of Even's.

**Pinned (W24b-0, 2026-11-09)** after an independent review of these files and the tree they were built from (rung4.md, "W24b-0 review"): `wisp_w18/pins.py` lists the image in `WISP_IMAGES["stage-0"]` (image, stripped ELF and map hashes, both gates, `crc32` and `crc32_aligned_over_stock`) and its Wisp Boot slot in `WISP_BOOT_PASSED` (observe suite 8/8 on the stock 2.4.0.24 and the patched `87e2d4e0…` bootloader). The review rebuilt it from commit `9bfac4d` on t3-worker: `stage-0.bin`, `wisp_boot.bin`, the stripped `stage0.elf` and the stripped `wisp_boot.elf` came out byte-identical (the maps differ only in the checkout's absolute paths, so the map is pinned as built). A build of a later tree differs in the 10-byte revision string stage-0 reports (`STAGE0_REV`), nothing else. `tests/test_stage0.py` runs install-wisp's whole gate on these files and refuses a one-byte change to any of them; `wisp-fw:w18-test stage-0` installs them through the patched loader in Renode against the repository's pin.

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
