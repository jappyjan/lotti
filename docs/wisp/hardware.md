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
| External flash | MX25U25643G, 32 MiB NOR (littlefs at `0x1400000`, FlashDB at `0x1FC0000`)                                                 | MSPI                       | [C] `memory-map.md`                         |
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
| `0x437FE0`          | 32-byte main-app preamble                                                                                                            | via stock install only                                  |
| `0x438000–…`        | main application (stock ends `0x794324` on 2.2.6.10, `0x7F5AAC` on 2.3.2.14: only 9.3 KiB below the ceiling) [C, `wisp-ota inspect`] | via stock install only                                  |
| ceiling `0x7F8000`  | hard limit for the app's end (g2flash guard)                                                                                         | —                                                       |
| `0x7FE000` (16 B)   | update-flag record, bootloader-owned                                                                                                 | only the documented flag value, only from verified code |
| `…–0x800000`        | NV / bond area; writing past `0x800000` = SWD-only brick                                                                             | **never**                                               |

## Boot and update chain (stock)

1. SBL (ROM) → Even bootloader `0x410000`.
2. Even bootloader: if the update flag says so, read the 32-byte header of the staged file `ota/s200_firmware_ota.bin` on the NOR littlefs, check its CRC, program MRAM from `0x438000`, check the SP vector, hand off [C, `protocols.md` §6]. CRC failure → "Bootloader ota fail, system reset" [C].
3. Main app at `0x438000`. **It alone** contains the BLE host (Cordio), GATT, and the OTA service [C]. The bootloader has no BLE [C].
4. OTA (phone → app): EVENOTA bundle over sid `0xC0/0xC1`; for the main component the app writes the littlefs staging file, verifies its CRC, writes `0x55555555` to the flag and resets after 3 s [C, `findings-hardware-drivers.md:606`].

**Consequences:** single slot, no rollback, no boot counter [C]. A main app that crashes before BLE is up cannot take an OTA any more → SWD-only recovery [C, g2flash README]. SWD pads are undocumented [?]; SBL UART recovery depends on per-device INFO0 provisioning nobody has read yet [?].

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
- Exact semantics of the 16-byte update-flag record beyond the `0x55555555` word.
