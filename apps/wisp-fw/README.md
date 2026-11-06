# wisp-fw — Wisp native firmware (Apollo510B)

The native target of [Wisp](../../docs/wisp/README.md): Zephyr from Ambiq's fork (decision W11) on one G2 temple, emulated in Renode with g2emu's Apollo510 platform (W15). **Milestone M0: build skeleton + Renode boot. Nothing here has run on glasses, and nothing here can talk to hardware** — the board defines no flash runner, and no script uses J-Link, SWD or BLE.

Read [safety.md](../../docs/wisp/safety.md) before changing anything that ends up in the image.

## Use

Everything runs on t3-worker (NixOS) as a normal user. The flake in this directory pins the toolchain; the scripts enter it themselves (`nix develop`), so plain `pnpm nx` is enough.

| Target                      | What it does                                                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `pnpm nx run wisp-fw:setup` | west workspace in `.wisp-cache/west/` from [west.yml](west.yml) (every repo pinned by SHA; about 30 s first time, no-op after) |
| `pnpm nx run wisp-fw:build` | `west build -b wisp_g2` into `.wisp-cache/build/wisp-fw/`, then the post-build gates; fails if any gate fails                  |
| `pnpm nx run wisp-fw:sim`   | boots `zephyr.bin` in Renode for 10 s of virtual time and streams UART1 (`scripts/sim.sh [seconds]`)                           |
| `pnpm nx run wisp-fw:test`  | Wisp Boot host tests, gate unit tests, Renode boot test (asserts on UART1), rule 8 negative builds (about 1 min)               |

Toolchain (from `flake.lock`, nixos-26.05 at `7dcdd87`): gcc-arm-embedded 15.2.rel1 (Zephyr variant `gnuarmemb`), CMake 4.1, Ninja, dtc, west 1.5, Renode 1.16.1. Workspace: `AmbiqMicro/ambiqzephyr` `ambiq-stable` @ `89c8a36` (Zephyr 4.3.0) plus only `ambiqhal_ambiq` @ `d3278ec`, `cmsis`, `cmsis_6` and `mbedtls` (the last only for the BT negative build). To move the pin, edit `west.yml`, rerun setup, build, test. A from-scratch setup in an empty cache (`WISP_CACHE_DIR=…`) rebuilt a byte-identical `zephyr.bin` (the git revision string is embedded, so compare at the same commit).

CI: the GitHub workflow (macOS, no nix) runs `nx run-many -t build test` and would fail on this project; it needs `--exclude=wisp-fw` there (not changed in this PR: the push token has no `workflow` scope). This project is green on t3-worker.

## Layout

```
boards/even/wisp_g2/   out-of-tree board: Apollo510B, code partition at 0x438000, UART1 console
src/main.c             banner + heartbeat (M0 app)
src/hal/               the HAL boundary for Wisp core: display, input, sensors, audio, power,
                       storage, link — declarations only, no Zephyr dependency
src/boot/wisp_boot.*   Wisp Boot design stub: the boot decision as a pure function (host-tested,
                       not linked into the image)
cmake/rule8.cmake      configure-time rule 8 gate
scripts/               setup/build/sim/test, check_image.py, check_rule8.py, wisp_layout.py
renode/                wisp_g2.repl (derived from g2emu) + wisp_g2.resc
third_party/g2emu/     three g2emu C# peripheral models (MIT, unmodified), see its README
tests/                 boot/ (C host tests), scripts/ (gate unit tests), sim/ (UART assertions),
                       rule8/ (negative builds: BT on, BT "allowed" on the unpatched fork, canary)
```

