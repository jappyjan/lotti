# stage-0 (built, not pinned)

The next image for the left temple after W24 (docs/wisp/rung4.md, "W24b: stage-0"): the observe-only Wisp Boot with the W24 diagnostics, and a bare-metal app of about 5 KiB at `0x448000` (`apps/wisp-fw/src/stage0/`, no Zephyr, no Ambiq HAL start-up). It feeds the Apollo watchdog, kicks the nPM1300 watchdog (`07 04 01`, its only PMIC write), answers the case-UART protocol (IDENT, READ blocks 1–4, the boot report, RESET), measures the LFRC against the 32 kHz crystal, and leaves breadcrumbs in the diagnostics record. MIT, our own code; nothing of Even's.

**Not pinned.** `install-wisp` refuses it until an independent review has checked these files and a reviewed commit adds them to `wisp_w18/pins.py` (`WISP_IMAGES`, and its Wisp Boot slot to `WISP_BOOT_PASSED` with the rung-3 results), as W23 did for native-0. The Renode case `wisp-fw:w18-test stage-0` pins it in memory only, to run install-wisp's own gate on these exact files.

| File | SHA-256 | What |
| --- | --- | --- |
| `stage-0.bin` | IMAGE_SHA | the image: Wisp Boot padded to 64 KiB (slot SLOT_SHA; `wisp_boot.bin` BOOT_SHA, BOOT_BYTES B), then stage-0 at `0x448000`. IMAGE_BYTES B, zlib CRC-32 IMAGE_CRC |
| `stage0.map` | MAP_SHA | stage-0's linker map, as built (it holds the build checkout's absolute paths) |
| `stage0.elf` | ELF_SHA | stage-0's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | WBELF_SHA | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone addresses from it |
| `manifest.json` | MANIFEST_SHA | the build's own manifest (its ELF hashes are of the unstripped ELFs) |

Built on t3-worker from commit SOURCE_COMMIT with `apps/wisp-fw/scripts/build_native.sh stage-0` and copied here by `scripts/package_native.sh stage-0`. The build's gates: `check_image` (Wisp Boot and `--part app`), `check_rule8` on both, `check_no_mram_write` on both, `check_native.py --observe --bare-app-elf`, and wisp-ota's `pack-main` (sendable).

Wisp Boot's rung-3 results with this build (rule 12): see docs/wisp/rung4.md, "W24b: stage-0".
