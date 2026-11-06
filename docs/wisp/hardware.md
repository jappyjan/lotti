# Wisp — G2 hardware reference

What Wisp builds on. Every fact names its source; **[C]** = confirmed in the cited source, **[I]** = inferred, **[?]** = open.
Main sources: [openCFW](https://github.com/kalanihelekunihi/evenRealities-openCFW) `g2/docs/` (MIT), [webflasher](https://github.com/AM-Guru/evenRealities-webflasher) README (MIT), [g2flash](https://github.com/jimrandomh/g2flash) (GPL-3.0: read for facts, never copy code), [g2emu](https://github.com/ithinkthisiscool/g2emu) (MIT). Researched 2026-11-05.

## Topology

- **Two temples, two computers.** Each temple runs its own copy of the same image and drives its own eye's panel [C]. The right temple (side id 1) is master: it owns the ambient light sensor and the input manager [C].
- The temples talk over a UART through the frame's flex (TinyFrame, CRC-16/ARC, 24 KiB max payload in stock) [C].
- Each temple is its own BLE peripheral (`Even G2_<pair>_<L|R>_<mac>`) [C, Lotti S1].

## Parts (per temple unless noted)

| Function       | Part                                                                                                                      | Bus / address                              | Source                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------------- |
| Main MCU       | Ambiq Apollo510B, Cortex-M55 + MVE (Helium), NemaGFX GPU                                                                  | —                                          | [C] openCFW `g2-glasses.md`                                 |
| Memory         | 4 MiB MRAM, 512 KiB DTCM (`0x20000000–0x20080000`) + 3 MiB SSRAM (`0x20080000–0x20380000`); stock initial SP `0x2007FB00` | —                                          | [C] §8.1, openCFW `reference/memory-map.md`                 |
| External flash | MX25U25643G or (stock ≥ 2.2.9.22) GD25LE256H, 32 MiB NOR (littlefs at `0x1400000`, FlashDB at `0x1FC0000`); ours: [?]     | MSPI1 CE0                                  | [C] `memory-map.md`, rung 3, 2.4.0.24 bootloader            |
| BLE controller | EM9305 (own firmware, own NVM), HCI                                                                                       | IOM6 SPI                                   | [C]; separate die vs. in-package [?]                        |
| Display        | microLED 640×480, 4-bit grey (green); JBD JBD4010 (hw_version 5) or Hongshi A6N-G (hw_version 6)                          | MSPI0 CE0, serial + quad 1-1-4, 320 B/line | [C] 2.4.0.24, [native drivers](#native-drivers-stock-24024) |
| Voice codec    | GX8002 (C-SKY), 2 DMICs, I2S 16 kHz 16-bit 2 ch out                                                                       | I2S                                        | [C]                                                         |
| Extra mic path | PDM0 on the Apollo                                                                                                        | PDM                                        | [C]                                                         |
| IMU            | TDK ICM-45608 (accel + gyro)                                                                                              | I2C4 `0x69`, INT1 GPIO38                   | [C] 2.4.0.24                                                |
| Magnetometer   | TDK ICT1531x (ID `0x45`)                                                                                                  | IMU aux I2C `0x1E`                         | [C] 2.4.0.24 ID check                                       |
| Touch + wear   | PSoC 4000T (CY8C4046FNI): touchpad and proximity (wear)                                                                   | I2C5 `0x0C`, attn GPIO27                   | [C] 2.4.0.24                                                |
| Ambient light  | TI OPT3007 (OPT3001 register set, no INT pin); stock starts it on the right temple only                                   | I2C2 `0x45`                                | [C] 2.4.0.24                                                |
| Power          | nPM1300 `0x6B` (stock 2.4.0.24 always selects it; its BQ25180 `0x6A` + BQ27427 `0x55` path is dead code)                  | I2C7, IRQ GPIO4                            | [C] 2.4.0.24                                                |
| Battery        | 96 mAh per temple                                                                                                         | —                                          | [C]                                                         |
| Sound out      | **No speaker.** PWM piezo buzzer (GPIO145)                                                                                | PWM                                        | [C]                                                         |
| Debug UART     | stock log + CLI shell, GPIO12 TX / GPIO14 RX, 921600 baud; UART0 = L/R link, UART2 = case, UART3 = GX8002                 | UART1 `0x4003A000`                         | [C] 2.4.0.24 UART table                                     |
| Case           | STM32G0B1 (dual-bank, ROM bootloader) + CH340 USB-UART, pogo UART 1 Mbaud to each temple                                  | —                                          | [C]                                                         |
| Ring (R1)      | nRF52840, **signed** Nordic Secure DFU — out of scope                                                                     | BLE                                        | [C]                                                         |
| Camera         | none                                                                                                                      | —                                          | [C]                                                         |

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

## Native drivers (stock 2.4.0.24)

What the native drivers in `apps/wisp-fw` need from the hardware, and what stock 2.4.0.24 does with it. Method: static analysis of the 2.4.0.24 main image in `.wisp-cache/` (objdump, the IAR `.data` initialiser run in an emulator to recover RAM tables; never committed), openCFW's reconstruction of 2.2.6.10 for orientation, public datasheets. Only facts are recorded (addresses, registers, values, order, delays). Addresses are 2.4.0.24 run addresses (file offset + `0x437FE0`). Tags: **[C]** confirmed in 2.4.0.24, **[C-2.2]** openCFW / 2.2.6.10 only, **[D]** datasheet, **[I]** inferred, **[?]** open. Researched 2026-11-06.

### Summary

| Part               | Bus, address                             | IRQ                                 | Power / enable                                 | Confidence                                | Wisp driver                                          |
| ------------------ | ---------------------------------------- | ----------------------------------- | ---------------------------------------------- | ----------------------------------------- | ---------------------------------------------------- |
| microLED panel     | MSPI0 CE0 (GPIO199), serial + quad 1-1-4 | none (MSPI0 IRQ 20)                 | nPM1300 BUCK1, LDSW2 (JBD), GPIO142 / 128 / 68 | [C] sequences and values; [?] which panel | `even,g2-uled` (`src/drivers/uled.c`)                |
| PSoC 4000T touch   | I2C5 (IOM5, GPIO47/48, 400 kHz), `0x0C`  | GPIO27, falling (attention)         | always on; reset GPIO10                        | [C]                                       | `even,g2-touch` (`src/drivers/g2_touch.c`)           |
| ICM-45608 IMU      | I2C4 (IOM4, GPIO34/35, 1 MHz), `0x69`    | GPIO38, rising (INT1)               | rail GPIO129                                   | [C]; currents [?]                         | `invensense,icm45608` (`src/drivers/icm45608.c`)     |
| OPT3007 light      | I2C2 (IOM2, GPIO25/26, 400 kHz), `0x45`  | none (no INT pin)                   | shared rail GPIO134                            | [C]                                       | `ti,opt3007` (`src/drivers/opt3007.c`)               |
| nPM1300 PMIC       | I2C7 (IOM7, GPIO22/23, 400 kHz), `0x6B`  | PMIC GPIO1 (GPOIRQ) → GPIO4, rising | —                                              | [C] (BQ path dead)                        | Zephyr `nordic,npm1300` MFD, regulator, charger, wdt |
| GX8002 codec (mic) | UART3 (TX GPIO73, RX GPIO69) + I2S0 RX   | GPIO29, falling (event)             | GPIO134 → 5 ms → GPIO143 → 20 ms → GPIO146     | [C] pads and sequence                     | not yet (facts only)                                 |

### microLED panel (JBD4010 / Hongshi A6N-G)

**Which panel** [C]: stock keeps two drivers (option records ROM `0x71097C` JBD, type 0; `0x71086C` A6N-G, type 1) and picks one in `uled_mspi_init` (`0x4EE1AE`) from the board's **hw_version** byte: 6 → A6N-G, anything else → JBD4010. hw_version comes from a resistor strap on GPIO16 (ADC slot 3, 3 samples, mV = raw × 1190 >> 12; bins 950–1050 mV → 6, 550–650 → 3, 300–400 → 4, 100–250 → 5). New in 2.4: an out-of-range ADC falls back by the board serial (BSN[6..7] = "SS" → 6, "fallback to DVT3/Hongshi"; else 5, "fallback to DVT2/JBD"). So hw 5 = DVT2/JBD, hw 6 = DVT3/Hongshi; retail units are probably A6N-G [I]. The board DTS defaults to `panel = "a6n-g"`; `tests/drivers/jbd4010.overlay` selects the JBD. One stock log line from a temple (`[BSP]hw_version: %d`) settles it.

**Bus** [C] (`.data` device configs at RAM `0x2000252C/44` JBD, `0x200024FC/14` A6N-G; init `0x5C118A`): MSPI0, SPI mode 0, IRQ 20 priority 4, interrupt mask `0x1A80`. Pads: CE0 GPIO199 (MNCE0_0), D0 GPIO64, D1 GPIO65, SCK GPIO72, plus D2 GPIO66 / D3 GPIO67 for quad. Commands and reads are blocking PIO, serial; pixels are quad 1-1-4 (instruction and address on one line, data on four). Full frames go by DMA, and stock waits for completion.

|               | JBD4010                                                                                       | A6N-G                                                                       |
| ------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| serial        | 31.25 MHz, instr 1 B, addr 3 B (unused), turnaround 1                                         | 24 MHz, no instr, addr 2 B (reads only)                                     |
| quad 1-1-4    | 31.25 MHz, WriteInstr `0x62`, ReadInstr `0x63`, addr 4 B                                      | 32 MHz (Wisp: 31.25, the fork has no 32 MHz setting), no instr, addr 4 B    |
| frame write   | `0x62`, addr `0x00000000`, **153 602 B** (frame + 2), then `0x97`                             | addr `0x32002C00`, 153 602 B, no commit [I: `0x32` quad write + DCS `0x2C`] |
| partial write | per row: `0x62`, addr `((y << 10) & 0x7FC00 \| x) << 8 \| 0xFF`, span + 2 B, then `0x97` once | none (the stock "sync" slot is a stub)                                      |

Pixel format [C]: 640×480, 4 bpp, 320 B per row, **even x = high nibble** (the core's format), 0 = off.

**Power sequencing** [C] (JBD up `0x5BC170`, down `0x5BC208`; A6N-G up `0x5E0B44`, down `0x5E0B90`):

- JBD, hw ≥ 4: LDSW2 on (load-switch mode) → 3 ms → BUCK1 on (npmx code 1, read as 1.1 V [I]; code 8 = 1.8 V on hw 6) → 3 ms → GPIO142 high → 10 ms → bus up → GPIO68 high. Down: GPIO142 low → 3 ms → BUCK1 off → 3 ms → LDSW2 off → 10 ms → GPIO68 low. hw < 4 boards switch GPIO128/GPIO143 instead.
- A6N-G: BUCK1 on (1.8 V) → 7 ms → bus up → 1 ms → GPIO128 high → 110 ms → init → … → 50 ms → GPIO142 high. Down: GPIO142 low → 1 ms → GPIO128 low → 1 ms → BUCK1 off → 10 ms.
- Neither panel has a sleep command: "off" is unpowered. At boot stock powers the panel up, configures it, reads the chip ID, sends a blank frame, waits 5 ms and **powers it down** again. The roles of GPIO142 / 128 / 68 (reset vs enable) are not named anywhere [?].

**JBD4010 configure** [C] (`0x5BB6EA`; 2.2.6.10 waited 50 ms after `0x99`): `0x66`, 1 ms, `0x99`, 70 ms, `0x06`, `0x01 {10}`, blank frame + `0x97`, then window offset `0xC0 {x, y}` + `0x97` + 1 ms at (0,0), (0,20), (24,0), (24,20), (12,10), then twice `0x73`, 100 µs, `0x97`, 1 ms, then `0x36 {lum}`, `0x46 {current}`, `0x31 {04}`, `0xA3`, `0x97`, 1 ms, then the offset: `0xA9`, `0xC0 {x, y}` (x 2..22, y 2..18; stock 12, 10), `0xA3`, `0x97`, 1 ms. Chip ID `0x9F` (4 B, id = r[1] << 8 | r[2]). Health [C]: status `0x05` = `0x90` **is a fault**, status `0x35` = 0 is a fault; recovery = power-down, 1 ms, power-up, configure, frame, brightness. Brightness [C] (`0x5BBDD4`, level map `0x471030`): `0x06`, `0xA9`, `0x36 {lum >> 8, lum >> 16}`, `0x46 {current & 0x3F}`, `0x31 {04}`, `0xA3`, `0x97`; level 2..100: level < 31 → current 0, lum = ((M − 333)(level − 2) + 14) / 28 + 333; else current = (36·level − 1045) / 70, lum = M. M = 7100 × a per-unit factory factor (0.5608…1.0 by factory byte, table at ROM `0x76292C`) − 2100·R/10 (R = mode reduction 0..10) [C]. The payload byte order of `0x36` is exactly as stock sends it [C], its meaning [?]. Meanings of `0x66/0x99/0x06/0x01/0x31/0x71–0x74/0xA9/0xA3` [?].

**A6N-G init** [C] (`0x5DFD82`, stream ROM `0x741F24`, identical in 2.2.6.10): register frames are raw 3-byte serial writes `{0x78 bank 0 | 0x7A bank 1, reg, value}`; reads send a 2-byte address `{0x79 | 0x7B, reg}` and read 1 byte (3 tries, 2 ms apart). Sequence: bank1 `0x55 = 0`; then `BE=84, b1 7E=02, b1 A5=40` (6 µs each), `F1=3F, E2=FF, F7=FC, 78=0A, 7C=12, B7=80, B0=80` (100 µs each); 100 µs; `F0=28`; read-backs (reg `0x00` must read `0x36`); chip ID (bank 0 reg `0x06` = 1); blank frame; brightness; offset. Offset [C]: per axis read EF (x) / F0 (y), write `v + (old & 0xE0)` (v ≤ 16; stock 8, 8), then `D9 = BF`, `D9 = FF`, 100 µs between steps. Brightness (rewritten in 2.4, `0x5E04D8`) [C]: coarse `E7` (read once, ≤ 15), then fine `E2`; level ≥ 40 → E2 interpolated over 36, 50, 67, 91, 116, 152, 255; below that from a decile curve (−5, 1, 10, 13, 28, 41, 53, 69, 80, 94, 100), lowering E7 when very dim; then a per-unit factory factor (Wisp: 100 %). Health [C]: `BE` = `0x84`, reg `0x62` ∈ {`0x77`, `0x57`}, plus a mirror check of `D8` bit 5 (not done by Wisp).

**Current** [D]: no datasheet for either part. JBD's 0.13" QSPI series: about 60 mW typical, VDDI 1.8 V / DVDD 1.2 V ([JBD](https://www.jb-display.com/product_des/3.html)). Off = rails off = leakage only [I]. Needs measuring.

### PSoC 4000T touch and wear

[C] unless marked. I2C5 `0x0C`; a command is one write `[cmd, body…]`, its reply a **separate** read (stock's HAL never uses a repeated start). Attention GPIO27, falling edge (the PSoC pulls it low when a report is ready). Reset GPIO10 (written as a pad, held high by the pin table): low 10 ms, high, **100 ms** settle (2.2.6.10: 50 ms).

| cmd | Meaning                               | Reply           | Wisp                                                                |
| --- | ------------------------------------- | --------------- | ------------------------------------------------------------------- |
| 1   | firmware version                      | 4 B, big-endian | read once at init (log only)                                        |
| 2   | **enter DFU**                         | —               | **never sent**: refused before the bus (safety rule 8)              |
| 3   | last report                           | 16 B            | read on every attention edge                                        |
| 4   | sensor diffs                          | 10 B            | allowed, unused                                                     |
| 5   | save proximity baseline (PSoC EEPROM) | —               | API only, for "in the case"; stock sends it on every case insertion |
| 6   | read saved baseline                   | 2 B LE          | allowed, unused                                                     |
| 7   | write long-press threshold (EEPROM)   | `07 00 17`      | **never sent**                                                      |
| 8   | read long-press threshold             | 2 B LE (ms)     | read once at init                                                   |

Report: byte 0 proximity (1 = not worn, 2 = worn, 0 = no change); byte 1 flags (0x01 press, 0x02 release, 0x04 tap with count in byte 2, 0x08 double, 0x10 long, 0x20 slide back, 0x40 slide forward, **0x80 error → reset the PSoC**); byte 2 tap count or slide distance; byte 3 speed [C-2.2]. There is no position. **Wear** is decided inside the PSoC (CAPSENSE proximity widget; thresholds 160/170/150, baseline overrides, [C-2.2]); the host only forwards byte 0. **At every boot stock resets the PSoC, reads its version, compares it with `/firmware/touch.bin` and reprograms the PSoC on a mismatch or a failed read** (`0x583DE8`). Wisp has no such path at all. PSoC currents: not needed (it runs its own low-power scan) [?].

### ICM-45608 IMU

[C]: I2C4 `0x69`, 1-byte register address, WHO_AM_I `0x72` = `0x81`. INT1 → GPIO38 rising; stock writes INT1_CONFIG2 = `0x01` (push-pull, pulsed, active-high). Rail: GPIO129 (low at reset); stock power-cycles it (off 100 ms, on, 5 ms) before init and powers the IMU off by dropping the rail with no register write first. Stock init (`0x4C3210`): soft reset + ID, both sensors off, flush, ODR codes 6..11 = 800..25 Hz, accel ±4 g (FS code 3) in low-power mode, gyro ±2000 dps (code 1) in low-noise or low-power, then TDK eDMP features (tap, tilt, head-up, compass). Register map, ODR and FS codes are the ICM-45686's, except that FS code 0 (±32 g / ±4000 dps) does not exist on the 45608 [D: TDK `inv_imu_regmap_le.h`, `INV_IMU_HIGH_FSR_SUPPORTED 0`]; the in-tree Zephyr `icm45686` driver hard-checks WHO_AM_I `0xE9`, so Wisp has its own small driver. Data registers are little-endian [D]. Magnetometer: ICT1531x (`0x01` = `0x45`) at `0x1E` behind the IMU's I2C master (not driven yet). Current [D]: no public 45608 datasheet; sibling ICM-45605: 6-axis 0.42 mA low-noise, 0.22 mA low-power ([TDK](https://invensense.tdk.com/products/motion-tracking/6-axis/icm-45605/)); rail off = 0.

### OPT3007 ambient light

[C]: I2C2 `0x45` (not I2C7), IDs `0x7E` = `0x5449`, `0x7F` = `0x3001`; **no INT pin** (DSBGA, [D] SBOS864). Rail GPIO134, shared with the GX8002 (high from boot). Stock waits 5 ms after the rail, writes M = 3 (continuous) and CT = 0 (100 ms), so config ≈ `0xC610` [I], and starts the ALS only on one role (right temple, [C-2.2] + community). Stock "off" just drops the rail. Wisp keeps it in shutdown (M = 0) and runs one single-shot conversion per sample. Current [D]: 1.8 µA active (3.7 µA at full-scale light), 0.3 µA shutdown; conversion 100 ms (CT = 0) or 800 ms.

### nPM1300 PMIC, battery, case

**The G2 runs the nPM1300** [C]: in 2.4.0.24 every HW-ID bin, and now also an invalid ADC reading, writes charger family 1 (board info RAM `0x20076D9C`); nothing writes 2, so the BQ25180 + BQ27427 code is linked but dead. I2C7 `0x6B`, 16-bit register addresses sent high byte first. IRQ: PMIC GPIO1 in GPOIRQ mode → Apollo GPIO4, rising. Stock init (`0x5009F8`, `0x4FF3A0`) [C]:

| Setting                          | Stock value                                                                     | Wisp DTS                        |
| -------------------------------- | ------------------------------------------------------------------------------- | ------------------------------- |
| charge current / discharge limit | 96 mA / 1000 mA                                                                 | same                            |
| termination normal / warm        | 4.45 V / 4.10 V (openCFW's 4.00 V is 2.2.6.10 or a misread)                     | same                            |
| VBUS current limit               | 500 mA                                                                          | same                            |
| NTC                              | 100 kΩ, β 4250, 0 / 10 / 45 / 60 °C                                             | same                            |
| events                           | watchdog warning, VBUS detected / removed, charge error, NTC cold/hot, die temp | MFD driver defaults             |
| BUCK1                            | off at boot; **the panel's rail** (see above)                                   | panel driver switches it        |
| BUCK2                            | 3.1 V, on                                                                       | always-on                       |
| LDSW1                            | LDO, 1.8 V, on                                                                  | always-on                       |
| LDSW2                            | load switch (hw ≥ 4), switched with the JBD panel; off on hw 6                  | panel driver (JBD only)         |
| **timer**                        | **watchdog, reset mode, 30.72 s, kicked every 1 s** by stock's device manager   | kicked once and stopped at boot |

The case is detected by VBUS only (no case GPIO in the pin table); the case UART is UART2 (GPIO42/44, 1 Mbaud). Battery: 96 mAh, 3.87 V per temple (FCC report); stock's percent comes from Nordic's closed `nrf_fuel_gauge` (not used by Wisp; Wisp estimates from voltage). Currents [D] ([nPM1300 PS](https://docs.nordicsemi.com/r/bundle/ps_npm1300/page/product_overview.html-sys-el-spec)): ship 370 nA, hibernate 500 nA, active with bucks off 600 nA, one/both bucks in auto 0.8 / 1.1 µA, a buck in forced PWM 4 mA (keep auto).

**Zephyr I2C byte order** (found while wiring the PMIC, not a G2 fact): the fork's `i2c_ambiq.c` copies a write-read header into the IOM offset field little-endian, but the IOM sends offset bytes highest first, so every 16-bit PMIC register read would go to the wrong register. Wisp carries a fixed copy ([apps/wisp-fw/third_party/zephyr/README.md](../../apps/wisp-fw/third_party/zephyr/README.md)); the Renode driver test fails with the unfixed driver.

### GX8002 microphone path (facts only, no driver yet)

[C]: power GPIO134 → 5 ms → GPIO143 → 20 ms → GPIO146 (off: all low, no delays). Control UART3, TX GPIO73 / RX GPIO69, 115200 at run time, `BUXX` frames (14-byte header, CRC-32): mic gain `0x0B`, I2S output `0x0F`, DMIC open/close `0x0C/0x0D` [C-2.2]. Event line GPIO29, falling. PCM: I2S0 **RX slave** (the codec is clock master), CLK GPIO100, WS GPIO102, DATA GPIO101, IRQ 44; 2 × 32-bit slots, 16-bit samples, data delay 1 [C-2.2]. Never load or update its firmware (safety rule 8). PDM0 (GPIO50/51, IRQ 48) is a second mic path; which mic it carries is open [?]. Current [D]: ≈ 70 µW VAD standby, ≈ 0.6 mW running ([NationalChip](https://www.nationalchip.com/en/index.php/news/info/229)).

### Board pins (stock pin table ROM `0x689158`, 97 rows, identical to 2.2.6.10)

[C]: outputs high at boot 9, 10, 134; outputs low 7, 11, 46, 68, 128, 129, 142, 143, 144, 146, 147; inputs with IRQ 4 (rising, PMIC), 27 (falling, touch), 29 (falling, codec), 38 (rising, IMU); inputs 13, 37, 156; peripherals UART0 0/2 (L/R link, 921600), UART1 12/14 (console, 921600), HW-ID ADC 16, **SWD 20/21**, I2C7 22/23, I2C2 25/26, I2C4 34/35, UART2 42/44, I2C5 47/48, MSPI1 49, 95–98, 103, PDM0 50/51, MSPI0 64–67, 72 (+ CE 199), UART3 69/73, I2S0 100–102, buzzer 145 (TIMER7 output 0, PWM).

### Expected current per state (datasheet figures; nothing measured)

| State            | Panel                         | IMU                                    | ALS                                       | PMIC                  | Notes                                                       |
| ---------------- | ----------------------------- | -------------------------------------- | ----------------------------------------- | --------------------- | ----------------------------------------------------------- |
| not worn, idle   | rails off (≈ 0)               | rail off (0)                           | shutdown 0.3 µA                           | ≈ 1.1 µA (bucks auto) | plus the Apollo510 in sleep [?] and the PSoC's own scan [?] |
| worn, display on | ≈ 60 mW class [D, JBD family] | off unless used                        | 0.3 µA, 1.8 µA during a 100 ms conversion | ≈ 1.1 µA + load       | the panel dominates                                         |
| IMU streaming    | —                             | 0.22 mA LP … 0.42 mA LN [D, ICM-45605] | —                                         | —                     |                                                             |

Stock for comparison: about 7.5 %/h worn, i.e. ≈ 7 mA from 96 mAh (damage-wm, above).

### Uncertain without hardware

- Which panel is fitted (hw_version 5 or 6), what GPIO142 / 128 / 68 do, the exact BUCK1 voltages (npmx codes 1 and 8), the meaning of most JBD opcodes and of the two trailing bytes of every pixel write.
- Whether the panels tolerate Wisp's 31.25 MHz quad clock on the A6N-G (stock: 32 MHz).
- The per-unit factory brightness factors (JBD M, A6N-G calibration byte); Wisp uses the neutral value.
- Whether the nPM1300 watchdog is still armed after an Apollo reset into a new image.
- I2C pull-ups (the stock pad config `0x4200` is not decoded; Wisp enables the internal pull-ups).
- The ICM-45608's per-mode currents; whether the OPT3007 is fitted on the left temple; which mic PDM0 carries.
- Everything timing-related: Renode completes every bus transfer at once.

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
- SWD pad location and a working attach (needed before any native flash, see [safety.md](safety.md)).
- INFO0/INFOC provisioning (does SBL UART recovery exist on retail units?).
- Which panel variant our units have (JBD4010 = hw_version 5, A6N-G = hw_version 6). Answered by one stock log line (`[BSP]hw_version: %d`); the init sequences are in [Native drivers](#native-drivers-stock-24024). The power board is answered: stock 2.4.0.24 only drives the nPM1300.
- Whether the nPM1300 watchdog that stock arms (30.72 s, reset mode) is still running when a new image boots after an Apollo reset. Wisp kicks and stops it at boot either way.
- EM9305: firmware patch load at boot needed? Wire format of its DFU.
- Inter-temple UART: baud rate, real throughput.
- Whether SRAM survives a software POR / watchdog reset on the real chip (Wisp does not rely on it; rung 3 fills SRAM with `0xA5` on every reset).
- MSPI1 pin mux and the power/clock state the bootloader leaves behind at hand-off (Wisp Boot re-applies the stock DEV0CFG/PADOUTEN values; unverified on glasses).