Wisp core hook: `-DWISP_WITH_CORE=ON` (optionally `-DWISP_CORE_DIR=…`, default `packages/wisp-core`) adds the core's CMake project and links `wisp_core` into the app with Zephyr's flags; checked against `t3/wisp-core` @ `b40f049`, which cross-compiles cleanly for the M55 (its `-Wpedantic -Werror` needed Zephyr's headers passed as system includes — done in `CMakeLists.txt`).

## What boots

`wisp_g2` image: 53.7 KB, linked at `0x438000` (vector table first; initial SP `0x20081740` in SSRAM, reset vector `0x0043a375`). Renode loads the flat `zephyr.bin` at `0x438000` — exactly what the Even bootloader would install — and starts it the way the bootloader hands off (VTOR = `0x438000`, MSP = vector 0, PC = vector 1). UART1 from a `wisp-fw:test` run:

```
*** Booting Zephyr OS build 4.3.0 ***

*** Wisp native 0.0.0-m0 (1d0d616da1-dirty) ***
wisp: board wisp_g2, Zephyr 4.3.0, image @ 0x438000
wisp: M0 skeleton, bluetooth off (safety rule 8)
wisp: heartbeat 1 uptime 1000 ms
wisp: heartbeat 2 uptime 2001 ms
wisp: heartbeat 3 uptime 3002 ms
wisp: heartbeat 4 uptime 4005 ms
wisp: heartbeat 5 uptime 5007 ms
```

The kernel ticks off the STIMER (Renode's Apollo4 system-timer model is register-compatible enough for `ambiq_stimer.c`); heartbeats drift about 1–2 ms per second of virtual time. No Renode warnings at log level 3.

## Board `wisp_g2`

- **MRAM partitions** (flash0 starts at `0x410000`, so offsets are relative to it): `even-bootloader` `0x410000–0x438000` read-only (the 32-byte EVEN preamble at `0x437FE0` sits at its end and is added by wisp-ota, never the linker), `wisp` `0x438000–0x7F8000` = `zephyr,code-partition` (3840 KiB; the linker region ends exactly at the ceiling), `even-nv` `0x7F8000–0x800000` read-only (update flag at `0x7FE000`, bonds).
- **Enabled:** UART1 at 115200 (console), STIMER, pinctrl. Watchdog, PM and everything else off.
- **Disabled, with TODOs from hardware.md:** I2C4 (ICM-45608 `0x69`, magnetometer `0x1E`), I2C5 (PSoC 4000T `0x0C`), IOM6 SPI (EM9305 — see rule 8), I2C7 (nPM1300 `0x6B` or BQ25180 `0x6A` + BQ27427 `0x55`, OPT3007 `0x45`), MSPI0 (panel), MSPI1 (NOR, instance unconfirmed), PDM0, I2S0 (GX8002), GPU; buzzer GPIO145, inter-temple and case UARTs as comments.
- **Unverified on the G2:** UART1 pads (the evb's P12/P14 are used as placeholders), STIMER clock source. Both must come from the stock image before anything runs on glasses.
- `SOC_APOLLO510B_EM9305_EXTREF_INIT` defaults to n on this board (see below).

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

## Wisp Boot (design stub)

`src/boot/wisp_boot.{h,c}`: the decision only — record (magic, version, attempts, fallbacks, CRC-32) in, `RUN_APP` / `FALLBACK_TO_STOCK` / `RUN_APP_DEGRADED` out. Fallback after 3 unconfirmed boots or on the rescue hold; never halts (no valid rescue image, or 2 fallbacks in a row that came back, → run the app anyway); a corrupt record counts as a fresh install. `tests/boot/` covers the sequences and an exhaustive sweep of small states under ASan/UBSan. Not linked into the image; the entry is still Zephyr's reset vector.

## What Renode lacks (for this and the next rungs)

- **Peripherals are plain memory** outside the three g2emu models used (CLKGEN/RTC, PWRCTRL, UART1) and Renode's Apollo4 STIMER/CTIMER models: GPIO, MCUCTRL, IOM (I2C/SPI), MSPI, NemaGFX, PDM/I2S, CRC/crypto, **watchdog** (`0x40024000` — never bites), security/OTP. Writes vanish, reads return what was written or 0.
- **No power management:** `CONFIG_PM` is off in M0; deep sleep, power domains beyond the PWRCTRL status mirror, and wake-up sources are not modelled.
- **No EM9305** and no HCI SPI, so no BLE in emulation at all (fine for M0, needed for nothing before M6).
- **No NOR flash / littlefs:** g2emu's MSPI model is a readiness stub, XIP (`0x80000000`) is plain memory.
- **No SBL / boot ROM:** nothing at `0x400000`; the machine starts at whatever the script sets. MRAM is ordinary RAM in Renode (writes just land), so MRAM programming is not modelled — the real path goes through Apollo510 boot-ROM helpers (`am_hal_mram_*`), to be confirmed.
- **Reset semantics unverified:** what `SYSRESETREQ` / a watchdog reset does to the machine, and whether memory survives it, has not been tested.
- **UART:** g2emu's UART1 model completes TX instantly and only raises the interrupts the stock HAL uses; the polled console works, an interrupt-driven console is untested.

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

## Next steps toward rung 3 (Wisp Boot fault tests with the real Even bootloader)

1. **Load the stock chain in Renode.** Take the pinned stock EVENOTA bundle from `.wisp-cache/` (never committed), extract the bootloader component (type 1) with wisp-ota and load it at `0x410000`; there is no SBL image, so start at the bootloader's own vector table (VTOR `0x410000`). Also extract the stock main image (type 0) for `wisp/rescue.bin`.
2. **NOR model.** A Renode model of the MX25U25643G behind MSPI (command mode: read, page program, sector erase, status) or confirm the bootloader only reads through XIP. g2emu's `G2Mspi` is only a readiness stub.
3. **littlefs image.** Build `ota/s200_firmware_ota.bin` + `wisp/rescue.bin` into a littlefs image at NOR `0x1400000` (littlefs-python, BSD); find the geometry (block size, count, `lfs` config) in the stock bootloader.
4. **MRAM programming.** Find how the bootloader writes MRAM (boot-ROM helper calls?) and model it: hook the ROM entry points or add a programmable-MRAM peripheral, so an install really rewrites `0x438000…`.
5. **Update-flag record.** Pin down the 16-byte record at `0x7FE000` (safety.md "Still to verify") by tracing the bootloader in Renode.
6. **Reset + watchdog models.** WDT at `0x40024000` that resets the machine; define what a reset preserves (retained SRAM for the boot record) and route it back through `0x410000`.
7. **Wire Wisp Boot in.** Make `wisp_boot.c` the first stage at `0x438000` (own vector table, app after it) with storage HAL calls for record, rescue copy and flag write; keep the decision function as is.
8. **Fault harness.** Robot/monitor scripts that inject: app hangs (no confirm), crashes at random instruction counts, power cut (machine reset) during the rescue copy and during the bootloader's install, corrupt record, missing/corrupt `rescue.bin`, rescue hold. Exit check: 100 % of injected faults end in a stock install (rung 3).
9. **Before M6 (not rung 3):** patch the HAL so the EM9305 update/recovery/trim code is compiled out and `apollox_blue.c` forces `skip_fw_update = true`; `CONFIG_WISP_BT_ALLOWED` stays off until `check_rule8.py` passes on that build. Read the G2 pin map (UART1 pads, IOM pins, clocks) from the stock image.
