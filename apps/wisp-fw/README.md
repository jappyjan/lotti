# wisp-fw — Wisp native firmware (Apollo510B)

The native target of [Wisp](../../docs/wisp/README.md): Zephyr from Ambiq's fork (decision W11) on one G2 temple, emulated in Renode with g2emu's Apollo510 platform (W15). **Milestone M0: build skeleton + Renode boot; rung 3: Wisp Boot, fault-tested in Renode against the real Even bootloader; M6 groundwork: drivers for the panel, touch/wear, IMU, light and PMIC, tested in Renode against bus models. Nothing here has run on glasses, and nothing here can talk to hardware** — the board defines no flash runner, and no script uses J-Link, SWD or BLE.

Read [safety.md](../../docs/wisp/safety.md) before changing anything that ends up in the image.

## Use

Everything runs on t3-worker (NixOS) as a normal user. The flake in this directory pins the toolchain; the scripts enter it themselves (`nix develop`), so plain `pnpm nx` is enough.

| Target                             | What it does                                                                                                                   |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `pnpm nx run wisp-fw:setup`        | west workspace in `.wisp-cache/west/` from [west.yml](west.yml) (every repo pinned by SHA; about 30 s first time, no-op after) |
| `pnpm nx run wisp-fw:build`        | `west build -b wisp_g2` into `.wisp-cache/build/wisp-fw/`, then the post-build gates; fails if any gate fails                  |
| `pnpm nx run wisp-fw:sim`          | boots `zephyr.bin` in Renode for 10 s of virtual time and streams UART1 (`scripts/sim.sh [seconds]`)                           |
| `pnpm nx run wisp-fw:test`         | Wisp Boot + flush host tests, gate unit tests, Renode boot test (asserts on UART1), rule 8 negative builds (about 4 min)       |
| `pnpm nx run wisp-fw:drivers-test` | the drivers in Renode against panel and I2C models, both panels + one negative case ([below](#drivers); about 5 min)           |
| `pnpm nx run wisp-fw:build-boot`   | Wisp Boot (bare metal, `src/boot/`) into `.wisp-cache/build/wisp-boot/`, then the image and rule 8 gates on it                 |
| `pnpm nx run wisp-fw:boot-test`    | **rung 3**: the real Even bootloader + Wisp Boot + fault apps in Renode, every fault case and power cut (see below; ~45 min)   |

Toolchain (from `flake.lock`, nixos-26.05 at `7dcdd87`): gcc-arm-embedded 15.2.rel1 (Zephyr variant `gnuarmemb`), CMake 4.1, Ninja, dtc, west 1.5, Renode 1.16.1. Workspace: `AmbiqMicro/ambiqzephyr` `ambiq-stable` @ `89c8a36` (Zephyr 4.3.0) plus only `ambiqhal_ambiq` @ `d3278ec`, `cmsis`, `cmsis_6`, `mbedtls` (only for the BT negative build) and `littlefs` @ `8f5ca34` (Zephyr's fork of littlefs 2.11, BSD-3-Clause, on-disk format 2.1 like stock; Wisp Boot and the rung-3 tools build it directly, not through Zephyr's FS layer). To move the pin, edit `west.yml`, rerun setup, build, test. A from-scratch setup in an empty cache (`WISP_CACHE_DIR=…`) rebuilt a byte-identical `zephyr.bin` (the git revision string is embedded, so compare at the same commit).

CI: the GitHub workflow (macOS, no nix) runs `nx run-many -t build test` and would fail on this project; it needs `--exclude=wisp-fw` there (not changed in this PR: the push token has no `workflow` scope). This project is green on t3-worker.

## Layout

```
boards/even/wisp_g2/   out-of-tree board: Apollo510B, code partition at 0x438000, UART1 console
src/main.c             banner, native HAL bring-up, heartbeat; the driver self-test (test builds)
src/hal/               the HAL boundary for Wisp core: display, input, sensors, audio, power,
                       storage, link — declarations, no Zephyr dependency
src/hal/native/        the native HAL on the drivers: display (flush path), input, sensors, power
src/display/           wisp_flush: core strips -> panel frame -> dirty rows (portable, host-tested)
src/drivers/           uled (panel), g2_touch (PSoC), icm45608, opt3007 — Wisp's own, MIT
dts/bindings/          their devicetree bindings (+ vendor prefixes)
third_party/zephyr/    i2c_ambiq.c from the fork with a header byte-order fix (Apache-2.0)
src/boot/              Wisp Boot: wisp_boot.* (pure decision, record, image check; host-tested),
                       stage/ (the bare-metal stage at 0x438000: NOR, littlefs, flag, watchdog),
                       CMakeLists.txt (standalone, arm-none-eabi-gcc), wisp_boot_layout.h
cmake/rule8.cmake      configure-time rule 8 gate
scripts/               setup/build/sim/test, check_image.py, check_rule8.py, wisp_layout.py
renode/                wisp_g2.repl (derived from g2emu, with the panel and I2C models) +
                       wisp_g2.resc; rung 3: wisp_g2_boot.repl, boot.resc; models/ (Wisp's C#
                       models: NOR+MSPI, panel+MSPI, IOM+I2C devices, reset, WDT, boot ROM, ...)
third_party/g2emu/     three g2emu C# peripheral models (MIT, unmodified), see its README
tests/                 boot/ (C host tests; rung3.py harness, app/ fault apps, tools/wisp_lfs.c),
                       display/ (flush host test), drivers/ (Renode driver checks, JBD overlay),
                       scripts/ (gate unit tests), sim/ (UART assertions),
                       rule8/ (negative builds: BT on, BT "allowed" on the unpatched fork, canary)
```

Wisp core hook: `-DWISP_WITH_CORE=ON` (optionally `-DWISP_CORE_DIR=…`, default `packages/wisp-core`) adds the core's CMake project and links `wisp_core` into the app with Zephyr's flags; checked against `t3/wisp-core` @ `b40f049`, which cross-compiles cleanly for the M55 (its `-Wpedantic -Werror` needed Zephyr's headers passed as system includes — done in `CMakeLists.txt`).

## What boots

`wisp_g2` image: 112.6 KB, linked at `0x438000` (vector table first; initial SP `0x2008a030` in SSRAM, reset vector `0x0043cd2d`). Renode loads the flat `zephyr.bin` at `0x438000` — exactly what the Even bootloader would install — and starts it the way the bootloader hands off (VTOR = `0x438000`, MSP = vector 0, PC = vector 1). The platform has Wisp's I2C and panel models, so the drivers probe their devices; everything stays suspended. UART1 from a `wisp-fw:sim` run:

```
[00:00:00.114,105] <inf> g2_touch: PSoC firmware 01000202
[00:00:00.114,196] <inf> g2_touch: long press 1000 ms
*** Booting Zephyr OS build 4.3.0 ***

*** Wisp native 0.0.0-m0 (3938e0d52a-dirty) ***
wisp: board wisp_g2, Zephyr 4.3.0, image @ 0x438000
wisp: bluetooth off (safety rule 8)
wisp: hal power ok (0)
wisp: hal display ok (0)
wisp: hal input ok (0)
wisp: hal sensors ok (0)
wisp: sensors present 0x1b
wisp: heartbeat 1 uptime 1122 ms
wisp: heartbeat 2 uptime 2124 ms
wisp: heartbeat 3 uptime 3125 ms
```

The kernel ticks off the STIMER (Renode's Apollo4 system-timer model is register-compatible enough for `ambiq_stimer.c`); heartbeats drift about 1–2 ms per second of virtual time. No Renode warnings at log level 3.

## Board `wisp_g2`

- **MRAM partitions** (flash0 starts at `0x410000`, so offsets are relative to it): `even-bootloader` `0x410000–0x438000` read-only (the 32-byte EVEN preamble at `0x437FE0` sits at its end and is added by wisp-ota, never the linker), `wisp` `0x438000–0x7F8000` = `zephyr,code-partition` (3840 KiB; the linker region ends exactly at the ceiling), `even-nv` `0x7F8000–0x800000` read-only (update flag at `0x7FE000`, bonds).
- **Devices** (every bus, address, pad and sequence from stock 2.4.0.24, with confidence and source in [hardware.md "Native drivers"](../../docs/wisp/hardware.md#native-drivers-stock-24024)): UART1 console on GPIO12/14 at 921600 (as stock); I2C2 OPT3007 `0x45`; I2C4 ICM-45608 `0x69` (INT1 GPIO38, rail GPIO129); I2C5 PSoC touch `0x0C` (attention GPIO27, reset GPIO10); I2C7 nPM1300 `0x6B` (IRQ GPIO4) with BUCK1 (panel rail), BUCK2 3.1 V and LDSW1 1.8 V always-on, LDSW2, charger at stock's values, the PMIC watchdog; MSPI0 the microLED panel on CE0 GPIO199 (`panel = "a6n-g"` by default; `tests/drivers/jbd4010.overlay` for the JBD). Every device starts suspended (`zephyr,pm-device-runtime-auto`).
- **Disabled:** IOM6 SPI (EM9305 — see rule 8), MSPI1 (NOR, Wisp Boot's for now), PDM0, I2S0 (GX8002), GPU; buzzer, inter-temple and case UARTs as comments.
- **Uncached SRAM** `0x20200000–0x20370000` (panel frame, MSPI command queue); it stops below Wisp Boot's RAM (`0x20370000–0x20380000`).
- **Unverified on the G2:** STIMER clock source; which panel is fitted; I2C pull-ups (internal ones are on).
- `SOC_APOLLO510B_EM9305_EXTREF_INIT` defaults to n on this board (see below).

## Drivers

All of them Wisp's own (MIT) except the nPM1300 drivers (Zephyr in-tree) and the I2C controller driver (the fork's, patched). Facts and their confidence: [hardware.md "Native drivers"](../../docs/wisp/hardware.md#native-drivers-stock-24024).

| Driver                           | Compatible            | What it does                                                                                                                                                                                                               | Power                                                                                                                    |
| -------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `src/drivers/uled.c`             | `even,g2-uled`        | both panels: stock's power sequences, init streams, brightness maps, health checks; full frames by DMA (quad 1-1-4), JBD row updates by PIO; owns the 153 602-byte frame in uncached SRAM                                  | PM runtime: resume = rails + init + blank frame, suspend = stock's power-down, rails off (no panel sleep command exists) |
| `src/drivers/g2_touch.c`         | `even,g2-touch`       | reset, version, long-press threshold, then one 16-byte report per attention edge; gestures, press/release, wear; resets the PSoC on its error flag. **Command allow-list: 2 (DFU) and 7 (EEPROM write) can never be sent** | suspend = attention interrupt off                                                                                        |
| `src/drivers/icm45608.c`         | `invensense,icm45608` | WHO_AM_I `0x81`, soft reset, ±4 g / ±2000 dps, ODR 25–800 Hz, accel LP up to 400 Hz, data-ready trigger on INT1                                                                                                            | suspend = sensors off + rail off (0 current); resume = rail cycle, reset, restore                                        |
| `src/drivers/opt3007.c`          | `ti,opt3007`          | one single-shot conversion per fetch (sleeps through the 100 ms integration), lux from the result register                                                                                                                 | shutdown except during a fetch                                                                                           |
| Zephyr `nordic,npm1300*`         | —                     | MFD, regulators, charger (battery voltage, status, VBUS = case), watchdog                                                                                                                                                  | the native HAL kicks and stops the PMIC watchdog at boot                                                                 |
| `third_party/zephyr/i2c_ambiq.c` | `ambiq,i2c`           | the fork's driver with multi-byte register headers sent in buffer order ([why](third_party/zephyr/README.md))                                                                                                              | as upstream                                                                                                              |

The native HAL (`src/hal/native/`) puts the core on top: `wisp_native_present` / `wisp_native_frame_done` are the engine's `present` / `frame_done`. Strips land in the panel's frame buffer (`src/display/wisp_flush.c`), and at frame end only the dirty rows go out (runs closer than 4 rows merged, more than 240 rows or an A6N-G as one full-frame DMA). Sensors are batched per stream; nothing runs while nothing is configured (no polling loop: the IMU is interrupt-driven, the light sensor is sampled at the requested rate up to 5 Hz, wear is event-driven). The PSoC gives no touch position, so raw touch events carry `pos` 0 and gestures come from the controller (`wisp_hal_input_gestures`).

### Driver test in Renode (`wisp-fw:drivers-test`)

`scripts/drivers_test.sh` builds the image with wisp-core linked and `tests/drivers/selftest.conf` (the self-test in `main.c`), runs it on `renode/wisp_g2.repl` (the same platform as `wisp-fw:sim`), and checks the run with `tests/drivers/check_drivers.py`. The self-test powers the panel, composes two frames with wisp-core's compositor (16 grey bands with a box; then only the box changes), sets brightness, runs the health check, powers the panel off, reads the IMU and the light sensor once, services one touch report, reads the battery.

Models (MIT, written for this; register maps from hal_ambiq's `apollo510.h`):

- `WispMspiPanel` — MSPI0 (PIO, DMA, command queue, as hal_ambiq drives them) + a recording panel: logs every transaction with its bus mode (`DEVCFG0/XIPMIXED`: `1/0` serial, `1/5` quad 1-1-4), answers like a healthy JBD4010 or A6N-G, and keeps the frame the pixel writes produce.
- `WispIom` — IOM0..7 as I2C masters (offset bytes highest first, as the datasheet says) with the G2's devices: nPM1300 register file, ICM-45608 (ID, soft reset, a sample), OPT3007 (IDs, single-shot), PSoC (the command protocol, counts forbidden commands).

What the checker asserts, per panel:

- **Panel:** the exact transaction sequence (opcode or register frame, bus mode, address, length, payload) of power-up, init, blank frame, the full frame, the partial update (JBD: 32 row writes for the 32 changed rows), brightness (values recomputed in Python from stock's formulas), health check; and the frame memory byte for byte against the image computed in Python.
- **I2C:** the PSoC never received a command outside {1, 3, 4, 5, 6, 8}; the IMU got its ID read, soft reset, INT1 config, ±4 g / 100 Hz, and ends with PWR_MGMT0 = 0; the light sensor starts in shutdown, converts single-shot, never continuous; every PMIC register address has a valid base byte (byte order), BUCK2 3.1 V, LDSW1 1.8 V LDO, the watchdog kick and stop (never a start), BUCK1 on/off around the panel at the variant's voltage, and (JBD) LDSW2 before BUCK1 on and after it off.
- **UART:** every HAL part came up, every self-test step returned 0, no error or fault.
- **Negative case:** the same image with the fork's unpatched `i2c_ambiq.c` must fail the PMIC byte-order check.

Result on t3-worker, 2026-11-06: both panels pass (A6N-G 33 panel / 123 I2C transactions, JBD4010 76 / 127), the negative case is rejected (`3404` instead of `0434`). What the models cannot show: timing (every transfer completes at once), GPIO interrupts (the touch report is serviced by a direct call), real panel behaviour beyond the recorded bytes, analog values (battery reads 0 mV).

## Checks in place

All run in every build (`wisp_checks` target, after the link) and fail it:

**Image (rules 1 and 3), `scripts/check_image.py`:** load address = `0x438000`; image end ≤ `0x7F8000`; no loadable segment in MRAM outside `[0x438000, 0x7F8000)` and none outside MRAM; vector[0] (SP) in `(0x20000000, 0x20380000]` and 8-byte aligned; vector[1] (reset) Thumb and inside the image. Output: `check_image: OK load 0x00438000 end 0x004451e4 (3878428 bytes free) SP 0x20081740 reset 0x0043a375`. The constants live in `scripts/wisp_layout.py`; wisp-ota keeps its own copy on purpose (rule 3 wants independent implementations).

**EM9305 (rule 8), `cmake/rule8.cmake` + `scripts/check_rule8.py`:**

1. _configure:_ fails on `CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT`, `CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM` (writes EM9305 NVM), and on `CONFIG_BT` / `CONFIG_AMBIQ_COMPONENT_USE_BT` unless `CONFIG_WISP_BT_ALLOWED=y` (M6) and `CONFIG_WISP_EM9305_SKIP_FW_UPDATE=y`.
2. _sources_ (`compile_commands.json`): with BT off, no EM9305 driver source is compiled. With BT on, every compiled caller of `am_devices_em9305_init()` must assign `skip_fw_update = true` and nothing else.
3. _symbols_ (`nm --defined-only`, locals included): no `ble_fw_image_bin_*`, `image_records`, `erase_pages`, `am_devices_em9305_update_fw`, `em9305_nvm_recovery_reflash`, `fw_write_*`, `fw_erase_*`, `fw_update_*`, `fw_enter_cm_mode`, `am_devices_em9305_crystal_trim_set`; with BT off, no `am_devices_em9305_*` at all.
4. _map + bytes:_ with BT off, no `am_devices_em9305.c.obj` in the linked part of `zephyr.map`; and none of the EM9305 firmware arrays (64-byte windows parsed from the HAL's own `ble_fw_image_em9305.h`, start and middle) occurs in `zephyr.bin` — this still works with symbols stripped or functions inlined.

How it was verified (all part of `wisp-fw:test`):

| Build                                                                    | `nm` EM9305 hits                                            | EM9305 objects in map | `zephyr.bin` | Result                                                                                                            |
| ------------------------------------------------------------------------ | ----------------------------------------------------------- | --------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------- |
| M0 image                                                                 | 1 (`CONFIG_WISP_EM9305_SKIP_FW_UPDATE`, a Kconfig absolute) | 0                     | 53 732 B     | passes                                                                                                            |
| `tests/rule8/bt.conf` (BT on)                                            | —                                                           | —                     | —            | configure fails: `WISP SAFETY RULE 8 … Bluetooth / the EM9305 driver is enabled but stays disabled…`              |
| `tests/rule8/bt_allowed.conf` (BT on, Wisp switches set, unpatched fork) | 38                                                          | 87                    | 377 328 B    | post-build fails on all three: `apollox_blue.c` never sets `skip_fw_update`; update/recovery symbols; image bytes |
| `-DWISP_RULE8_CANARY=ON` (EM9305 image linked via `SYS_INIT`)            | 5                                                           | 0                     | 289 036 B    | post-build fails: `ble_fw_image_bin_*`, `image_records`, image bytes                                              |
| canary ELF stripped                                                      | 0                                                           | 0                     | 289 036 B    | byte check alone rejects it                                                                                       |

In the BT build, `nm -S` shows the bundled controller image as `ble_fw_image_bin_00302400` (`0x39300` = 234 240 bytes) next to `am_devices_em9305_update_fw` and `em9305_nvm_recovery_reflash` — the path that would erase Even's EM9305 firmware. Two of the denylisted functions (`fw_write_image`, `fw_erase_nvm_main`) were inlined there and left no symbol, which is why the byte check exists.

### What the fork does with the EM9305 (why the gate is this strict)

- `am_devices_em9305_init()` reflashes when the device version is **≤** the bundled `0x04050100` (equal → CRC verify, reflash on mismatch), when the version can't be read, and when the controller won't boot. Only `skip_fw_update` stops it — a runtime flag, so the image and erase code stay linked either way.
- `drivers/bluetooth/hci/apollox_blue.c` (`bt_apollo_controller_init`) builds its callback struct without `skip_fw_update` → `false` whenever BT is on.
- The evb's `board.c` EXTREF init (SoC default y whenever an `ambiq,bt-hci-spi` node is enabled) passes `skip_fw_update = IS_ENABLED(CONFIG_BT)` → `false` with BT off — a board that merely describes the radio in DT and leaves BT off would reflash it at boot. `wisp_g2` has no `board.c`, keeps the node disabled and pins the default to n.
- Even's EM9305 version is unknown. If it is ≤ `0x04050100`, any stock-fork BT build reflashes it on first boot.

## Wisp Boot

The first stage of the native image (safety.md "Fallback-to-stock"): `[0x438000, 0x448000)` is Wisp Boot, the Wisp app's vector table follows at `0x448000`. Bare metal, no Zephyr, no BLE, no interrupts; 16 760 bytes (`wisp_boot.bin`), most of it littlefs. Built by `scripts/build_boot.sh` (CMake in `src/boot/`), and the build fails unless `check_image.py` (rules 1, 3) and `check_rule8.py` (sources, symbols, map, EM9305 image bytes; Wisp Boot has no Kconfig, so an empty config stands in) pass on it:

```
check_image: OK load 0x00438000 end 0x0043c178 (3915400 bytes free) SP 0x20380000 reset 0x0043847d
check_rule8: OK bt=off, 129 symbols, no forbidden symbols, map clean, 6 EM9305 image signatures absent
```

Every boot (`stage/boot_main.c`):

1. Arm the watchdog (LFRC/64 = 16 Hz, reset after 128 ticks = 8 s, `RSTGEN.CFG.WDREN`) and lock it. The app must feed it.
2. MSPI1 PIO driver for the MX25U25643G (`stage/boot_nor.c`: READ4B/PP4B/SE4B, so 3- or 4-byte mode does not matter) and littlefs with the stock geometry. **It never formats**: no filesystem → run the app degraded.
3. Read the boot record `wisp/boot.rec`, the 8-byte preamble head of the staging file, and check `wisp/rescue.bin` (rule-3 header check + full zlib CRC, `wisp_boot_image_check()`).
4. Decide (`wisp_boot_decide()`, pure, host-tested), write the record back, then
   - `run-app` / `run-app-degraded`: check that the app's vector table is runnable (SP in SRAM below Wisp Boot's RAM, Thumb reset handler inside the slot; an erased slot is not — it would fault into its own garbage vectors and lock the core up), else reset at once (the attempt is already counted); quiet the NVIC, VTOR = `0x448000`, jump;
   - `rescue`: copy `rescue.bin` → `ota/s200_firmware_ota.bin` (littlefs makes the new file visible only at close), re-read and CRC the staged copy, write the flag record `{0x55555555, ~0, ~0, ~0}` through the boot ROM and read it back, software POR. Any failure → reset **without** writing the flag.

The app confirms a good boot through a fixed services table at `0x438200` (`stage/boot_services.h`: `confirm()` rewrites the record with Wisp Boot's own code and RAM, the top 64 KiB of SSRAM, which the app must leave alone).

**Boot record on the NOR, not in retained SRAM.** It has to survive power loss and every kind of reset. Retained SRAM does neither reliably: a power loss clears it, and the SBL and the Even bootloader run before Wisp Boot on every boot and use SRAM themselves. Whether SRAM survives a software POR or a watchdog reset on the Apollo510 is not documented, and rung 3 fills it with `0xA5` on every reset so nothing can depend on it. MRAM would survive, but then Wisp Boot would carry a second MRAM write path next to the flag (rule 1 wants exactly one). littlefs commits a small file atomically (copy-on-write metadata), Wisp Boot needs littlefs for the rescue copy anyway, and one record write per boot is far inside the NOR's endurance (littlefs wear-levels, `block_cycles` 500).

**Decision rules** (`src/boot/wisp_boot.h`): 3 unconfirmed boots → rescue. A pending rescue (power cut mid-rescue, or the bootloader did not install) is resumed on the next boot; after 4 rescue tries the app runs degraded instead of resetting forever. The record carries the CRC word of the staging preamble it belongs to: an install always goes through the staging file, so a different word means a new install and a fresh record (a reinstalled Wisp starts with a clean count). No valid `rescue.bin` → never touch the staging file or the flag; run the app with a fresh 3-boot window. Touchpad rescue hold: input exists, reading the PSoC (I2C5 `0x0C`) is a TODO.

## Rung 3: fallback-to-stock with the real Even bootloader (`wisp-fw:boot-test`)

**What runs.** The unmodified stock bootloader (2.4.0.24 by default, the version on Jan's temples; `WISP_STOCK_VERSION` picks another cached bundle) (`ota/s200_bootloader.bin` from the pinned bundle in `.wisp-cache/`, SHA-256 checked, never committed) at `0x410000`, started the way the SBL hands off. In front of nothing but Renode peripheral models: no code patches, no hooks in Even's code. The NOR is a 32 MiB file with a littlefs image built on the host (`tests/boot/tools/wisp_lfs.c`, the same littlefs source as Wisp Boot) holding `ota/s200_firmware_ota.bin` (the Wisp image as `wisp-ota pack-main` packs it, so wisp-ota's guards run on every test image) and `wisp/rescue.bin` (the stock main payload). Start state = "Wisp was installed through the stock OTA path": Wisp in MRAM, flag `0x55555555` still set (the bootloader never clears it, see hardware.md), so the bootloader reinstalls Wisp on every boot until the rescue replaces the staging file.

**Models** (`renode/models/`, MIT, written for this rung; register maps from hal_ambiq's CMSIS `apollo510.h`, protocols from AmbiqSuite's HAL):

| Model          | What it does                                                                                                                                                                                                                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `WispMspiNor`  | MSPI1 (PIO, DMA, command queue) + MX25U25643G behind it (RDID, status/config, WREN, 4-byte mode, reads, page program with NOR AND-semantics, sector/block/chip erase), backed by a file; non-volatile across resets. Program/erase complete instantly, so a power cut lands between two NOR operations |
| `WispBootRom`  | the boot-ROM MRAM helper `nv_program_main2` (key, bounds) and the other ROM entries; logs every MRAM write with the caller's LR                                                                                                                                                                        |
| `WispRstGen`   | SWPOI/SWPOR, AIRCR, watchdog and harness power cuts → machine reset: MRAM and NOR kept, all registers and **all SRAM lost (filled with `0xA5`)**, restart through the SBL hand-off at `0x410000`                                                                                                       |
| `WispWdt`      | Apollo510 WDT (CFG/RSTRT/LOCK, LFRC dividers, RESEN + `RSTGEN.CFG.WDREN`) on virtual time                                                                                                                                                                                                              |
| `WispAdc`      | the bootloader's board-detect conversions                                                                                                                                                                                                                                                              |
| `WispUartIdle` | UART0/2/3 with nothing attached (Renode's PL011 kept IRQ 17 asserted under the stock HAL)                                                                                                                                                                                                              |
| `WispProbe`    | harness only: milestones on Wisp Boot addresses, power cuts at a NOR operation count or a milestone, MRAM dump                                                                                                                                                                                         |
| `WispTrace`    | plain register storage for every other range, with access logging to find what a stalled guest polls                                                                                                                                                                                                   |

Plus g2emu's MIT models (`third_party/g2emu/`): CLKGEN/RTC, PWRCTRL, UART1 and, new for rung 3, the IOM/I2C model: the stock app dereferences a NULL ops pointer in its nPM1300 PMIC driver when the first I2C transfer gets no answer.

**What it proves** (each case asserts its end state; `tests/boot/rung3.py`):

- **STOCK**: MRAM `[0x438000, end)` equals the stock image, the bootloader's last hand-off went to it, the stock app's own UART line (`EM9305 reset status`) came after that hand-off with no Wisp Boot output since, the staging file is the rescue image; and in every case the bootloader region is unchanged and **Wisp code's only MRAM write was the flag record** (from the boot-ROM log, by caller address).
- **SAFE** (rescue impossible): Wisp Boot never wrote the flag, MRAM and the staging file still hold Wisp, and the Wisp app gets control every boot.
- **WISP** (control): a confirming app is never rescued, also across power cycles.

Power cuts are positioned from a reference run (milestones on Wisp Boot functions and the NOR operation count): rescue decided but not started, five points inside the 3.5 MB staging copy (14 654 NOR program/erase operations), copy committed, verified-but-no-flag, right after the flag write, and inside / right after the bootloader's own stock install.

Result on t3-worker, 2026-11-06, Wisp Boot `wisp_boot.bin` SHA-256 `8dd8fd69ef4b…`: **all 26 runs end in their expected state, on both the stock 2.2.6.10 and the stock 2.4.0.24 bootloader** (`.wisp-cache/rung3/<version>/report.md`; 47 min wall for 2.4.0.24). The table is the 2.2.6.10 run. On 2.4.0.24 every case has the same verdict and end state, and only the NOR operation counts of the copy cut points differ (2.4.0.24: 326 / 3866 / 7713 / 11560 / 15100), because its main image is larger. The 2.4.0.24 bootloader logs `Nor flash chip: MX25U25643G` (the model's RDID); its GD25LE256H path is not exercised:

| Case                            | Fault                                                       | Expected | Result | End state                                                 | Run                                                   |
| ------------------------------- | ----------------------------------------------------------- | -------- | ------ | --------------------------------------------------------- | ----------------------------------------------------- |
| `reference`                     | reference: app hangs (positions the cut points)             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `good-confirms`                 | control: app confirms, then 3 power cycles                  | WISP     | pass   | Wisp app running, confirmed                               | 3 resets, 4 Wisp Boot runs, 0 WDT bites, 8 s virtual  |
| `app-hangs`                     | app hangs (no confirm, no feed)                             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `app-hangs-flag-clear`          | app hangs, flag already cleared before                      | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `crash-reset-handler`           | app faults in its reset handler                             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `crash-after-300ms`             | app crashes 300 ms after start                              | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `wdt-never-fed`                 | app runs but never feeds the watchdog                       | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `app-slot-erased`               | no app behind Wisp Boot (slot erased)                       | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 0 WDT bites, 10 s virtual |
| `record-corrupt`                | boot record corrupt + app hangs                             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `rescue-corrupt`                | rescue.bin corrupt (one byte) + app hangs                   | SAFE     | pass   | no flag; Wisp app keeps booting (degraded every 3rd boot) | 7 resets, 8 Wisp Boot runs, 7 WDT bites, 66 s virtual |
| `rescue-missing`                | rescue.bin missing + app hangs                              | SAFE     | pass   | no flag; Wisp app keeps booting (degraded every 3rd boot) | 7 resets, 8 Wisp Boot runs, 7 WDT bites, 60 s virtual |
| `cut-rescue-start`              | power cut: rescue decided, record written, copy not started | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-copy-2pct`                 | power cut mid staging copy (2 %, NOR op 312)                | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-copy-25pct`                | power cut mid staging copy (25 %, NOR op 3682)              | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-copy-50pct`                | power cut mid staging copy (50 %, NOR op 7346)              | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `cut-copy-75pct`                | power cut mid staging copy (75 %, NOR op 11009)             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `cut-copy-98pct`                | power cut mid staging copy (98 %, NOR op 14379)             | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `cut-copy-committed`            | power cut: staging copy committed, before verify            | STOCK    | pass   | stock running; flag left set by the install               | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 32 s virtual |
| `cut-copy-committed-flag-clear` | same, flag cleared before (Wisp Boot must resume)           | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `cut-before-flag`               | power cut: copy verified, flag not written                  | STOCK    | pass   | stock running; flag left set by the install               | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-before-flag-flag-clear`    | same, flag cleared before (Wisp Boot must resume)           | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 5 Wisp Boot runs, 3 WDT bites, 36 s virtual |
| `cut-after-flag`                | power cut right after the flag write                        | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 4 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-install-10pct`             | power cut during the bootloader's stock install (10 %)      | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-install-50pct`             | power cut during the bootloader's stock install (50 %)      | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-install-99pct`             | power cut during the bootloader's stock install (99 %)      | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |
| `cut-install-done`              | power cut right after the last install write                | STOCK    | pass   | stock running; Wisp Boot set the flag                     | 5 resets, 4 Wisp Boot runs, 3 WDT bites, 34 s virtual |

Resets count every reset (watchdog, SWPOR, cut); a power cut is processed when Renode finishes the current instruction block, so it lands at the named point or a few instructions after it. "flag left set by the install": the cut came after the staged copy was committed but before Wisp Boot's flag write, and the flag was still `0x55555555` from the original install, so the bootloader installed the staged rescue on its own (after its own CRC check); with the flag cleared beforehand, the same cut makes Wisp Boot resume and set it (`…-flag-clear`).

**Terminal states that are not a stock install** (honest list):

- `rescue.bin` corrupt or missing: Wisp Boot refuses to stage it and never writes the flag (staging a bad image would make the bootloader clear the flag and jump back anyway, see hardware.md). The temple keeps booting the Wisp app (every third boot "degraded" with a fresh window). If that app cannot bring up BLE, the temple is **SWD-only** — rung 3 cannot fix that. It is the reason for the precondition in safety.md: `rescue.bin` is verified on the glasses before any native flash.
- After 4 rescue attempts that did not end in a stock install (e.g. the bootloader keeps rejecting the staged copy), the app runs degraded instead of resetting forever.
- Wisp Boot itself crashing before it writes the record would loop forever (bootloader → Wisp Boot → fault → reset). Nothing in the rung-3 cases does; it is why Wisp Boot stays tiny and has this test suite.

**Run time.** About 1–2 min wall per case (the 3.5 MB copy through the PIO FIFO model and the bootloader's install dominate); `boot-test` runs the reference plus all cases. `--list`, `--only NAME…` narrow it; every run keeps `uart1.txt`, `monitor.log`, `renode.log`, NOR before/after and an MRAM dump in `.wisp-cache/rung3/runs/<case>/`.

## What Renode lacks (for this and the next rungs)

- **Peripherals are plain storage** outside the models above: GPIO, MCUCTRL, NemaGFX, PDM/I2S, CRC/crypto, security/OTP. Writes are stored, reads return what was written or 0.
- **Core lockup is not modelled**: a fault inside a fault handler stops a Cortex-M on silicon (the watchdog then fires); Renode instead re-enters the handler forever and virtual time crawls. The fault apps therefore have a spinning fault handler, and an unrunnable app slot is caught by Wisp Boot's vector check before the jump.
- **Timing is not modelled**: NOR program/erase and MRAM writes complete instantly, so power cuts land between operations, never inside a page program or an erase (littlefs is designed for that case; not exercised here).
- **No SBL**: nothing at `0x400000`; the reset model performs its hand-off (VTOR = `0x410000`, MSP/PC from the bootloader's vector table). INFO0-driven SBL behaviour (recovery, secure boot) is not modelled.
- **The stock app** gets far enough to print its own early lines (EM9305 bring-up) and then spends its time in busy-waits; its BLE, display and sensors are not usable (no EM9305, no panel, IOM devices are g2emu stubs). Enough to prove "stock is installed and running", not more.
- **No power management:** `CONFIG_PM` is off; deep sleep and power domains beyond the PWRCTRL status mirror are not modelled.
- **No EM9305**, so no BLE in emulation (fine until M6).
- **UART1:** g2emu's model completes TX instantly; the polled console works, an interrupt-driven console is untested.

## What the fork provides for Apollo510B (89c8a36)

| Area            | In the fork                                                                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SoC / boards    | `apollo510b` SoC, `apollo510b_evb` (template), `soc/ambiq/apollo5x` (`power.c` PM hooks, `cpu_freq.c` HP/LP perf states, cache/TCM setup, BLE low-power mode for the 510B)  |
| BLE             | `hci/apollox_blue.c` + hal_ambiq `am_devices_em9305.c` (HCI over IOM6 SPI) — gated, see rule 8                                                                              |
| MSPI            | `mspi_ambiq_ap5.c` + timing scan; `flash_mspi_nor.c` (generic JEDEC NOR, candidate for the MX25U25643G), PSRAM (`mspi-aps-z8`) on the evb                                   |
| Display / GPU   | `gpu_ambiq.c` (NemaGFX, `ambiq,nema-gpu`), NemaGFX SDK in hal_ambiq `components/graphics`, MIPI DBI/DSI drivers, LVGL fork (not in our workspace)                           |
| Audio           | `dmic_ambiq_pdm.c` (PDM0), `i2s_ambiq`, `amic_ambiq_audadc.c`                                                                                                               |
| Storage / MRAM  | `flash_ambiq.c` (MRAM, 16 B write / 2 KiB erase blocks), NVS/ZMS listed as supported                                                                                        |
| Power / sensors | Zephyr drivers for nPM13xx (MFD, charger, GPIO, LED), `charger_bq25180.c`, `bq274xx` (lists BQ27427), `opt3001`, `icm45686` (same TDK family as the ICM-45608; port needed) |
| Rest            | I2C/SPI on IOM, UART, GPIO, PWM, counter/timer, RTC, watchdog, CRC32, TRNG, crypto (CC312), ADC, USB, SDHC                                                                  |

## Next steps

Before rung 3 can be signed off (see safety.md "Rung 3 status"):

1. Jan reviews the terminal states and rules 11–12 in safety.md.
2. ~~Repeat `boot-test` with the bootloader version actually installed on the temples~~ done 2026-11-06: 2.4.0.24, 26/26. Still open: which bootloader is really in MRAM (the Even app may install the bundle's bootloader component only on some updates; 2.3.2.14's and 2.4.0.24's DFU code is identical either way), and a NOR model answering as GD25LE256H in case the temples have that part.
3. Put the real native app (Zephyr, relinked at `0x448000`, feeding the watchdog and calling `confirm()`) behind Wisp Boot instead of the bare-metal fault apps.

Toward rung 4 (hardware), none of which emulation can answer:

4. Read Wisp Boot's hardware assumptions off the stock image and the glasses: MSPI1 pin mux and clock after the bootloader's hand-off, UART1 state (or build with `WISP_BOOT_LOG=0`), ROM power-up on `MEMPWRSTATUS`, whether the 16 Hz watchdog divider and 8 s window suit the app.
5. Touchpad rescue hold (PSoC on I2C5 `0x0C`) as a Wisp Boot input.
6. Zephyr app: link at `0x448000`, feed the watchdog, confirm after BLE + `HELLO`, clear the flag after confirming (stock does that in its OTA init; until then every boot reinstalls the staged image). The board's uncached region already stops below Wisp Boot's RAM; `sram0` and the stack still have to be kept out of it.
7. Drivers still to write: the GX8002 mic path (UART3 control + I2S0 RX, never its firmware), PDM0, the buzzer (TIMER7 PWM), the magnetometer behind the IMU, the NOR littlefs (storage HAL), the inter-temple UART. A GPIO interrupt model in Renode would let the attention and data-ready paths run there too.
8. Before M6 (not rung 3): patch the HAL so the EM9305 update/recovery/trim code is compiled out and `apollox_blue.c` forces `skip_fw_update = true`; `CONFIG_WISP_BT_ALLOWED` stays off until `check_rule8.py` passes on that build.
