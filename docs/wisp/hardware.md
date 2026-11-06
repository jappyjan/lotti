# Wisp — G2 hardware reference

What Wisp builds on. Every fact names its source; **[C]** = confirmed in the cited source, **[I]** = inferred, **[?]** = open.
Main sources: [openCFW](https://github.com/kalanihelekunihi/evenRealities-openCFW) `g2/docs/` (MIT), [webflasher](https://github.com/AM-Guru/evenRealities-webflasher) README (MIT), [g2flash](https://github.com/jimrandomh/g2flash) (GPL-3.0: read for facts, never copy code), [g2emu](https://github.com/ithinkthisiscool/g2emu) (MIT). Researched 2026-11-05.

## Topology

- **Two temples, two computers.** Each temple runs its own copy of the same image and drives its own eye's panel [C]. The right temple (side id 1) is master: it owns the ambient light sensor and the input manager [C].
- The temples talk over a UART through the frame's flex (TinyFrame, CRC-16/ARC, 24 KiB max payload in stock) [C].
- Each temple is its own BLE peripheral (`Even G2_<pair>_<L|R>_<mac>`) [C, Lotti S1].

## Parts (per temple unless noted)

| Function       | Part                                                                                                                      | Bus / address              | Source                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------ |
| Main MCU       | Ambiq Apollo510B, Cortex-M55 + MVE (Helium), NemaGFX GPU                                                                  | —                          | [C] openCFW `g2-glasses.md`                      |
| Memory         | 4 MiB MRAM, 512 KiB DTCM (`0x20000000–0x20080000`) + 3 MiB SSRAM (`0x20080000–0x20380000`); stock initial SP `0x2007FB00` | —                          | [C] §8.1, openCFW `reference/memory-map.md`      |
| External flash | MX25U25643G or (stock ≥ 2.2.9.22) GD25LE256H, 32 MiB NOR (littlefs at `0x1400000`, FlashDB at `0x1FC0000`); ours: [?]     | MSPI1 CE0                  | [C] `memory-map.md`, rung 3, 2.4.0.24 bootloader |
| BLE controller | EM9305 (own firmware, own NVM), HCI                                                                                       | IOM6 SPI                   | [C]; separate die vs. in-package [?]             |
| Display        | microLED 640×480, 4-bit grey (green); JBD JBD4010 or Hongshi A6N-G                                                        | MSPI0 quad SPI, 320 B/line | [C] §2, §5                                       |
| Voice codec    | GX8002 (C-SKY), 2 DMICs, I2S 16 kHz 16-bit 2 ch out                                                                       | I2S                        | [C]                                              |
| Extra mic path | PDM0 on the Apollo                                                                                                        | PDM                        | [C]                                              |
| IMU            | TDK ICM-45608 (accel + gyro)                                                                                              | I2C4 `0x69`                | [C]                                              |
| Magnetometer   | likely ICT1531x                                                                                                           | IMU aux I2C `0x1E`         | [I]                                              |
| Touch + wear   | PSoC 4000T (CY8C4046FNI): touchpad and proximity (wear)                                                                   | I2C5 `0x0C`                | [C]                                              |
| Ambient light  | TI OPT3007 (some sources: OPT3001), right temple only                                                                     | `0x45`                     | [C]                                              |
| Power          | Board A: nPM1300 `0x6B`. Board B: BQ25180 `0x6A` + BQ27427 gauge `0x55`                                                   | I2C7                       | [C]                                              |
| Battery        | 96 mAh per temple                                                                                                         | —                          | [C]                                              |
| Sound out      | **No speaker.** PWM piezo buzzer (GPIO145)                                                                                | PWM                        | [C]                                              |
| Debug UART     | stock log + CLI shell; UART2 = case link                                                                                  | UART1 `0x4003A000`         | [C] g2emu (stock in Renode)                      |
| Case           | STM32G0B1 (dual-bank, ROM bootloader) + CH340 USB-UART, pogo UART 1 Mbaud to each temple                                  | —                          | [C]                                              |
| Ring (R1)      | nRF52840, **signed** Nordic Secure DFU — out of scope                                                                     | BLE                        | [C]                                              |
| Camera         | none                                                                                                                      | —                          | [C]                                              |

Memory detail (hal_ambiq `am_apollo510.h`, g2emu): DTCM is `0x20000000–0x20080000` and SSRAM `0x20080000–0x20380000`. Ambiq's Zephyr DTS maps only the first `0x7C000` of DTCM; stock puts its initial SP at `0x2007FB00`, in the last 16 KiB. Ambiq's Zephyr `flash0` starts at `0x410000` (the SBL is outside it), so devicetree partition offsets are relative to `0x410000`.

## MRAM map (Apollo510, per temple)

| Range               | What                                                                                                                                                                             | Wisp may write?                                         |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `0x400000–0x410000` | Ambiq SBL (secure ROM bootloader)                                                                                                                                                | **never**                                               |
| `0x410000–0x438000` | Even bootloader (stock `ota/s200_bootloader.bin`; image ends `0x434477` on 2.2.6.10, `0x434900` on 2.3.2.14, `0x43490D` on 2.4.0.24)                                             | **never**                                               |
| `0x437FE0`          | nothing is written here: the bootloader skips the 32-byte preamble and programs `payload[0x20:]` at `0x438000` [C, rung 3]                                                       | —                                                       |
| `0x438000–…`        | main application (stock ends `0x794324` on 2.2.6.10, `0x7F5AAC` on 2.3.2.14: only 9.3 KiB below the ceiling; `0x7BF564` on 2.4.0.24: 226.7 KiB below it) [C, `wisp-ota inspect`] | via stock install only                                  |
| ceiling `0x7F8000`  | hard limit for the app's end (g2flash guard)                                                                                                                                     | —                                                       |
| `0x7FE000` (16 B)   | update-flag record, bootloader-owned; semantics below                                                                                                                            | only the documented flag value, only from verified code |
| `…–0x800000`        | NV / bond area; writing past `0x800000` = SWD-only brick                                                                                                                         | **never**                                               |

## Boot and update chain (stock)

1. SBL (ROM) → Even bootloader `0x410000`.
2. Even bootloader: if the update flag says so, read the 32-byte header of the staged file `ota/s200_firmware_ota.bin` on the NOR littlefs, check its CRC, program MRAM from `0x438000`, check the SP vector, hand off [C, `protocols.md` §6]. CRC failure → "Bootloader ota fail, system reset" [C].
3. Main app at `0x438000`. **It alone** contains the BLE host (Cordio), GATT, and the OTA service [C]. The bootloader has no BLE [C].
4. OTA (phone → app): EVENOTA bundle over sid `0xC0/0xC1`; for the main component the app writes the littlefs staging file, verifies its CRC, writes `0x55555555` to the flag and resets after 3 s [C, `findings-hardware-drivers.md:606`].

**Consequences:** single slot, no rollback, no boot counter [C]. A main app that crashes before BLE is up cannot take an OTA any more → SWD-only recovery [C, g2flash README]. SWD pads are undocumented [?]; SBL UART recovery depends on per-device INFO0 provisioning nobody has read yet [?]. The stock bootloader has no UART receive path at all ([recovery.md](recovery.md#do-the-charging-pins-carry-anything-besides-power)).

### What the 2.2.6.10 bootloader does, step by step (rung 3)

Reverse-engineered from the stock bootloader (Ghidra + objdump on the copy in `.wisp-cache/`, never committed) and then **observed running it unmodified in Renode** (`apps/wisp-fw` `boot-test`, README "Rung 3"). Addresses are in that bootloader. [C] below means confirmed both ways.

- **Start-up** [C]: board detect over the ADC (3 conversions; `0x430000`), MSPI1 NOR init (RSTEN/RST, RDID must read `C2 25 39`, a 36-setting timing scan, quad enable, 4-byte mode), littlefs mount (format on failure), create `/firmware /ota /user /log`, **increment the littlefs file `boot_count` on every boot** — the bootloader writes the NOR on every boot, not only when installing.
- **Flag check** `is_need_updata_image` (`0x42E224`) [C]: reads **only word 0** of `0x7FE000`; install iff it equals `0x55555555`. Words 1–3 are never read.
- **Install** (`0x42DE58`, DFU task) [C]: open the staging file (open failure → error reset, see below), read its 32-byte preamble, require flags bit 26 (`0x04 << 24`), stream-check the zlib CRC-32 over `[8, size)` against word 1 (failure → error reset), then copy `[0x20, size)` to MRAM at the preamble's run base in 4 KiB chunks through the boot ROM (below), reading each chunk back ("flash write verify ok"). Run base ≠ `0x438000` is logged and forced to `0x438000`. The preamble itself is never written to MRAM.
- **Hand-off** [C]: only if `*(0x438000)` (the initial SP) has bit 29 set (`0x2xxxxxxx`); then de-init, VTOR = `0x438000`, jump to word 1. If the SP word fails that check the DFU task just waits for the next message: **the bootloader hangs** (no watchdog is armed by it).
- **No flag clear after a good install** [C]: the flag stays `0x55555555`, so every later boot **reinstalls the staging file** until something clears the flag. The stock app does: its OTA service init (`0x4486BC` in the 2.2.6.10 app) writes `{0xFFFFFFFF ×4}`; the setter (`0x478860`) writes `{value, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF}` and skips the write when word 0 already equals the value.
- **Error reset** `bootloader_error_reset` (`0x42DE0E`) [C]: writes `{0xFFFFFFFF ×4}` to the flag, then a software POR (`RSTGEN.SWPOR = 0xD4`). So a missing or corrupt staging file clears the flag and the next boot jumps to whatever is in MRAM — the CRC check runs before any MRAM write, so that image is intact.
- **Interrupted install** [C, rung 3 power-cut cases]: the flag is still set and the staging file unchanged, so the next boot reinstalls from the start.

### Update-flag record (`0x7FE000`, 16 bytes)

| Value of the 4 words                             | Written by                                                  | Meaning to the bootloader                                      |
| ------------------------------------------------ | ----------------------------------------------------------- | -------------------------------------------------------------- |
| `0x55555555, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF` | stock app after a verified main OTA; **Wisp Boot's rescue** | install `ota/s200_firmware_ota.bin` (every boot until cleared) |
| `0xFFFFFFFF ×4`                                  | stock app OTA init; bootloader on an install error          | no install, jump to `0x438000`                                 |
| anything else in word 0                          | — (e.g. erased MRAM)                                        | no install                                                     |

Only word 0 matters; Wisp writes the record exactly as stock does. These are the "documented flag values" of safety rule 1.

### MRAM programming

All MRAM writes go through the Apollo510 **boot-ROM helper** `nv_program_main2(key, program, src, word_offset, n)` at `0x0200FF20` (hal_ambiq `am_hal_bootrom_helper.c`; key `0x12344321`; destination `0x400000 + 4·word_offset`), wrapped by AmbiqSuite's `am_hal_mram_main_program()` (16-byte aligned destination, multiple of 4 words) [C: the bootloader's flag write at `0x42E4F4` and its install both call it]. Plain CPU stores to MRAM are not the write path. Renode models the ROM entry (`renode/models/WispBootRom.cs`) and logs every call, so the harness can prove which code wrote what.

### NOR littlefs (as the bootloader mounts it)

littlefs 2.10.1 (on-disk 2.1) at NOR `0x1400000`, block `n` at `0x1400000 + n·4096`: read 16, prog 256, block 4096, count 3008, block_cycles 500, cache 4096, lookahead 256, no name/file/attr limits set (defaults), no lock callbacks [C: the bootloader's `lfs_config` at `0x431070`; openCFW `memory-map.md`; and in Renode a host littlefs 2.11 with this config mounts what the real bootloader formatted, and the bootloader mounts what the host wrote]. Driver opcodes seen: RDID `0x9F`, RDSR `0x05`, RDCR `0x15`, WREN `0x06`, EN4B `0xB7`, quad-output 4-byte read `0x6C`, page program, 4 KiB sector erase.

## Stock 2.4.0.24 (installed on Jan's temples)

Both temples report **2.4.0.24** (read-only, right temple, sid `0x09`, 2026-11-06). Everything above was first worked out on 2.2.6.10. This section says what still holds on 2.4.0.24. Method: static analysis of the copy in `.wisp-cache/` (never committed), objdump and instruction-level diffs against 2.2.6.10 and 2.3.2.14, and rung 3 in Renode. Addresses are 2.4.0.24 run addresses.

**Bundle** [C]: `cdn.evenreal.co/firmware/a0d486afe862a9121657477b98667c95.bin`, 4 482 361 B, SHA-256 `363198f8…0fd0e05`, built 2026-10-23. Webflasher's catalog stops at 2.3.2.14. The md5 and size are Even's own update metadata as recorded by rayriffy/even-g2-thai (MIT); the file from cdn-az.evenrealities.com is byte-identical. Pinned in `catalog.ts`.

| #   | Type         | Path                        | Payload   | vs 2.2.6.10          |
| --- | ------------ | --------------------------- | --------- | -------------------- |
| 1   | 4 codec      | `firmware/codec.bin`        | 329 092   | changed              |
| 2   | 5 EM9305     | `firmware/ble_em9305.bin`   | 211 948   | identical            |
| 3   | 3 touch      | `firmware/touch.bin`        | 34 720    | changed (= 2.3.2.14) |
| 4   | 6 case       | `firmware/box.bin`          | 55 784    | identical            |
| 5   | 1 bootloader | `ota/s200_bootloader.bin`   | 149 773   | changed (below)      |
| 6   | 0 main       | `ota/s200_firmware_ota.bin` | 3 700 100 | new build            |

- **EVENOTA format: unchanged** [C]. Same header, TOC, trailer, 128-byte component headers, storage type 3 for every component, entry ids 1..6, CRC-32C per component. Every `wisp-ota` guard passes, and only `main-only` fails, as it does on every stock bundle.
- **Main app** [C]: the preamble is unchanged (flags `0x04`, size 3 700 100 = payload, type `0xCB`, run base `0x438000`, zlib CRC-32 `0x971F4516` over `payload[8:]`). SP `0x2007FB00`, reset `0x005FBE3F`. Installs `[0x438000, 0x7BF564)`, which leaves 226.7 KiB below the `0x7F8000` ceiling. 10 standalone version strings, as in 2.2.6.10.
- **Flag record: same address, same values** [C]. The setter `0x483708` loads `0x7FE000` and writes `{value, ~0, ~0, ~0}`, skipping the write when word 0 already holds the value, like 2.2.6.10's `0x478860`. The OTA service clears it with `0xFFFFFFFF` at `0x44AC8A`, the counterpart of 2.2.6.10's OTA-init clear. RESULT_CHECK of the main image sets it (`0x448C92`, `0x55555555`). The settings page is at `0x7FF000` (even-g2-thai). Nothing moved, so `UPDATE_FLAG_ADDRESS` and the `0x7F8000` ceiling stay single constants.

### Bootloader 2.4.0.24 vs 2.2.6.10

Image `[0x410000, 0x43490D)`. The DFU task, the flag check, the install, the error reset and the MRAM write wrapper are **instruction-identical** to 2.2.6.10, only relocated by `+0x358`: `is_need_updata_image` `0x42E57C`, install `0x42E1B0`, `bootloader_error_reset` `0x42E166`, the MRAM-program wrapper `0x42E84C` (`0x42E4F4` on 2.2.6.10), flag literal `0x7FE000` and ROM key `0x12344321` in the same pools [C, objdump diff]. The staging file is still `ota/s200_firmware_ota.bin`. Install is still to `0x438000`, with hand-off on SP bit 29. There is **no version check** (no compare code, no version strings) [C].

What changed is the NOR driver [C]:

- A second part, **GigaDevice GD25LE256H** (RDID `C8 60 19`), next to the MX25U25643G (`C2 25 39`). The classifier is at `0x41FE1A`: MX → 0, GD → 1, anything else → 2, logged as "Unknown nor flash ID 0x%06X, fallback to %s semantics". 2.2.6.10 only knew the MX part. The quad-enable and 4-byte-mode paths are per part (`mx_*` / `gd_*`). An MSPI flash mutex was added.
- Since 2.2.9.22 (strings: the GD driver first appears there, in both the bootloader and the main app). The 2.3.2.14 → 2.4.0.24 change is one low-level transfer helper (`0x41F918`) that gained a fourth argument; its only caller (`0x41B85C`) passes 0. The rest is relocation.

Rung 3 ran this bootloader unmodified in Renode (the NOR model answers MX): see [safety.md](safety.md#rung-3-status-2026-11-06).

### Stock OTA receiver 2.4.0.24 vs 2.2.6.10 (what `wisp-ota`'s sender relies on)

- **Unchanged** [C]: the GATT service `…1001`, the characteristics `…0001`/`…0002`/`…5401`/`…5402`, and the staging path `ota/s200_firmware_ota.bin`. Every OTA reply site, as (sid, subcommand, status): there are 36 in each version, with the same multiset `{C0:0/0, 0/10, 1/0, 1/1, 1/6, 3/7, 3/8, 4/9; C1:2/0, 2/6}`, all through one send function (`0x446CD4`). The 3000 ms reset timer after `{4, 9}` (`0x448CB4`). The 1500 ms transport RX timer (`0x4A2F88`), which now carries a generation counter so a stale timeout is dropped.
- **New in 2.4 (not in 2.2.6.10)** [C, strings and code]:
  - **RESULT_CHECK re-reads the whole staged file** (`0x449C2C`: size against the header, CRC-32C against the component CRC) **before** it answers `{3, 8}`. It logs `fs readback verify … cost %d ms`. The reply therefore comes later than on 2.2.6.10, by the time it takes to read 3.6 MB from littlefs. That time is unmeasured. Above the sender's 8 s control timeout, the sender ends in `result-unknown`, which is safe: the flag is set or not, and the next step is to reconnect and read the version.
  - **OTA idle watchdog**: checked every 10 s (`0x44AE5E`). It aborts a session with no OTA RX for **90 s** (300 s while the glasses process locally). The sender's longest gap is the 8 s control timeout.
  - An interface lock: BLE OTA messages are dropped while an OTA session runs over UART (the case). Abort requests are refused while traffic is fresh. A transport abort on disconnect. The per-block "read data != write data" log string is gone; the whole-file readback looks like its replacement [I].

### Which hooks and facts are 2.2.6.10-only

All addresses in [host-mode.md](host-mode.md), and the openCFW citations (openCFW reconstructs 2.2.6.10), are 2.2.6.10 run addresses. None carry over to 2.4.0.24: the 2.4 main app is a new build, and even-g2-thai's rebase shows its functions moved independently (for example, the font chain builder `0x471238` → `0x4758F0`). The protocol facts above were re-checked; the hook addresses were not.

## Image formats

- **EVENOTA:** `EVENOTA\0`, count `+0x08`, `+0x0C` = 0, date/time/version strings `+0x10/0x20/0x30` (16 B each, NUL-padded; version `s200_v<x.y.z.w>`), TOC at `0x40` (16-B entries `{id, off, size, crc32c}`, `size` = 128 + payload), trailer `evenota\0` + 8 zero bytes. Components follow contiguously (unaligned) and close exactly at EOF. Each component = 128-B header (`+0/+4/+0x10/+0x20` = 0, size `+8`, CRC32C `+0xC`, magic `EVEN` `+0x14`, `+0x18/+0x1C/+0x2C` = `0xFFFFFFFF`, type `+0x24`, storage type `+0x28`, path `+0x30`, 80 B) + payload [C, `firmware-formats.md`; all 19 official bundles 2.0.1.14–2.4.0.24 checked with `wisp-ota`].
- Entry ids run 1..n in TOC order. Most bundles carry 6 components (codec, EM9305, touch, case, bootloader, main); **2.2.0.24 and 2.2.4.34 carry 5 (no bootloader), so main is entry 5 there** [C, `wisp-ota inspect`]. Every stock component uses storage type 3.
- Official bundles: `https://cdn.evenreal.co/firmware/<md5>.bin` (Even's CDN); pinned SHA-256s in `packages/wisp-ota/src/catalog.ts` [C, webflasher catalog, g2flash `build_cfw.sh`].
- Component types: main 0, bootloader 1, font 2, touch 3, codec 4, EM9305 5, case 6. Storage: 0 MRAM, 1 XIP NOR (read-back verified), 3 littlefs file [C].
- CRC-32C MSB-first (poly `0x1EDC6F41`, init 0, xorout 0) per payload, in TOC and subheader [C].
- Main-app preamble (32 B): word0 = `0x04<<24 | size`, where size is the whole payload **including** the preamble; word1 = zlib CRC32 over `payload[8:]`; `+0x10` type `0xCB`; `+0x14` run base `0x438000`; `+0x08/+0x0C/+0x18/+0x1C` = 0. The bootloader programs `payload[0x20:]` at the run base [C].
- The bootloader takes the run base and the 24-bit size from the preamble **without a bounds check**; an oversized image overruns into the flag / NV area. `wisp-ota` is therefore the only guard [C, g2flash `APP_MAX_END` comment].
- A main-only bundle is accepted [C, g2flash #3].
- Downgrades are not blocked on the glasses [C, faceclaw #56, #6]. The 2.4.0.24 code agrees: neither its bootloader nor its main app's OTA receiver compares versions (no version-compare code or strings, the same reply statuses as 2.2.6.10; [2.4.0.24 section](#stock-24024-installed-on-jans-temples)) [C, static]. The "string version comparison" in [docs/spikes/custom-firmware.md](../spikes/custom-firmware.md) is a field in the Even app's protobuf, so a phone-side rule, not glasses code [I].
- **Never install a main app older than 2.2.9.22 on a temple whose NOR chip is unknown.** 2.2.9.22 added a second NOR part (GigaDevice GD25LE256H) to both the bootloader and the main app; every older build drives only the Macronix MX25U25643G [C, strings in all 19 bundles]. An older app on a GD temple may fail to mount the littlefs that the OTA path stages into [I].

## Stock link facts (for planning throughput)

- Stock: 30 ms interval, latency 4 when idle, DLE 247, 1M PHY; about 8 KB/s phone, about 50 KB/s from BlueZ [C, damage-wm].
- With 2M PHY + 7.5 ms interval (g2flash patch): about 41 KiB/s measured; phones may clamp the interval (Android 11.25 ms; iOS 15 ms) [C].
- Per-message round trip floor about 60–70 ms [C].
- Panel transfer of one full frame: 1.2–6.6 ms [C, damage-wm]. Stock tick is 1.024 ticks/ms — drifts 1.4–2 % against the phone [C].

## Power facts

- Worn, stock: about 7.5 %/h (100 → 67 % in 4.4 h) [C, damage-wm].
- Stock uses FreeRTOS tickless idle and an EM9305 sleep manager [C]. Apollo watchdog about 30 s [C].

## Open hardware questions

- Which NOR part our temples have (MX25U25643G or GD25LE256H). It decides whether any main app older than 2.2.9.22 is safe to install (Even app device info or a stock log line `Nor flash chip: %s` might tell).
- How long 2.4.0.24's RESULT_CHECK readback of the staged 3.6 MB file takes (its log line `fs readback verify … cost %d ms`).
- SWD pad location and a working attach: unlabelled, unmapped, behind a glued pod; see [recovery.md](recovery.md#1-swd-on-the-temples).
- INFO0/INFOC provisioning (does SBL UART recovery exist on retail units?).
- Which power board our units have (nPM1300 or BQ25180 + BQ27427).
- Which panel variant our units have (JBD4010 or A6N-G); panel init sequences.
- EM9305: firmware patch load at boot needed? Wire format of its DFU.
- Inter-temple UART: baud rate, real throughput.
- Whether SRAM survives a software POR / watchdog reset on the real chip (Wisp does not rely on it; rung 3 fills SRAM with `0xA5` on every reset).
- MSPI1 pin mux and the power/clock state the bootloader leaves behind at hand-off (Wisp Boot re-applies the stock DEV0CFG/PADOUTEN values; unverified on glasses).
