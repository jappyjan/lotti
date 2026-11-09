# stage-0b (built, NOT pinned, W24d)

The image after W24b's stage-0 (docs/wisp/rung4.md, "W24d: stage-0b"): stage-0 with the three silicon fixes of W24d, all in code shared by the observe-only Wisp Boot and the bare-metal app (`apps/wisp-fw/src/boot/stage/`, `src/boot/wisp_diag.h`, `src/stage0/`):

1. the case UART is driven **half duplex** (one pogo wire: listen with pad 42 parked, turn round only to send), as stock and the patched loader do;
2. Wisp Boot's NOR driver no longer writes `MSPICFG = 0` (which asserts PRSTN/IPRSTN and holds MSPI1 in reset), read-modify-writes the MSPI registers it touches, and the whole NOR phase is bounded (a STIMER deadline and a poll budget) and fed per block;
3. every update of the diagnostics record and of Wisp Boot's status block is **cleaned out of the D-cache** (DCCMVAC by line), so a watchdog reset no longer loses them.

MIT, our own code; nothing of Even's.

**Not pinned.** `wisp_w18/pins.py` does not list it, and `install-wisp` refuses it before the case (`tests/test_stage0b.py`). An independent review and the pinning commit come first. `proposed-pin.json` holds what that commit would copy into `pins.WISP_IMAGES` and `pins.WISP_BOOT_PASSED`, plus the new address of Wisp Boot's status block for `pins.PEEK_REGIONS["wisp-boot-status"]` (`st` moved from `0x20375330` to `0x2037533C`). The Renode harness (`wisp-fw:w18-test stage-0b`) loads it into the pin tables of its own process to run install-wisp's gate on these files.

| File | SHA-256 | What |
| --- | --- | --- |
| `stage-0b.bin` | `e5c70fb4d6a90ce21beb3e4e75f00093cf1e218100c6d40e2c8212da98ca587d` | the image: Wisp Boot padded to 64 KiB (slot `e673d6cd…`; `wisp_boot.bin` `7cec83a0…`, 11,536 B), then stage-0b at `0x448000` (5,400 B). 70,936 B, zlib CRC-32 `d10cc7b6`; ends at `0x449518` (writes bounded by `0x449520`) |
| `stage0.map` | `3650b6c7159809fc65823040f82e33080afe1378f1b21ad8848fee630c8534ee` | stage-0b's linker map, as built (it holds the build checkout's absolute paths) |
| `stage0.elf` | `961c8a651a680f052e3eebbf276ec46cd0cf5d7bd3f80571046cf2be046c7fca` | stage-0b's ELF after `arm-none-eabi-objcopy --strip-debug` (gcc-arm-embedded 15.2.rel1 from the wisp-fw flake) |
| `wisp_boot.elf` | `228fb70890294ce93df6c307126524815fde79f5b4ce76bd3bf73bc7df27cab9` | Wisp Boot's ELF, `--strip-debug`; the Renode harness takes its milestone and `wisp_dcache_clean` addresses from it |
| `manifest.json` | `5bfc725ea364005d28ad0658e8f475e65d8ea17c4f6ab428a2e9d899642083a0` | the build's own manifest (its ELF hashes are of the unstripped ELFs) |
| `proposed-pin.json` | — | the proposed pin entries (above) |

**Built** on t3-worker from commit `91035fc` (clean tree; stage-0b reports rev `91035fc98e`) at the checkout path `/home/jappy/.t3/worktrees/lotti/t3-b19ef7ba` with `apps/wisp-fw/scripts/build_native.sh stage-0b`, copied here by `scripts/package_native.sh stage-0b`, and `proposed-pin.json` written by `scripts/propose_pin.py stage-0b --commit 91035fc`. The build's gates: `check_image` (Wisp Boot and `--part app`), `check_rule8` on both, `check_no_mram_write` on both, `check_native.py --observe --bare-app-elf`, and wisp-ota's `pack-main` (sendable).

**Reproduced** the same day from a second checkout of `91035fc` (its own `.wisp-cache`), bind-mounted at that path in a private mount namespace: image, both stripped ELFs, the map and the manifest byte-identical. The map's hash depends on the checkout path, so a review that builds elsewhere reproduces it the same way:

```sh
C=/home/jappy/.t3/worktrees/lotti/t3-b19ef7ba   # the path the map records
R=<the review checkout of 91035fc, with .wisp-cache/{west,stock} and packages/wisp-ota/dist>
unshare -rm bash -c "mkdir -p $C && mount --bind $R $C && exec unshare --map-user=1000 --map-group=100 \
  bash -c 'cd $C && apps/wisp-fw/scripts/build_native.sh stage-0b'"
```

(`mkdir -p` only if the path does not exist; the outer namespace maps the user to root so it may mount, the inner one maps back to the user so nix and git work.) A build of a later tree differs in the 10-byte revision string stage-0b reports (`STAGE0_REV`), nothing else.

`install-wisp` writes whole 16-byte units, so over the stock 2.4.0.24 main its final CRC over `[0x438000, 0x449520)` (the image and the 8 stock bytes after it) is **`1ad236d1`** (the proposed `crc32_aligned_over_stock`); `app-check` compares the image's own 70,936 bytes with `d10cc7b6`.

Wisp Boot's rung-3 results with this build (rule 12) and the Renode evidence: docs/wisp/rung4.md, "W24d: stage-0b".
