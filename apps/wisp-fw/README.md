# wisp-fw — Wisp native firmware (Apollo510B)

The native target of [Wisp](../../docs/wisp/README.md): Zephyr from Ambiq's fork (decision W11) on one G2 temple, emulated in Renode with g2emu's Apollo510 platform (W15). **M0: build skeleton + Renode boot; rung 3: Wisp Boot, fault-tested in Renode against the real Even bootloader; M6 part 1: Bluetooth with the Wisp GATT service carrying a wisp-core session, with the EM9305 driver patched so it can never write the controller's NVM ([Bluetooth](#bluetooth)); drivers for the panel, touch/wear, IMU, light and PMIC, tested in Renode against bus models ([Drivers](#drivers)). Nothing here has run on glasses, and nothing here can talk to hardware** — the board defines no flash runner, and no script uses J-Link, SWD or a real radio (the BLE test runs against a virtual controller).

Read [safety.md](../../docs/wisp/safety.md) before changing anything that ends up in the image.

## Use

Everything runs on t3-worker (NixOS) as a normal user. The flake in this directory pins the toolchain; the scripts enter it themselves (`nix develop`), so plain `pnpm nx` is enough.

| Target                             | What it does                                                                                                                                                                                  |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pnpm nx run wisp-fw:setup`        | west workspace in `.wisp-cache/west/` from [west.yml](west.yml) (every repo pinned by SHA; about 30 s first time, no-op after)                                                                |
| `pnpm nx run wisp-fw:build`        | `west build -b wisp_g2` (the app at `0x448000`, panel `WISP_PANEL=jbd4010`) into `.wisp-cache/build/wisp-fw/`, then the post-build gates; fails if any gate fails                            |
| `pnpm nx run wisp-fw:sim`          | boots `zephyr.bin` in Renode for 10 s of virtual time and streams UART1 (`scripts/sim.sh [seconds]`)                                                                                          |
| `pnpm nx run wisp-fw:test`         | Wisp Boot, flush and BLE adapter host tests, gate unit tests, Renode boot test, BLE end to end on native_sim, rule 8 and patch negative builds                                                |
| `pnpm nx run wisp-fw:drivers-test` | the drivers in Renode against panel and I2C models, both panels + one negative case ([below](#drivers); about 5 min)                                                                          |
| `pnpm nx run wisp-fw:build-boot`   | Wisp Boot (bare metal, `src/boot/`) into `.wisp-cache/build/wisp-boot/`, then the image and rule 8 gates on it                                                                                |
| `pnpm nx run wisp-fw:build-native` | **`native-0`**, the first native image: observe-only Wisp Boot + the app, combined and checked, into `.wisp-cache/build/native-0/` ([below](#native-0))                                    |
| `pnpm nx run wisp-fw:boot-test`    | **rung 3**: the real Even bootloader (stock 2.4.0.24 and the patched `87e2d4e0…`) + Wisp Boot (fallback and observe-only) + fault apps and the real app in Renode (see below; hours)        |
| `pnpm nx run wisp-fw:w18-test`     | **W18**: drdaeman's patched bootloader in Renode, driven by the real `apps/wisp-recovery/w18.py` code over an emulated UART2 ([below](#w18-the-patched-bootloader-in-renode-wisp-fww18-test)) |

Toolchain (from `flake.lock`, nixos-26.05 at `7dcdd87`): gcc-arm-embedded 15.2.rel1 (Zephyr variant `gnuarmemb`), CMake 4.1, Ninja, dtc, west 1.5, Renode 1.16.1, Bumble 0.0.228 (the virtual BLE controller of the end-to-end test). Setup applies Wisp's EM9305 patches to the workspace ([third_party/ambiq](third_party/ambiq/README.md)). Workspace: `AmbiqMicro/ambiqzephyr` `ambiq-stable` @ `89c8a36` (Zephyr 4.3.0) plus only `ambiqhal_ambiq` @ `d3278ec`, `cmsis`, `cmsis_6`, `mbedtls` (only for the BT negative build) and `littlefs` @ `8f5ca34` (Zephyr's fork of littlefs 2.11, BSD-3-Clause, on-disk format 2.1 like stock; Wisp Boot and the rung-3 tools build it directly, not through Zephyr's FS layer). To move the pin, edit `west.yml`, rerun setup, build, test. A from-scratch setup in an empty cache (`WISP_CACHE_DIR=…`) rebuilt a byte-identical `zephyr.bin` (the git revision string is embedded, so compare at the same commit).

CI: the GitHub workflow (macOS, no nix) runs `nx run-many -t build test` and would fail on this project; it needs `--exclude=wisp-fw` there (not changed in this PR: the push token has no `workflow` scope). This project is green on t3-worker.

## Layout

```
boards/even/wisp_g2/   out-of-tree board: Apollo510B, Wisp Boot at 0x438000, the app's code partition at
                       0x448000, UART1 console, UART2 case link; no default panel
