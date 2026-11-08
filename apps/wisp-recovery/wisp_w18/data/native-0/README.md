# native-0, pinned (W23)

The first native Wisp image, as `w18.py install-wisp` writes it at `0x438000` (docs/wisp/rung4.md §2, W23/W24). These are the files of the **reviewed build**: `apps/wisp-fw` at commit `8374f9a`, built with `pnpm nx run wisp-fw:build-native` (`scripts/build_native.sh native-0`). They are pinned in `wisp_w18/pins.py` (`WISP_IMAGES["native-0"]`, `WISP_BOOT_PASSED`), and `install-wisp` refuses any other bytes. MIT, our own code (Wisp Boot and the Zephyr app); nothing of Even's.

| File | SHA-256 | What |
| --- | --- | --- |
| `native-0.bin` | `5d373fd8874275a3a59d18306536a4b73a4f4361e92050ee22583faedfd60bba` | the image: observe-only Wisp Boot padded to 64 KiB (slot `16616d9d…`; `wisp_boot.bin` `d793a93e…`, 8,256 B), then the app at `0x448000`. 230,428 B, ends at `0x47041c` (writes bounded by `0x470420`). zlib CRC-32 `c0dd9dc0` (what `app-check` compares) |
| `zephyr.map` | `28fcb218edaeb3302c1bc226b3483fa64393760d4eaf03e92491f87a4d4647c0` | the app's linker map, as built (it holds the build checkout's absolute paths; that is why it is pinned as built and not rebuilt elsewhere) |
| `zephyr.elf` | `4411c3ada90ea09a40c97986c8f957b6ba7419676b9da893e723e78312877510` | the app's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake): symbols and every loaded section kept, no debug info and no paths. `install-wisp` checks every loaded section against the image |
| `manifest.json` | `35ed2019…` | the build's own manifest, unchanged. Its `app_elf_sha256` and `boot_elf_sha256` are the unstripped ELFs, which are not committed |
| `wisp_boot.elf` | `3c9d5e3e…` | Wisp Boot's ELF, `--strip-debug` too. Not pinned and not read by `install-wisp`: the Renode harness (`wisp-fw:w18-test`, `native-0` cases) takes Wisp Boot's milestone addresses from it |

## How it was reproduced

On t3-worker, 2026-11-08: a scratch worktree at `8374f9a`, built in a private mount namespace in which it appeared at the reviewed build's own checkout path (the map embeds that path). Results, equal to the review's: image `5d373fd8…` (230,428 B), app map `28fcb218…`, Wisp Boot `d793a93e…`, slot `16616d9d…`. The build's gates, from its log:

```
-- Wisp hardware image gate: panel off, PMIC observe-only, no test switches
check_image: OK load 0x00448000 end 0x0047041c (3701732 bytes free) SP 0x200904e0 reset 0x0044b681
check_rule8: OK bt=on, 2962 symbols, no forbidden symbols, map clean, 6 EM9305 image signatures absent, EM9305 units preprocessed clean, no NVM write/erase opcode in 4 checked
check_no_mram_write: OK 2962 symbols, map clean, no program key or boot-ROM helper address in 164892 bytes or built by movw/movt
```

followed by `check_native.py` (layout, both vector tables, Wisp Boot's slot) and wisp-ota's `pack-main` (sendable).

Wisp Boot's rung-3 results (rule 12; PR #77): the observe suite 6/6 on the stock 2.4.0.24 bootloader and 6/6 on the patched `87e2d4e0…`.

## The CRC the W24 report shows

`install-wisp` writes whole 16-byte units, so its final CRC (`crc_after`) covers `[0x438000, 0x470420)`: the image plus the 4 bytes after it, which keep what MRAM held there. Over the stock 2.4.0.24 main (the left temple at W24) that is **`efde0857`** (`pins.WISP_IMAGES["native-0"]["crc32_aligned_over_stock"]`; the Renode `native-0` case checks it). `app-check` reads the image's own 230,428 bytes and compares with `c0dd9dc0`.

## A newer native-0

A rebuild of a later commit gives another image hash (the app embeds its git revision). Pinning one means a reviewed commit that replaces these files and the pins together; `tests/test_install_wisp.py` checks that the files and the pins agree.
