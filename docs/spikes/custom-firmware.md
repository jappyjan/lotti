# Spike: can we run custom firmware on the G2? — yes, and it's already done

Status: done 2026-11-01. Goal: answer whether the G2's main-MCU firmware can be replaced, and map the landscape around it.

## Verdict

Yes. The firmware image is **not cryptographically signed** — it is only CRC-checked (CRC32C + CRC32) — so the unsigned OTA path accepts modified images. Custom firmware is already being built and flashed by several open-source projects.

## Why it works

- **No signature.** The OTA response enum (`g2.ota_transmit.eOTATransmitRsp`) has `CRC_ERR` and `CHECK_FAIL` but no signature/verify error. `CHECK_FAIL` = component CRC32C + mainApp preamble CRC32 mismatch (per g2flash's `--recompute-checksums` docs). The "Could not get signatures" strings in the app are Android APK self-verification, not firmware.
- **Bootloader** (Apollo, EVENOTA payload type 1, 7 modes) reports `{bootloader, mode, no-downgrade}`; the downgrade gate is a **string version comparison**, not a fuse counter. No unlock/debug flag in `dev_config` / `dev_settings` / `module_configure`.
- **OTA path is public** (SIDs 192–195: `START → INFORMATION → FILE → RESULT_CHECK → NOTIFY`).

## Hardware (for flashing and recovery)

| Part           | Chip                      | Notes                            |
| -------------- | ------------------------- | -------------------------------- |
| Main MCU       | Ambiq Apollo510B (M55)    | one per temple                   |
| BLE controller | EM9305 (ARCv2 EM)         |                                  |
| Voice codec    | GX8002 (C-SKY CK804EF)    |                                  |
| Touch          | PSoC 4000T                |                                  |
| Case MCU       | STM32G0B1                 | has STM32 ROM bootloader         |
| Case USB       | WCH CH340                 | pogo-pin UART (`5A A5 FF`), 1-Mbaud 8N1 |

No SWD/JTAG tap is exposed; the charging case's CH340 USB→UART is the recovery/brick path. The **R1 ring is signed** (Nordic nRF52840 Secure DFU) — a separate problem, out of scope here.

## Who is already doing it

| Project                                | What it is                                                                                          | Stars |
| -------------------------------------- | --------------------------------------------------------------------------------------------------- | ----- |
| `jimrandomh/faceclaw`                  | unofficial Android UI for the G2 (requires CFW): launcher, music, compass, assistant                | 97    |
| `jimrandomh/g2flash`                   | firmware-mod toolchain: downloads stock from Even's CDN, patches, re-hashes; full 640×480, display lists, compressed transport | 45    |
| `kalanihelekunihi/evenRealities-openCFW` | clean-room decompile → byte-identical C rebuild, with a full hardware reference (MCUs, toolchains, pinned upstream) | 26    |
| `AM-Guru/evenRealities-webflasher`     | browser analyzer/recovery/backup over the case's CH340 USB; EVENOTA bundles + case-flash backup; R1 signed DFU | 15    |
| `ithinkthisiscool/g2emu`               | real-firmware emulator (Renode) — run genuine firmware without hardware                               | 3     |

## Forks and experiments (what people are trying)

- **h264 video playback** — `Danxtream/g2flash-video-plus`
- **framebuffer window manager / compositor** — `expectbugs/damage-wm`
- **Thai glyph support in firmware** — `rayriffy/even-g2-thai`
- **faster image handling** — `jimrandomh/g2fast`
- **CFW research port for 2.2.8.4** — `not-benny/even-g2-cfw-research`
- **offline stock-firmware companion app** — `ithinkthisiscool/open-g2-hub`
- assorted personal `g2flash` forks (recently pushed, in-progress)

## What this means for Lotti

- Replacing the firmware is possible, but g2flash's own README warns it is the riskiest layer — a boot crash bricks OTA. Prefer phone-side changes when they suffice.
- The two highest-leverage plays for Lotti are (1) the **full 640×480 resolution + display lists** that faceclaw's mods unlock, if the 576×288 EvenHub ceiling ever binds, and (2) **g2emu** for iterating without risking hardware.