boards/panels/         jbd4010 / a6n-g overlays (WISP_PANEL picks one; BUCK1's voltage with it)
images/native-0/       the native-0 image's .conf + overlay (panel off, PMIC drivers off)
src/main.c             watchdogs, case UART, banner, Wisp Boot's status, native HAL bring-up,
                       Bluetooth start, heartbeat; the driver self-test (test builds)
src/boot_link.c        the app's side of Wisp Boot: services table, status block, confirm()
src/case/              case-UART status protocol (docs/wisp/case-uart.md): codec (portable,
                       host-tested) + the UART2 thread
src/ble/               the Wisp GATT service on Zephyr: transport only (wisp_ble.c)
src/link/              transport adapter between a GATT link and wisp-core's wisp_conn: chunking,
                       back-pressure, advertising policy, idle drop (portable C, host-tested)
src/hal/               the HAL boundary for Wisp core: display, input, sensors, audio, power,
                       storage, link — no Zephyr dependency (link: the ops a target provides)
src/hal/native/        the native HAL on the drivers: display (flush path), input, sensors, power
src/display/           wisp_flush: core strips -> panel frame -> dirty rows (portable, host-tested)
src/drivers/           uled (panel), g2_touch (PSoC), icm45608, opt3007 — Wisp's own, MIT
dts/bindings/          their devicetree bindings (+ vendor prefixes)
src/boot/              Wisp Boot: wisp_boot.* (pure decision, record, image check; host-tested),
                       stage/ (the bare-metal stage at 0x438000: NOR, littlefs, flag, watchdog),
                       CMakeLists.txt (standalone, arm-none-eabi-gcc), wisp_boot_layout.h
cmake/rule8.cmake      configure-time rule 8 gate
scripts/               setup/build/sim/test, build_native.sh, check_image.py, check_rule8.py,
                       check_no_mram_write.py (G13), check_native.py, wisp_layout.py
renode/                wisp_g2.repl (derived from g2emu, with the panel and I2C models) +
                       wisp_g2.resc; rung 3: wisp_g2_boot.repl, boot.resc; models/ (Wisp's C#
                       models: NOR+MSPI, panel+MSPI, IOM+I2C devices, reset, WDT, boot ROM, ...)
third_party/g2emu/     three g2emu C# peripheral models (MIT, unmodified), see its README
third_party/ambiq/     Wisp's patches to the fork: the EM9305 driver never writes NVM (rule 8)
boards/*.conf          per-board additions to prj.conf (wisp_g2; native_sim for the BLE test)
tests/                 boot/ (C host tests; rung3.py harness, app/ fault apps, tools/wisp_lfs.c),
                       link/ (adapter host tests), ble/ (end to end: Bumble bridge + SDK test),
                       display/ (flush host test), drivers/ (Renode driver checks, JBD overlay),
                       scripts/ (gate unit tests), sim/ (UART assertions),
                       rule8/ (negative builds: BT not allowed, canary)
```

Wisp core: linked whenever `CONFIG_WISP_BLE` is on (the default), or with `-DWISP_WITH_CORE=ON` (optionally `-DWISP_CORE_DIR=…`, default `packages/wisp-core`). It is built as its own CMake project with Zephyr's flags and its own `-Wpedantic -Werror` (Zephyr's headers passed as system includes); `CONFIG_STD_C11` because the core is C11.

## What boots

`wisp_g2` app: about 198 KB, linked at `0x448000`, behind Wisp Boot (vector table first; initial SP in SSRAM below Wisp Boot's RAM). `wisp-fw:sim` loads the flat `zephyr.bin` at `0x448000` and starts it the way Wisp Boot hands off (VTOR = `0x448000`, MSP = vector 0, PC = vector 1); a whole native image (Wisp Boot + app, what the Even bootloader or install-wisp puts at `0x438000`) is `wisp-fw:build-native`'s, and rung 3 and W18 boot it behind the real bootloaders. *(The log below predates the move to `0x448000`; the lines are the same.)* The platform has Wisp's I2C and panel models, so the drivers probe their devices (everything stays suspended); it has no EM9305, so Bluetooth gives up after the driver's 5 s active-state timeout and the app runs on without a link. UART1 from a `wisp-fw:sim` run:

```
[00:00:00.114,105] <inf> g2_touch: PSoC firmware 01000202
[00:00:00.114,196] <inf> g2_touch: long press 1000 ms
*** Booting Zephyr OS build 4.3.0 ***

I: PSoC firmware 01000202
I: long press 1000 ms
*** Booting Zephyr OS build 4.3.0 ***

*** Wisp native 0.0.0-ble (0aada8bd98-dirty) ***
wisp: board wisp_g2, Zephyr 4.3.0, image @ 0x438000
wisp: hal power ok (0)
wisp: hal display ok (0)
wisp: hal input ok (0)
wisp: hal sensors ok (0)
wisp: sensors present 0x1b
wisp: bluetooth: EM9305 update path compiled out (safety rule 8)
E: EM9305 active state timeout
E: BT controller initialization failed: 1
E: HCI driver open failed (1)
E: Bluetooth unavailable (1): no Wisp link
wisp: bluetooth unavailable, running without a link
wisp: heartbeat 1 uptime 6198 ms
wisp: heartbeat 2 uptime 7241 ms
wisp: heartbeat 3 uptime 8285 ms
```

That is also a rule 8 test: a controller that never reports "active" is exactly when the unpatched driver starts its NVM recovery reflash. `tests/sim/check_uart.py` fails on any of the driver's update / recovery log lines and on a fault. The kernel ticks off the STIMER (Renode's Apollo4 system-timer model is register-compatible enough for `ambiq_stimer.c`); heartbeats drift about 4 % per second of virtual time. No Renode warnings at log level 3.

## Board `wisp_g2`

- **MRAM partitions** (flash0 starts at `0x410000`, so offsets are relative to it): `even-bootloader` `0x410000–0x438000` read-only (the 32-byte EVEN preamble at `0x437FE0` sits at its end and is added by wisp-ota, never the linker), `wisp-boot` `0x438000–0x448000` (Wisp Boot, built separately), `wisp-app` `0x448000–0x7F8000` = `zephyr,code-partition` (the linker region ends exactly at the ceiling), `even-nv` `0x7F8000–0x800000` read-only (update flag at `0x7FE000`, bonds).
- **Devices** (every bus, address, pad and sequence from stock 2.4.0.24, with confidence and source in [hardware.md "Native drivers"](../../docs/wisp/hardware.md#native-drivers-stock-24024)): UART1 console on GPIO12/14 at 921600 (as stock); I2C2 OPT3007 `0x45`; I2C4 ICM-45608 `0x69` (INT1 GPIO38, rail GPIO129); I2C5 PSoC touch `0x0C` (attention GPIO27, reset GPIO10); I2C7 nPM1300 `0x6B` (IRQ GPIO4) with BUCK1 (panel rail), BUCK2 3.1 V and LDSW1 1.8 V always-on, LDSW2, charger at stock's values, the PMIC watchdog; MSPI0 the microLED panel on CE0 GPIO199 (**no default** (rung4.md G11): `WISP_PANEL=jbd4010` or `a6n-g` adds `boards/panels/<panel>.overlay` with BUCK1's voltage; both of Jan's temples are hardware 5, the JBD4010, PR #73); UART2 the case link (GPIO42/44, 1 Mbaud, [case-uart.md](../../docs/wisp/case-uart.md)). Every device starts suspended (`zephyr,pm-device-runtime-auto`).
- **BLE:** IOM6 SPI with the EM9305 (`ambiq,bt-hci-spi`, `zephyr,bt-hci`), see [Bluetooth](#bluetooth). Its pads and IRQ / reset / CLKREQ / CM pins are the evb's (the EM9305 is inside the Apollo510B package, so probably fixed, but unproven).
- **Disabled:** MSPI1 (NOR, Wisp Boot's for now), PDM0, I2S0 (GX8002), GPU; buzzer and inter-temple UART as comments.
- **Uncached SRAM** `0x20200000–0x20370000` (panel frame, MSPI command queue); it stops below Wisp Boot's RAM (`0x20370000–0x20380000`).
- **Unverified on the G2:** STIMER clock source; which panel is fitted; I2C pull-ups (internal ones are on).
- `SOC_APOLLO510B_EM9305_EXTREF_INIT` defaults to n on this board (see below).

## Drivers

All of them Wisp's own (MIT) except the nPM1300 drivers (Zephyr in-tree) and the I2C controller driver (the fork's, with Wisp's byte-order patch). Facts and their confidence: [hardware.md "Native drivers"](../../docs/wisp/hardware.md#native-drivers-stock-24024).

| Driver                                                      | Compatible            | What it does                                                                                                                                                                                                               | Power                                                                                                                    |
| ----------------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `src/drivers/uled.c`                                        | `even,g2-uled`        | both panels: stock's power sequences, init streams, brightness maps, health checks; full frames by DMA (quad 1-1-4), JBD row updates by PIO; owns the 153 602-byte frame in uncached SRAM                                  | PM runtime: resume = rails + init + blank frame, suspend = stock's power-down, rails off (no panel sleep command exists) |
| `src/drivers/g2_touch.c`                                    | `even,g2-touch`       | reset, version, long-press threshold, then one 16-byte report per attention edge; gestures, press/release, wear; resets the PSoC on its error flag. **Command allow-list: 2 (DFU) and 7 (EEPROM write) can never be sent** | suspend = attention interrupt off                                                                                        |
| `src/drivers/icm45608.c`                                    | `invensense,icm45608` | WHO_AM_I `0x81`, soft reset, ±4 g / ±2000 dps, ODR 25–800 Hz, accel LP up to 400 Hz, data-ready trigger on INT1                                                                                                            | suspend = sensors off + rail off (0 current); resume = rail cycle, reset, restore                                        |
| `src/drivers/opt3007.c`                                     | `ti,opt3007`          | one single-shot conversion per fetch (sleeps through the 100 ms integration), lux from the result register                                                                                                                 | shutdown except during a fetch                                                                                           |
| Zephyr `nordic,npm1300*`                                    | —                     | MFD, regulators, charger (battery voltage, status, VBUS = case); off in hardware images (native-0: the HAL reads the PMIC directly)                                                                                         | the HAL arms the PMIC watchdog with stock's writes and kicks it every second                                             |
| Zephyr `i2c_ambiq.c` + [patch](third_party/ambiq/README.md) | `ambiq,i2c`           | the fork's driver with Wisp's `zephyr-0002` patch: multi-byte register headers go out in buffer order (upstream reverses them)                                                                                             | as upstream                                                                                                              |

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
- **Negative case:** the same image built against a pristine Zephyr tree (no `zephyr-0002` patch; configure check skipped with the TEST ONLY `WISP_PATCHES_TEST_UNPATCHED`, Bluetooth off) must fail the PMIC byte-order check. `wisp-fw:test` separately proves the configure check fires on that tree.

Result on t3-worker, 2026-11-06: both panels pass (A6N-G 33 panel / 123 I2C transactions, JBD4010 76 / 127), the negative case is rejected (`3404` instead of `0434`). What the models cannot show: timing (every transfer completes at once), GPIO interrupts (the touch report is serviced by a direct call), real panel behaviour beyond the recorded bytes, analog values (battery reads 0 mV).

## Checks in place

All run in every build (`wisp_checks` target, after the link) and fail it:

**Image (rules 1 and 3), `scripts/check_image.py`:** the app (`--part app`): load address = `0x448000`, SP and every RAM section below Wisp Boot's RAM (`0x20370000`); Wisp Boot and whole images: load address = `0x438000`; image end ≤ `0x7F8000`; no loadable segment in MRAM outside `[0x438000, 0x7F8000)` and none outside MRAM; vector[0] (SP) in `(0x20000000, 0x20380000]` and 8-byte aligned; vector[1] (reset) Thumb and inside the image. Output: `check_image: OK load 0x00438000 end 0x0045c598 (3783272 bytes free) SP 0x2008dd30 reset 0x00439f55`. The constants live in `scripts/wisp_layout.py`; wisp-ota keeps its own copy on purpose (rule 3 wants independent implementations).

**No MRAM write path (rule 1, rung4.md G13), `scripts/check_no_mram_write.py`:** after every app link, and on the observe-only Wisp Boot: no symbol of `am_hal_mram_*`, `nv_program_*`, `am_hal_bootrom_*`, `g_am_hal_bootrom_helper`, `*_program_info*`, `flash_ambiq_*`, `hw_flag_set_install`; no input section of `am_hal_mram.c`, `am_hal_bootrom_helper.c` or the Ambiq flash driver in the linked map; no Ambiq flash/MRAM driver Kconfig; neither the program key `0x12344321` nor a boot-ROM helper address `0x0200FF00–0x0200FF7F` as a word at any byte offset of the binary, nor built by a movw/movt pair. `wisp-fw:test` builds a canary that links `am_hal_mram_main_program` and requires the gate to reject it; the fallback Wisp Boot fails it too (its one flag write), which is why the gate runs only on the observe-only build.

**Hardware images, `cmake/hwimage.cmake` (G11, G12):** a build with `CONFIG_WISP_HW_IMAGE` fails at configure time if the panel or any nPM1300 driver node is enabled, a test switch is set, or the image kind is 255. `wisp-fw:test` proves it fires.

**EM9305 (rule 8): Wisp's patches ([third_party/ambiq](third_party/ambiq/README.md)) + `cmake/rule8.cmake` + `scripts/check_rule8.py`.** Bluetooth is on, so the proof is about what is in the image, not about a switch:

1. _configure:_ fails on `CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT`, `CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM` (writes EM9305 NVM), `CONFIG_BT_HCI_SET_PUBLIC_ADDR` (vendor command `0xFC43`, persistence unknown), on `CONFIG_BT` / `CONFIG_AMBIQ_COMPONENT_USE_BT` without `CONFIG_WISP_BT_ALLOWED=y` and `CONFIG_WISP_EM9305_SKIP_FW_UPDATE=y`, and on any Wisp patch that is not exactly applied to its project (`git apply --reverse --check`): `EM9305 patch missing`.
2. _sources_ (`compile_commands.json`): with BT off, no EM9305 driver source is compiled. With BT on, every compiled caller of `am_devices_em9305_init()` must assign `skip_fw_update = true` and nothing else.
3. _units_ (BT on): the driver and every unit that mentions it, **preprocessed with their exact compile commands**, so this is the code the compiler saw: the driver carries the patch marker; no unit includes `ble_fw_image_em9305.h`; none contains an update / recovery / CM / trim identifier or the opcodes `0xFD03` (NVM write), `0xFD06` (erase NVM main), `0xFD07` (erase page), `0xFC43` (public address); every call site forces `skip_fw_update = true` (a macro that hides `false` from a text search is caught here).
4. _symbols_ (`nm --defined-only`, locals included): none of the update / recovery / NVM-write / CM / trim functions or their state, no `ble_fw_image_bin_*`, `image_records`, `erase_pages`; with BT off, no `am_devices_em9305_*` at all.
5. _map:_ BT off, no `am_devices_em9305.c.obj` linked; BT on, no input section of a forbidden function or array.
6. _code_ (BT on): no instruction in the disassembly of the whole ELF loads one of those opcodes as an immediate or literal. A secondary look only: the Ambiq driver writes opcodes byte by byte (`sys_put_le16`), so this one did **not** fire on the unpatched build; look 3 is what catches the opcodes.
7. _bytes:_ none of the EM9305 firmware arrays (64-byte windows parsed from the HAL's own `ble_fw_image_em9305.h`, start and middle) occurs in `zephyr.bin` — still works with symbols stripped or functions inlined.

On the shipped image: `check_rule8: OK bt=on, 2667 symbols, no forbidden symbols, map clean, 6 EM9305 image signatures absent, EM9305 units preprocessed clean, no NVM write/erase opcode in 4 checked`. In Renode the patched driver meets a controller that never comes up (the unpatched driver's recovery-reflash case) and gives up without writing anything ([What boots](#what-boots)).

How the gate was shown to fire (all part of `wisp-fw:test`, step 6):

| Build                                                                                  | Result                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/rule8/bt.conf` (BT on, `CONFIG_WISP_BT_ALLOWED=n`)                              | configure fails: `WISP SAFETY RULE 8 … Bluetooth / the EM9305 driver is enabled without CONFIG_WISP_BT_ALLOWED=y`                                                                                                                                                   |
| pristine `hal_ambiq` (git worktree of the pinned commit, no patch)                     | configure fails: `EM9305 patch missing: hal_ambiq-0001-em9305-never-write-nvm.patch is not applied`                                                                                                                                                                 |
| pristine Zephyr                                                                        | configure fails: `EM9305 patch missing: zephyr-0001-em9305-never-write-nvm.patch is not applied`                                                                                                                                                                    |
| pristine `hal_ambiq`, configure check skipped (`WISP_RULE8_TEST_UNPATCHED`, test only) | builds, then post-build fails with 76 findings: no patch marker, image header included, 28 forbidden identifiers and 3 NVM write/erase opcodes in the compiled units, 11 symbols, 22 map sections, 6 image byte windows (the instruction look finds nothing, see 6) |
| `-DWISP_RULE8_CANARY=ON` (EM9305 image linked via `SYS_INIT`)                          | post-build fails: `ble_fw_image_bin_*`, `image_records`, image bytes, the header in a unit                                                                                                                                                                          |
| canary ELF stripped                                                                    | byte check alone rejects it                                                                                                                                                                                                                                         |

`CONFIG_BT_HCI_SET_PUBLIC_ADDR` has no prompt (only SoCs select it), so it has no negative build; its gate is covered by the unit tests. The unit tests (`tests/scripts/test_checks.py`) cover every look on synthetic inputs, including a real preprocessor run.

### What the fork does with the EM9305 (why the gate is this strict)

- `am_devices_em9305_init()` reflashes when the device version is **≤** the bundled `0x04050100` (equal → CRC verify, reflash on mismatch), when the version can't be read, and when the controller won't boot. Only `skip_fw_update` stops it — a runtime flag, so the image and erase code stay linked either way.
- `drivers/bluetooth/hci/apollox_blue.c` (`bt_apollo_controller_init`) builds its callback struct without `skip_fw_update` → `false` whenever BT is on. (All of this is the unpatched fork; Wisp's patch removes it.)
- The evb's `board.c` EXTREF init (SoC default y whenever an `ambiq,bt-hci-spi` node is enabled) passes `skip_fw_update = IS_ENABLED(CONFIG_BT)` → `false` with BT off — a board that merely describes the radio in DT and leaves BT off would reflash it at boot. `wisp_g2` has no `board.c` and pins the default to n; the patch also fixes the evb's.
- Even's EM9305 version is unknown. If it is ≤ `0x04050100`, any stock-fork BT build reflashes it on first boot.

## Bluetooth

The first piece of the native firmware proper: the Wisp GATT service ([protocol.md](../../docs/wisp/protocol.md#links)), carrying a wisp-core session, so the TypeScript SDK can talk to a native temple.

```
phone ─ @wisp/sdk ─ GATT ─┐   glasses
                          ▼
  src/ble/wisp_ble.c     Zephyr: GATT service, advertising, connection callbacks   transport only
        │ one work queue thread ("wisp_link"); callbacks only set bits / fill a ring
  src/link/wisp_link.c   adapter: MTU chunks, back-pressure, advertising mode,      portable C,
        │                idle drop                                                  host-tested
  wisp-core wisp_conn    frames, CREDIT / RESYNC, coalesced credits, window queue,  portable C,
        │                ack timeout, session timeout, deadlines                    host-tested
  wisp-core wisp_basic   the session: HELLO, PING, TIME_SYNC, BYE; error 1 for every other service
```

- **Service** `cf099bf1-f34e-49e2-b353-7f20e02243bc`: RX `…bf2` (write without response; plain write is accepted too), TX `…bf3` (notify + CCC). The stream is cut into notifications of ATT MTU − 3 bytes (244 at MTU 247; ACL buffers are 251 bytes so one notification is one link-layer packet). Name `Wisp`, the service UUID in the advertising data.
- **Protocol logic lives in wisp-core.** `wisp_conn` (new, `packages/wisp-core/include/wisp/conn.h`) is one byte-stream connection: it feeds `wisp_rx`, answers duplicates with CREDIT and gaps with RESYNC, applies control frames in any state, sends coalesced CREDITs (at once when 25 % of the window is consumed or when bytes go out anyway, else 20 ms after the first unacknowledged frame), queues bodies that don't fit the phone's window, runs the ack and session timeouts, and returns one deadline. `wisp_basic` is the session alone; the engine plugs in through the same handler interface once drivers exist. The Zephyr side never parses a byte.
- **HELLO** answers `fw_name` `wisp-native`, protocol 0.2, `max_frame` 4096, `rx_window` 16384, `caps` 0 (no drivers behind the core yet, so no display, input or sensors are claimed), canvas 640 × 480 × 4 bpp, `session_timeout_ms` 10 000, `lens` from `CONFIG_WISP_LENS` (1; the temple side is not read from the hardware yet).
- **One connection at a time.** Advertising runs whenever nobody is connected. A connection that has no session for 10 s (`CONFIG_WISP_LINK_IDLE_DROP_MS`: no HELLO after connecting, or after BYE / a session timeout) is dropped, so advertising is only off while a session is up or about to be. A dropped link ends its session like BYE.
- **EM9305:** the patched driver (rule 8, [third_party/ambiq](third_party/ambiq/README.md)). If the controller does not come up, `bt_enable()` fails, the firmware runs on without a link, and nothing is written to the controller.

### Power choices

| What                  | Choice                                                                                                                                         | Why                                                                                                                                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Advertising           | 152.5 ms for 30 s after boot or a disconnect, then 1022.5 ms; off while connected                                                              | Both are Apple's recommended intervals: found within a second or two right after the phone loses the link, then about 1 % of the fast duty cycle while nobody looks. Legacy advertising, one set.                       |
| Connection parameters | the glasses ask for 30–50 ms, latency 0, supervision 4 s (5 s after connecting; the phone decides)                                             | Stock runs 30 ms. Latency 0 keeps a phone write within one interval of the glasses; the protocol's `LINK_PROFILE` op (not implemented yet) is where idle (higher latency) and bulk (7.5–15 ms) will switch it.          |
| Link layer            | 251-byte packets (DLE) and 2M PHY when both sides offer them                                                                                   | Less air time per byte, which is most of the radio's energy per transfer.                                                                                                                                               |
| Firmware              | no polling: the link thread runs on an event or at `wisp_conn`'s next deadline (credit, ack or session timeout, idle drop, advertising switch) | With a session up and the phone quiet, the only wakeups are the phone's keepalive PINGs (every 3.3 s by default) and the connection events themselves. With no connection, only advertising events and the 30 s switch. |
| Notifications         | at most 3 in flight in the Bluetooth stack (`CONFIG_WISP_LINK_TX_IN_FLIGHT`)                                                                   | A notification never blocks waiting for a buffer; the adapter retries the same chunk after the next completion.                                                                                                         |
| Heartbeat             | `CONFIG_WISP_HEARTBEAT_MS` 1000 (debug)                                                                                                        | One UART line per second costs power on glasses; set it to 0 for hardware. The Renode test needs it.                                                                                                                    |

Not decided yet: EM9305 sleep (`CONFIG_SOC_AMBIQ_APOLLO5X_BLE_LP`, off as on the evb), `CONFIG_PM` on the Apollo side, and what the glasses do when unworn. Measuring any of it needs hardware.

### Tests without hardware

- **Host unit tests** (`wisp-fw:test` step 2, `tests/link/test_wisp_link.c`): the adapter with a fake GATT target and a phone built from wisp-core's own sender and receiver: advertising modes and their timing; HELLO at ATT MTU 23 and 247 (chunk sizes), answers held until the phone subscribes; notifications refused by a full stack (same bytes retried) or lost (recovered by the ack timeout); the idle drop before HELLO, after BYE and after a session timeout; disconnect mid-session and a reconnect from seq 0. wisp-core's `tests/test_conn.c` covers `wisp_conn` itself, including 20 seeds of 300 PINGs over a link that drops 3 % of chunks both ways.
- **End to end** (step 5, `tests/ble/`): Renode cannot model the EM9305, so the same app is built for `native_sim/native/64`, where Zephyr's HCI user-channel driver talks H4 over TCP to a virtual controller ([Bumble](https://github.com/google/bumble), Apache-2.0). A second virtual controller on the same virtual link is the phone: `bumble_bridge.py` scans, connects, exchanges MTU 247, discovers the service and subscribes, and `e2e.test.mts` runs the real `@wisp/sdk` (`WispGlasses.connect`) through it. Zephyr's host stack, the GATT service, the adapter and wisp-core run unchanged; only the HCI driver differs from `wisp_g2`. The bridge's controller adds what Bumble's model lacks and a real controller must do: controller-to-host ACL flow control (without it the instant virtual link overran Zephyr's RX buffers) and answers to the connection-update, PHY and data-length procedures (which it reports to the test).

  | Test                                                                             | Checks                                                                                           |
  | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
  | the firmware advertises the Wisp service; a central connects at ATT MTU 247      | service UUID in the advertising data, MTU 247, RX write-without-response, TX notify, name `Wisp` |
  | the SDK completes HELLO against the native build                                 | protocol 0.2, `wisp-native`, `max_frame` 4096, timeout 10 s, canvas, caps 0                      |
  | session requests round-trip; services without drivers answer error 1             | `TIME_SYNC` × 3, `system.info()` → `WispError` 1                                                 |
  | frames larger than one write, past the receive window, arrive whole and in order | 12 × 3000-byte requests (36 kB, twice the window) → 12 errors in order, no RESYNC needed         |
  | no advertising while the session is up                                           | a 1.5 s scan sees no Wisp advertisement                                                          |
  | the firmware asks for its connection parameters                                  | LE Connection Update with 24–40 (30–50 ms), latency 0, 400 (4 s)                                 |
  | BYE ends the session; advertising resumes                                        | disconnect, then a scan sees it again; firmware log shows the session start and end              |
  | a connection without a session is dropped after 10 s                             | the firmware disconnects (0x13) 8–13 s after connecting                                          |

  18 s wall. The firmware's log is kept in `.wisp-cache/test/e2e-firmware.log`.

### Size and RAM (wisp_g2, `pnpm nx run wisp-fw:build`)

| Region              | M0 skeleton | With Bluetooth | Of which                                                                                                                                                                                                                     |
| ------------------- | ----------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MRAM (`zephyr.bin`) | 53 732 B    | 148 888 B      | Zephyr BT host + GATT, the EM9305 HCI driver, PSA crypto from mbedTLS (the host's `bt_rand` needs it), wisp-core's session and frames (`check_image`: 3 783 272 bytes left below `0x7F8000`)                                 |
| SSRAM, static       | —           | 70 850 B       | Wisp link 23.3 KB (frame buffer 4 106, send ring 8 192, window queue 4 096, RX ring 4 096, thread stack 2 048, adapter state 784); BT host buffers and stacks about 13 KB; Ambiq's IOM handle table 17.9 KB; main stack 2 KB |

The link buffers are Kconfig options (`CONFIG_WISP_LINK_*`); `max_frame` and `rx_window` in HELLO follow them. The main stack is 2 KiB because `bt_enable()` runs the EM9305 bring-up on it (the driver keeps a 258-byte buffer on the stack): with 1 KiB it overflowed in Renode, which does not enforce the M55's MPU stack guard.

### Still missing before a first native boot

Bluetooth was the transport; these are the rest of the way to rung 4 (safety.md), roughly in order:

1. **Hardware facts from the stock image** (none of these can be found in emulation): UART1 pads, the EM9305's SPI and GPIO pins (probably the evb's, unproven), the STIMER clock source, which power board and NOR part the temples have. Whether Even's EM9305 firmware comes up without a patch load from the host (if not, Bluetooth stays off and nothing is written).
2. ~~**Wisp Boot in front of this app**~~ done in `native-0` (W22): linked at `0x448000`, out of Wisp Boot's RAM, feeds the watchdog, confirms after `HELLO`; rung 3 runs with it. Still open: clearing the update flag after a confirmed new install (R4-3, G17).
3. **The update service** (protocol `0x07`): receive, verify and stage an image through the stock staging file, so a native temple can be updated, and returned to stock, over BLE. Without it a native image can only be left by Wisp Boot's fallback.
4. **The rescue precondition** (rule 11) and **a proven recovery path** (W17, M5): `wisp/rescue.bin` verified on the temple's NOR, and SWD or a software fallback proven on hardware.
5. Pairing / encryption of the link (none yet: anyone in range can open a session) and a real entropy source (the TRNG is not enabled on `wisp_g2`, so mbedTLS, which the host uses for `bt_rand`, runs on Zephyr's test-only fake entropy), `LINK_PROFILE`, a wisp-core engine behind `wisp_conn` once there are drivers, `lens` from the hardware.
6. Power: EM9305 sleep, `CONFIG_PM`, heartbeat off, and measuring all of it.

## Wisp Boot

The first stage of the native image (safety.md "Fallback-to-stock"): `[0x438000, 0x448000)` is Wisp Boot, the Wisp app's vector table follows at `0x448000`. Bare metal, no Zephyr, no BLE, no interrupts; 16 760 bytes (`wisp_boot.bin`), most of it littlefs. Built by `scripts/build_boot.sh` (CMake in `src/boot/`), and the build fails unless `check_image.py` (rules 1, 3) and `check_rule8.py` (sources, symbols, map, EM9305 image bytes; Wisp Boot has no Kconfig, so an empty config stands in) pass on it:

```
check_image: OK load 0x00438000 end 0x0043c178 (3915400 bytes free) SP 0x20380000 reset 0x0043847d
check_rule8: OK bt=off, 129 symbols, no forbidden symbols, map clean, 6 EM9305 image signatures absent
```

Every boot (`stage/boot_main.c`):

1. Arm the watchdog (LFRC/64, reset after 128 ticks, `RSTGEN.CFG.WDREN`) and lock it. The app must feed it. The LFRC is about 900 Hz (hal_ambiq `apollo510.h`), so that is about 9.1 s, not the 8 s an LFRC of 1024 Hz would give; stage-0 measures the real figure.
   Since W24 (rung4.md, "W24 result and analysis"), right after the arm: keep the previous boot's **diagnostics record** (`wisp_diag.h`, at `0x20370000`, never copied or zeroed) in the status block and start this boot's (RSTGEN.STAT, a boot counter, breadcrumbs, a fault if a handler runs); **kick the nPM1300 watchdog** once (`stage/boot_pmic.c`: `07 04 01` over IOM7 with the patched bootloader's own IOM7 register values, the only PMIC write Wisp Boot can make), so a reboot loop keeps re-kicking it and the PMIC never power-cycles back to its reset values; then the **boot-report window** on UART2 (`stage/boot_uart.c`, the loader's own UART2 values): only BOOTREP is answered ([case-uart.md](../../docs/wisp/case-uart.md#the-boot-report-op-04)), about 300 ms with no request, 100 ms after the last answer, at most 1 s (and a poll cap if the STIMER does not count). Pad writes go between GPIO PADKEY `0x73` and 0, as the bootloader's. Fault handlers record the fault before they reset.
2. MSPI1 PIO driver for the MX25U25643G (`stage/boot_nor.c`: READ4B/PP4B/SE4B, so 3- or 4-byte mode does not matter) and littlefs with the stock geometry. **It never formats**: no filesystem → run the app degraded.
3. Read the boot record `wisp/boot.rec`, the 8-byte preamble head of the staging file, and check `wisp/rescue.bin` (rule-3 header check + full zlib CRC, `wisp_boot_image_check()`).
4. Decide (`wisp_boot_decide()`, pure, host-tested), write the record back, then
   - `run-app` / `run-app-degraded`: check that the app's vector table is runnable (SP in SRAM below Wisp Boot's RAM, Thumb reset handler inside the slot; an erased slot is not — it would fault into its own garbage vectors and lock the core up), else reset at once (the attempt is already counted); quiet the NVIC, VTOR = `0x448000`, jump;
   - `rescue`: copy `rescue.bin` → `ota/s200_firmware_ota.bin` (littlefs makes the new file visible only at close), re-read and CRC the staged copy, write the flag record `{0x55555555, ~0, ~0, ~0}` through the boot ROM and read it back, software POR. Any failure → reset **without** writing the flag.

The app confirms a good boot through a fixed services table at `0x438200` (`stage/boot_services.h`: `confirm()` rewrites the record with Wisp Boot's own code and RAM, the top 64 KiB of SSRAM, which the app must leave alone). Version 2 of the table also points at Wisp Boot's **status block** (`wisp_boot_status.h`, 692 B in version 2, CRC-sealed): NOR id, mount result, the record, staging and `rescue.bin` facts, the `/firmware` inventory with sizes and CRCs, the action taken and the action the fallback build would take, and (version 2) the reset cause, the PMIC kick's result, the window's figures and the previous boot's diagnostics record. The app reports it over the case UART.

**Observe-only build** (`-DWISP_BOOT_OBSERVE=ON`, native-0's): the same code with every write compiled out: littlefs `LFS_READONLY`, no NOR program or erase (its only NOR commands are RDID, RDSR and READ4B), no flag write, the record never written, the action always `run-app`; `confirm()` only counts. 8,256 bytes. `-DWISP_BOOT_LOG=OFF` drops the UART1 log (hardware images: UART1's state after the hand-off is unconfirmed).

**Boot record on the NOR, not in retained SRAM.** It has to survive power loss and every kind of reset. Retained SRAM does neither reliably: a power loss clears it, and the SBL and the Even bootloader run before Wisp Boot on every boot and use SRAM themselves. Whether SRAM survives a software POR or a watchdog reset on the Apollo510 is not documented, and rung 3 fills it with `0xA5` on every reset so nothing can depend on it. MRAM would survive, but then Wisp Boot would carry a second MRAM write path next to the flag (rule 1 wants exactly one). littlefs commits a small file atomically (copy-on-write metadata), Wisp Boot needs littlefs for the rescue copy anyway, and one record write per boot is far inside the NOR's endurance (littlefs wear-levels, `block_cycles` 500).

**Decision rules** (`src/boot/wisp_boot.h`): 3 unconfirmed boots → rescue. A pending rescue (power cut mid-rescue, or the bootloader did not install) is resumed on the next boot; after 4 rescue tries the app runs degraded instead of resetting forever. The record carries the CRC word of the staging preamble it belongs to: an install always goes through the staging file, so a different word means a new install and a fresh record (a reinstalled Wisp starts with a clean count). No valid `rescue.bin` → never touch the staging file or the flag; run the app with a fresh 3-boot window. Touchpad rescue hold: input exists, reading the PSoC (I2C5 `0x0C`) is a TODO.

## native-0

The first native image (docs/wisp/rung4.md §2, W22): `pnpm nx run wisp-fw:build-native` (`scripts/build_native.sh native-0`) builds the observe-only Wisp Boot without its log, the app with `images/native-0/` (`CONFIG_WISP_HW_IMAGE`, image kind 0, the panel node disabled, every nPM1300 driver node disabled), runs every gate on each part, combines them (Wisp Boot padded to 64 KiB, then the app), checks the combined image (`check_native.py`), runs wisp-ota's rule-3 guards on it (`pack-main`: sendable) and writes `.wisp-cache/build/native-0/manifest.json` with the SHA-256 of the image, both ELFs and maps, Wisp Boot's binary and its 64 KiB slot. Nothing is pinned here; pinning is W23.

What the app does differently on native-0:

- **Watchdogs** (`src/hal/native/power.c`): a thread at the highest priority, started at `POST_KERNEL` init, restarts Wisp Boot's locked WDT (raw `RSTRT`, also once at `PRE_KERNEL_1`) and kicks the nPM1300's every second, after arming it with stock's own writes (`07 05 0A`, `07 08 00 3C 00`, `07 03 01`, `07 00 01`).
- **PMIC observed, not configured** (G12): none of Zephyr's nPM1300 drivers run (their init writes SHIP/LPRESET, the GPIO mode, rails and the whole charger configuration from our DTS, unchecked against stock until W21). The HAL's only PMIC writes are the watchdog's and the ADC's VBAT task (`05 00 01`); charger and VBUS status are reads. Renode asserts that allowlist and that no configuration register leaves W21's snapshot (`images/pmic-baseline-w21.json`, `scripts/pmic_baseline.py`); the driver test prints where the development build's drivers would.
- **Panel off** (G11): the panel node and MSPI0 are disabled; no MSPI0, BUCK1, LDSW2 or panel GPIO is touched; display calls return `ENOTSUP`.
- **Case UART** (`src/case/`, [case-uart.md](../../docs/wisp/case-uart.md)): IDENT, READ (its status, Wisp Boot's block) and RESET in the relay's frame shapes, stock's `0x24` query; nothing unasked; the case app's `0x13` poll unanswered (G10b).
- **confirm()** after a BLE `HELLO` (interrupts locked); the services table is checked before use.
- **Wisp Boot's status** printed once on UART1.



**What runs.** The unmodified stock bootloader (2.4.0.24 by default, the version on Jan's temples; `WISP_STOCK_VERSION` picks another cached bundle) (`ota/s200_bootloader.bin` from the pinned bundle in `.wisp-cache/`, SHA-256 checked, never committed) at `0x410000`, started the way the SBL hands off. In front of nothing but Renode peripheral models: no code patches, no hooks in Even's code. The NOR is a 32 MiB file with a littlefs image built on the host (`tests/boot/tools/wisp_lfs.c`, the same littlefs source as Wisp Boot) holding `ota/s200_firmware_ota.bin` (the Wisp image as `wisp-ota pack-main` packs it, so wisp-ota's guards run on every test image) and `wisp/rescue.bin` (the stock main payload). Start state = "Wisp was installed through the stock OTA path": Wisp in MRAM, flag `0x55555555` still set (the bootloader never clears it, see hardware.md), so the bootloader reinstalls Wisp on every boot until the rescue replaces the staging file.

**Since W22 (rung4.md):** two suites on two bootloaders (safety.md rule 12). `--bootloader stock` is the bundle's own 2.4.0.24; `--bootloader patched` is drdaeman's `87e2d4e0…` on 2.3.2.14 (built from the cache by `apps/wisp-recovery`), what Jan's temples run since W18; it is driven in 0.1 s steps (a longer `RunFor` through the loader's boot window can stall Renode) and is about 30× slower in wall time. `--suite fallback` is the Wisp Boot that rescues: the cases below plus the real app (native-0's) behind it, `native-app-runs` (boots, feeds both watchdogs, answers the case UART) and `native-app-unconfirmed` (never confirms without BLE: three power cuts while it runs, then the rescue ends in stock). `--suite observe` is native-0's observe-only Wisp Boot with its own expected outcome (OBSERVE: the app gets control every boot; Wisp Boot's NOR commands are RDID, RDSR and reads only, from the NOR model's code window; no MRAM write at all; its status block is checked field by field): `obs-native-0` (the real image as install-wisp leaves it, 4 boots, PMIC writes against W21's snapshot, the case-UART queries), `obs-would-rescue` (3 unconfirmed boots recorded and a valid `rescue.bin`: it reports "would rescue" and runs the app), `obs-crash-reset`, `obs-no-feed`, `obs-erased` (resets at once, every boot) and `obs-nor-gd` (a GD25LE256H RDID: reported, no filesystem, the app runs). The platform now has the case link on UART2 (`WispCaseLink`) and the PMIC watchdog on IOM7 (`WispPmicWdt`) in every run, and IOM0–6 as `WispIomTypes` (G2Iom with the submodule types the real app's I2C driver checks).

W22 results on t3-worker, 2026-11-08 (`.wisp-cache/rung3/<bootloader>-<sha8>-<suite>/report.md`):

| Suite | Wisp Boot (`wisp_boot.bin` SHA-256) | Stock 2.4.0.24 bootloader (`ecb91896…`) | Patched bootloader (`87e2d4e0…`) |
| --- | --- | --- | --- |
| observe (native-0's) | `d793a93e02ba18f7…` (8,256 B, the first 64 KiB of native-0) | **6/6 pass** | **6/6 pass** (`obs-native-0` first failed on a harness race, the stop came before the last boot's app was up; fixed and rerun: pass) |
| fallback | `5d2a7be1cd514ad3…` (17,824 B; status block, services v2) | **28/28 pass**: reference, the 25 fault and power-cut cases, `native-app-runs`, `native-app-unconfirmed` (the two real-app cases rerun with the final app: pass) | **reference + `native-app-runs` + `native-app-unconfirmed` pass**; the 25 fault and power-cut cases were not run on this bootloader (about 30 min wall each here). The fallback build is not in native-0; its full patched run is due before native-1 is flashed (rule 12) |

Every real-app run writes the PMIC only as W21's snapshot allows (`pmic_baseline.py`: 0 differences), kicks it at most about 1.1 s apart within a boot, and has no Apollo watchdog bite. Wisp Boot's NOR commands in the observe suite: `9f`, `05`, `13` only.

**Models** (`renode/models/`, MIT, written for this rung; register maps from hal_ambiq's CMSIS `apollo510.h`, protocols from AmbiqSuite's HAL):

| Model          | What it does                                                                                                                                                                                                                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `WispMspiNor`  | MSPI1 (PIO, DMA, command queue) + MX25U25643G behind it (RDID, status/config, WREN, 4-byte mode, reads, page program with NOR AND-semantics, sector/block/chip erase), backed by a file; non-volatile across resets. Program/erase complete instantly, so a power cut lands between two NOR operations |
| `WispBootRom`  | the boot-ROM MRAM helper `nv_program_main2` (key, bounds) and the other ROM entries; logs every MRAM write with the caller's LR                                                                                                                                                                        |
| `WispRstGen`   | SWPOI/SWPOR, AIRCR, watchdog and harness power cuts → machine reset: MRAM and NOR kept, all registers and **all SRAM lost (filled with `0xA5`)** unless a case keeps one range across warm resets (`RetainRange`), restart through the SBL hand-off at `0x410000`; `RSTGEN.STAT` set from the cause |
| `WispStimer`   | Renode's Apollo4 STIMER, plus `RSTGEN.STAT` at `0x4000885C` (inside the STIMER's window)                                                                                                                                                                                                              |
| `WispWdt`      | Apollo510 WDT (CFG/RSTRT/LOCK/COUNT, LFRC dividers, RESEN + `RSTGEN.CFG.WDREN`) on virtual time, LFRC 900 Hz                                                                                                                                                                                          |
| `WispPmicWdt`  | IOM7 with the nPM1300 watchdog (w18 and rung 3): kicks, harness arming or (`ActOnWrites`) the app's own, power-on values on expiry, the PMIC write log with PCs                                                                                                                                        |
| `WispAdc`      | the bootloader's board-detect conversions                                                                                                                                                                                                                                                              |
| `WispUartIdle` | UART0/2/3 with nothing attached (Renode's PL011 kept IRQ 17 asserted under the stock HAL)                                                                                                                                                                                                              |
| `WispProbe`    | harness only: milestones on Wisp Boot addresses, power cuts at a NOR operation count or a milestone, MRAM dump                                                                                                                                                                                         |
| `WispTrace`    | plain register storage for every other range, with access logging to find what a stalled guest polls, and the strict start-up record (with `WispPwrctrl` and `WispClkgen` around g2emu's stubs)                                                                                                      |

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

## stage-0 and the W24 follow-up (diagnostics, strict Renode)

W24 put native-0 on the left temple: it reboot-looped every 10.4 s and said nothing, while every Renode case had passed (docs/wisp/rung4.md, "W24 result and analysis"). This tree adds what the analysis asks for before the next image:

- **Diagnostics in Wisp Boot** (D1, D2; above, "Every boot"): the record, the reset cause, the boot report on the case UART, the PMIC kick at every boot. A Wisp Boot change, so rule 12: rung 3 on both bootloaders (results below).
- **stage-0** (`src/stage0/`, `pnpm nx run wisp-fw:build-native` is native-0's; stage-0 is `scripts/build_native.sh stage-0`, then `scripts/package_native.sh stage-0` copies it to `apps/wisp-recovery/wisp_w18/data/stage-0/`): the observe-only Wisp Boot and a bare-metal app of about 5 KiB at `0x448000`, no Zephyr and no HAL start-up. It feeds the Apollo watchdog and kicks the PMIC's every second, answers the case-UART protocol polled (IDENT, READ blocks 1–4, BOOTREP, RESET; the same codec), measures the LFRC (the watchdog's clock) against the 32 kHz crystal and the core clock, and leaves breadcrumbs. Gates: `check_image --part app`, rule 8, the no-MRAM-write gate over the app, `check_native --bare-app-elf` (no Zephyr, HAL or I2C symbols; its only PMIC code is the fixed kick), wisp-ota's `pack-main`. Not pinned: pinning comes after its review (rung4.md W24b).
- **Renode realism:** the watchdog's LFRC at 900 Hz (`WispWdt.LfrcHz`); `RSTGEN.STAT` (`WispRstGen`, served at `0x4000885C` by `WispStimer`); optional SRAM retention across warm resets (`rstgen RetainRange`, for the record); the PMIC model acting on the app's own arming writes and coming back at the W24 power-on values on expiry (`images/pmic-poweron-w24.json`), with a PC-attributed write log; and the **strict start-up record** (`WispStrict` in `WispTrace.cs`, spies on g2emu's PWRCTRL and CLKGEN stubs): every access Wisp code makes to a register no model acts on, with its PC. `tests/boot/strict.py` fails a case on a write to a power, clock or trim block (RSTGEN, CLKGEN, OTP, MCUCTRL, PWRCTRL beyond the device/memory power bits) unless `tests/boot/strict_allowlist.json` names it with a reason (empty).
- **Where it is checked:** every rung-3 case: Wisp Boot writes the PMIC only with the kick, once per boot, and makes no such strict write. Rung-3 observe: `obs-diag-wdt` (a watchdog reset, then the next boot's record) and `obs-stage-0` (stage-0 end to end, including a RESET and Wisp Boot's boot report after it). `w18-test`: `native-0` and `native-0-recover` also fail on an Apollo watchdog bite, on no app PMIC kick within 3 s of a boot, and on the strict record; `stage-0` installs the committed stage-0 through install-wisp's gate and the real patched loader and watches it with boot-watch's own protocol at the relay's cadence.
- **Results (2026-11-08, Wisp Boot `b54ee856…` observe / `b33da81a…` fallback):** rung 3 observe 8/8 on both bootloaders, fallback 28/28 on stock 2.4.0.24 (on the patched one as listed in rung4.md, "W24b"); `w18-test` passes except `native-0` and `native-0-recover`, which now fail on native-0's 33 writes to unmodelled power, clock and trim registers (its HAL start-up and the SIMO buck enable; the list is in rung4.md). That failure is the finding, not a regression: native-0 is the image that reboot-looped on W24.

## W18: the patched bootloader in Renode (`wisp-fw:w18-test`)

`tests/boot/w18.py` loads the rung-3 platform with UART2 replaced by `renode/models/WispCaseLink.cs`, a lockstep TCP bridge: every temple frame (`5A A5 FF …`) goes to the host and the CPU waits for the host's one answer, like the case relay's G2TX/G2RX. The host is `apps/wisp-recovery/wisp_w18` itself (`SocketLink` instead of `CaseRelayLink`). Cases: both stock bootloaders boot stock 2.4.0.24 (control); the patched one with nobody answering; `loader-hello`; `info-dump`; a full `recover` of the stock app into an erased app region; the same through the case relay's framing (`recover-relay`: `RelayPortLink` over `relay_model.RelayModel`, the code `CaseRelayLink` runs); the same with a power cut at 40 % of the write and a second session; and the MRAM states a cut during the stock app's bootloader copy can leave (k of 38 pages new). Results and limits: [recovery.md, Emulation proof](../../docs/wisp/recovery.md#emulation-proof-renode-pnpm-nx-run-wisp-fww18-test). Two emulation-only shims live in the model: `MveVprShim` (Renode's M55 has no MVE; the loader's trampoline saves and restores VPR) and `PacingShim` (the loader's short FreeRTOS delays drift in Renode, so they return at once). Neither touches what the loader does, only how long it takes in virtual time.

## What Renode lacks (for this and the next rungs)

- **Peripherals are plain storage** outside the models above: GPIO, MCUCTRL, NemaGFX, PDM/I2S, CRC/crypto, security/OTP. Writes are stored, reads return what was written or 0. Since W24 the strict record lists every such access by Wisp code, and the native cases fail on unreviewed writes to power, clock and trim registers: Renode still cannot say what silicon does with them, only that something untested happened.
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
3. ~~Put the real native app behind Wisp Boot~~ done in W22 (native-0, both suites, both bootloaders).

Toward rung 4 (hardware), none of which emulation can answer:

4. Read Wisp Boot's hardware assumptions off the stock image and the glasses: MSPI1 pin mux and clock after the bootloader's hand-off, UART1 state (or build with `WISP_BOOT_LOG=0`), ROM power-up on `MEMPWRSTATUS`, whether the 16 Hz watchdog divider and 8 s window suit the app.
5. Touchpad rescue hold (PSoC on I2C5 `0x0C`) as a Wisp Boot input.
6. ~~Zephyr app: link at `0x448000`, feed the watchdog, confirm after BLE + `HELLO`~~ done in W22; still open: clear the flag after a confirmed new install (R4-3, G17).
7. ~~Patch the HAL so the EM9305 update/recovery/trim code is compiled out and `apollox_blue.c` forces `skip_fw_update = true`~~ done 2026-11-06 ([third_party/ambiq](third_party/ambiq/README.md)); Bluetooth is on and `check_rule8.py` passes on the image. What remains toward a native boot: [Bluetooth, still missing](#still-missing-before-a-first-native-boot).
8. Drivers still to write: the GX8002 mic path (UART3 control + I2S0 RX, never its firmware), PDM0, the buzzer (TIMER7 PWM), the magnetometer behind the IMU, the NOR littlefs (storage HAL), the inter-temple UART. A GPIO interrupt model in Renode would let the attention and data-ready paths run there too.
