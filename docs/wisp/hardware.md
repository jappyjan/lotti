# Wisp — G2 hardware reference

What Wisp builds on. Every fact names its source; **[C]** = confirmed in the cited source, **[I]** = inferred, **[?]** = open.
Main sources: [openCFW](https://github.com/kalanihelekunihi/evenRealities-openCFW) `g2/docs/` (MIT), [webflasher](https://github.com/AM-Guru/evenRealities-webflasher) README (MIT), [g2flash](https://github.com/jimrandomh/g2flash) (GPL-3.0: read for facts, never copy code), [g2emu](https://github.com/ithinkthisiscool/g2emu) (MIT). Researched 2026-11-05.

## Topology

- **Two temples, two computers.** Each temple runs its own copy of the same image and drives its own eye's panel [C]. The right temple (side id 1) is master: it owns the ambient light sensor and the input manager [C].
- The temples talk over a UART through the frame's flex (TinyFrame, CRC-16/ARC, 24 KiB max payload in stock) [C].
- Each temple is its own BLE peripheral (`Even G2_<pair>_<L|R>_<mac>`) [C, Lotti S1].

## Parts (per temple unless noted)

| Function       | Part                                                                                                                      | Bus / address              | Source                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------- |
| Main MCU       | Ambiq Apollo510B, Cortex-M55 + MVE (Helium), NemaGFX GPU                                                                  | —                          | [C] openCFW `g2-glasses.md`                 |
| Memory         | 4 MiB MRAM, 512 KiB DTCM (`0x20000000–0x20080000`) + 3 MiB SSRAM (`0x20080000–0x20380000`); stock initial SP `0x2007FB00` | —                          | [C] §8.1, openCFW `reference/memory-map.md` |
| External flash | MX25U25643G, 32 MiB NOR (littlefs at `0x1400000`, FlashDB at `0x1FC0000`)                                                 | MSPI1 CE0                  | [C] `memory-map.md`, rung 3                 |
| BLE controller | EM9305 (own firmware, own NVM), HCI                                                                                       | IOM6 SPI                   | [C]; separate die vs. in-package [?]        |
| Display        | microLED 640×480, 4-bit grey (green); JBD JBD4010 or Hongshi A6N-G                                                        | MSPI0 quad SPI, 320 B/line | [C] §2, §5                                  |
| Voice codec    | GX8002 (C-SKY), 2 DMICs, I2S 16 kHz 16-bit 2 ch out                                                                       | I2S                        | [C]                                         |
| Extra mic path | PDM0 on the Apollo                                                                                                        | PDM                        | [C]                                         |
| IMU            | TDK ICM-45608 (accel + gyro)                                                                                              | I2C4 `0x69`                | [C]                                         |
| Magnetometer   | likely ICT1531x                                                                                                           | IMU aux I2C `0x1E`         | [I]                                         |
| Touch + wear   | PSoC 4000T (CY8C4046FNI): touchpad and proximity (wear)                                                                   | I2C5 `0x0C`                | [C]                                         |
| Ambient light  | TI OPT3007 (some sources: OPT3001), right temple only                                                                     | `0x45`                     | [C]                                         |
| Power          | Board A: nPM1300 `0x6B`. Board B: BQ25180 `0x6A` + BQ27427 gauge `0x55`                                                   | I2C7                       | [C]                                         |
| Battery        | 96 mAh per temple                                                                                                         | —                          | [C]                                         |
| Sound out      | **No speaker.** PWM piezo buzzer (GPIO145)                                                                                | PWM                        | [C]                                         |
| Debug UART     | stock log + CLI shell; UART2 = case link                                                                                  | UART1 `0x4003A000`         | [C] g2emu (stock in Renode)                 |
| Case           | STM32G0B1 (dual-bank, ROM bootloader) + CH340 USB-UART, pogo UART 1 Mbaud to each temple                                  | —                          | [C]                                         |
| Ring (R1)      | nRF52840, **signed** Nordic Secure DFU — out of scope                                                                     | BLE                        | [C]                                         |
| Camera         | none                                                                                                                      | —                          | [C]                                         |

Memory detail (hal_ambiq `am_apollo510.h`, g2emu): DTCM is `0x20000000–0x20080000` and SSRAM `0x20080000–0x20380000`. Ambiq's Zephyr DTS maps only the first `0x7C000` of DTCM; stock puts its initial SP at `0x2007FB00`, in the last 16 KiB. Ambiq's Zephyr `flash0` starts at `0x410000` (the SBL is outside it), so devicetree partition offsets are relative to `0x410000`.

## MRAM map (Apollo510, per temple)

| Range               | What                                                                                                                                 | Wisp may write?                                         |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| `0x400000–0x410000` | Ambiq SBL (secure ROM bootloader)                                                                                                    | **never**                                               |
| `0x410000–0x438000` | Even bootloader (stock `ota/s200_bootloader.bin`; image ends `0x434477` on 2.2.6.10, `0x434900` on 2.3.2.14)                         | **never**                                               |
| `0x437FE0`          | nothing is written here: the bootloader skips the 32-byte preamble and programs `payload[0x20:]` at `0x438000` [C, rung 3]           | —                                                       |
| `0x438000–…`        | main application (stock ends `0x794324` on 2.2.6.10, `0x7F5AAC` on 2.3.2.14: only 9.3 KiB below the ceiling) [C, `wisp-ota inspect`] | via stock install only                                  |
| ceiling `0x7F8000`  | hard limit for the app's end (g2flash guard)                                                                                         | —                                                       |
| `0x7FE000` (16 B)   | update-flag record, bootloader-owned; semantics below                                                                                | only the documented flag value, only from verified code |
| `…–0x800000`        | NV / bond area; writing past `0x800000` = SWD-only brick                                                                             | **never**                                               |

## Boot and update chain (stock)

1. SBL (ROM) → Even bootloader `0x410000`.
2. Even bootloader: if the update flag says so, read the 32-byte header of the staged file `ota/s200_firmware_ota.bin` on the NOR littlefs, check its CRC, program MRAM from `0x438000`, check the SP vector, hand off [C, `protocols.md` §6]. CRC failure → "Bootloader ota fail, system reset" [C].
3. Main app at `0x438000`. **It alone** contains the BLE host (Cordio), GATT, and the OTA service [C]. The bootloader has no BLE [C].
4. OTA (phone → app): EVENOTA bundle over sid `0xC0/0xC1`; for the main component the app writes the littlefs staging file, verifies its CRC, writes `0x55555555` to the flag and resets after 3 s [C, `findings-hardware-drivers.md:606`].

**Consequences:** single slot, no rollback, no boot counter [C]. A main app that crashes before BLE is up cannot take an OTA any more → SWD-only recovery [C, g2flash README]. SWD pads are undocumented [?]; SBL UART recovery depends on per-device INFO0 provisioning nobody has read yet [?].

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

## Image formats

- **EVENOTA:** `EVENOTA\0`, count `+0x08`, `+0x0C` = 0, date/time/version strings `+0x10/0x20/0x30` (16 B each, NUL-padded; version `s200_v<x.y.z.w>`), TOC at `0x40` (16-B entries `{id, off, size, crc32c}`, `size` = 128 + payload), trailer `evenota\0` + 8 zero bytes. Components follow contiguously (unaligned) and close exactly at EOF. Each component = 128-B header (`+0/+4/+0x10/+0x20` = 0, size `+8`, CRC32C `+0xC`, magic `EVEN` `+0x14`, `+0x18/+0x1C/+0x2C` = `0xFFFFFFFF`, type `+0x24`, storage type `+0x28`, path `+0x30`, 80 B) + payload [C, `firmware-formats.md`; all 18 official bundles 2.0.1.14–2.3.2.14 checked with `wisp-ota`].
- Entry ids run 1..n in TOC order. Most bundles carry 6 components (codec, EM9305, touch, case, bootloader, main); **2.2.0.24 and 2.2.4.34 carry 5 (no bootloader), so main is entry 5 there** [C, `wisp-ota inspect`]. Every stock component uses storage type 3.
- Official bundles: `https://cdn.evenreal.co/firmware/<md5>.bin` (Even's CDN); pinned SHA-256s in `packages/wisp-ota/src/catalog.ts` [C, webflasher catalog, g2flash `build_cfw.sh`].
- Component types: main 0, bootloader 1, font 2, touch 3, codec 4, EM9305 5, case 6. Storage: 0 MRAM, 1 XIP NOR (read-back verified), 3 littlefs file [C].
- CRC-32C MSB-first (poly `0x1EDC6F41`, init 0, xorout 0) per payload, in TOC and subheader [C].
- Main-app preamble (32 B): word0 = `0x04<<24 | size`, where size is the whole payload **including** the preamble; word1 = zlib CRC32 over `payload[8:]`; `+0x10` type `0xCB`; `+0x14` run base `0x438000`; `+0x08/+0x0C/+0x18/+0x1C` = 0. The bootloader programs `payload[0x20:]` at the run base [C].
- The bootloader takes the run base and the 24-bit size from the preamble **without a bounds check**; an oversized image overruns into the flag / NV area. `wisp-ota` is therefore the only guard [C, g2flash `APP_MAX_END` comment].
- A main-only bundle is accepted [C, g2flash #3].
- Downgrades are not blocked on the glasses [C, faceclaw #56, #6].

## Stock link facts (for planning throughput)

- Stock: 30 ms interval, latency 4 when idle, DLE 247, 1M PHY; about 8 KB/s phone, about 50 KB/s from BlueZ [C, damage-wm].
- With 2M PHY + 7.5 ms interval (g2flash patch): about 41 KiB/s measured; phones may clamp the interval (Android 11.25 ms; iOS 15 ms) [C].
- Per-message round trip floor about 60–70 ms [C].
- Panel transfer of one full frame: 1.2–6.6 ms [C, damage-wm]. Stock tick is 1.024 ticks/ms — drifts 1.4–2 % against the phone [C].

## Power facts

- Worn, stock: about 7.5 %/h (100 → 67 % in 4.4 h) [C, damage-wm].
- Stock uses FreeRTOS tickless idle and an EM9305 sleep manager [C]. Apollo watchdog about 30 s [C].

## Open hardware questions

- SWD pad location and a working attach (needed before any native flash, see [safety.md](safety.md)).
- INFO0/INFOC provisioning (does SBL UART recovery exist on retail units?).
- Which power board our units have (nPM1300 or BQ25180 + BQ27427).
- Which panel variant our units have (JBD4010 or A6N-G); panel init sequences.
- EM9305: firmware patch load at boot needed? Wire format of its DFU.
- Inter-temple UART: baud rate, real throughput.
- Whether SRAM survives a software POR / watchdog reset on the real chip (Wisp does not rely on it; rung 3 fills SRAM with `0xA5` on every reset).
- MSPI1 pin mux and the power/clock state the bootloader leaves behind at hand-off (Wisp Boot re-applies the stock DEV0CFG/PADOUTEN values; unverified on glasses).
