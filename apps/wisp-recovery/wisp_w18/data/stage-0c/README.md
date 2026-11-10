# stage-0c (pinned at W24e-0)

stage-0b (pinned at W24d-0) with W24e's Wisp Boot fix (docs/wisp/rung4.md, "W24e: stage-0c"). On silicon at W24d, stage-0b's Wisp Boot hung at its first MSPI1 access (last stage `boot-nor`, then the watchdog). The Even bootloader hands off with MSPI1 in deep sleep: `DEVPWREN.PWRENMSPI1` = 0 and `CLKGEN.MSPIIOCLKCTRL` = `0x200` (IO clock gated). stage-0b powered MSPI1 but never ungated its clock. stage-0c's Wisp Boot (`apps/wisp-fw/src/boot/stage/boot_nor.c`) follows the HAL's WAKE order, with every register read-modify-written:

1. power MSPI1, with a bounded wait on `DEVPWRSTATUS` (if MSPI1 never shows there, `-12` and no MSPI1 access);
2. set the IO clock source (stock's HFRC 192 MHz), open the gate, then wait at least 10 µs;
3. only then touch MSPI1's registers, at SCK 12 MHz.

Before the hand-off it puts MSPI1 back as stock leaves it (powered down, clock gated). Each NOR transfer is bounded in total polls and by the phase's STIMER deadline. The new breadcrumbs are `boot-nor-power`, `boot-nor-clock` and `boot-nor-id`. The app is stage-0b's, version 0.3.0 (IDENT `Wisp 0.3.0 kind 16`). MIT, our own code; nothing of Even's.

**Pinned at W24e-0** (2026-11-10, PR #89) after an independent review that rebuilt these files byte-identical from `58a5cf8` at the canonical path: `wisp_w18/pins.py` lists the image in `WISP_IMAGES["stage-0c"]` (`proposed-pin.json`'s `image` copied unchanged, plus `crc32_aligned_over_stage_0b`) and its Wisp Boot slot `f13335bd…` in `WISP_BOOT_PASSED`; `PEEK_REGIONS["wisp-boot-status"]` is stage-0c's `st` (`0x20375340`), stage-0b's stays readable as `wisp-boot-status-stage-0b`. `tests/test_stage0c.py` runs install-wisp's whole gate on these files against the repository's pins and refuses a one-byte change to any of them; `wisp-fw:w18-test stage-0c` installs them through the patched loader in Renode.

| File | SHA-256 | What |
| --- | --- | --- |
| `stage-0c.bin` | `b41bfd5d353640edb7671f560a88d3238f2ee6a97d782a8a58040c2223e03d2a` | the image: Wisp Boot padded to 64 KiB (slot `f13335bd…`; `wisp_boot.bin` `9097fc71…`, 12,000 B), then the app at `0x448000` (5,400 B). 70,936 B, zlib CRC-32 `ad4bc401`; ends at `0x449518` (writes bounded by `0x449520`) |
| `stage0.map` | `c257fe00b42e31c1d11eeff94106f5154c4218a4f4147e041edaa6727c4c1ae8` | the app's linker map, as built (it holds the build checkout's absolute paths) |
| `stage0.elf` | `d70495a80d705a06dc8c8cb24ad06e62656400bbcf356e9f002249fc90172ae0` | the app's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | `09b853425832c6cfc6179f0d8857602ac0f204fe2255e004232b22c1d96b94e2` | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone and `wisp_dcache_clean` addresses from it |
| `manifest.json` | `abbea3f611396595b0f96b940d93cc3b8e36846aae3e6345efd0fa20e2ef13e9` | the build's own manifest (its ELF hashes are of the unstripped ELFs) |
| `proposed-pin.json` | — | the proposed pin entries |

**Built** on t3-worker from commit `58a5cf8` (clean tree; the app reports rev `58a5cf87f4`) at the checkout path `/home/jappy/.t3/worktrees/lotti/t3-4445548f` with `apps/wisp-fw/scripts/build_native.sh stage-0c`. `scripts/package_native.sh stage-0c` copied the files here, and `scripts/propose_pin.py stage-0c --commit 58a5cf8` wrote `proposed-pin.json`. The build's gates all passed: `check_image` (Wisp Boot and `--part app`), `check_rule8` on both, `check_no_mram_write` on both, `check_native.py --observe --bare-app-elf`, and wisp-ota's `pack-main` (`SENDABLE`). The reproduction, the same way as stage-0b's (a second checkout of the commit bind-mounted at that path; see `../stage-0b/README.md`), is recorded in rung4.md W24e.

**Final CRC.** install-wisp writes whole 16-byte units, keeping what follows the image in its last unit. So its final CRC over `[0x438000, 0x449520)` (the image plus 8 bytes) depends on what the region held before (`proposed-pin.json` `crc32_aligned_over`):

| Before | Final CRC |
| --- | --- |
| stock 2.4.0.24 | **`d976c4e8`** |
| stage-0b (W24d left it on the left temple) | **`d976c4e8`**: stage-0b ended at the same `0x449518`, so those 8 bytes are still stock's |
| stage-0 | `d976c4e8` |
| native-0 | `db51218a` (the 8 bytes are native-0's) |

`app-check` compares the image's own 70,936 bytes with `ad4bc401`.
