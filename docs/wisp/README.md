# Wisp — open firmware and SDK for the Even G2

Wisp is a replacement firmware for the Even Realities G2 glasses plus an SDK for phone apps. It is **generic**: Lotti is one app on top of it, not the reason for its shape. Anyone should be able to build a glasses app on Wisp without hacks.

Status: M0 foundation landed (2026-11-06): `wisp-core` (C, 131 golden vectors), `wisp-sdk-ts`, `wisp-ota` (all 18 stock releases verified and repacked offline), `wisp-fw` (Zephyr skeleton booting in Renode). M1 in review: the display engine in `wisp-core` (layers, compositor, resources, text, animation, input) and `apps/wisp-sim` (the core in WebAssembly, a WebSocket link, a browser viewer, an SDK example with an end-to-end test). Protocol at draft 0.2. M2 (rung 1) passed on the left temple on 2026-11-06: stock 2.4.0.24 repacked by `wisp-ota`, flashed over BLE from the Lotti app and back to pure stock (hardware log in safety.md). See [safety.md](safety.md) before touching hardware.

- [Protocol v0](protocol.md) — the wire contract (firmware ⇄ SDK)
- [Safety policy](safety.md) — brick rules and the flashing ladder
- [Hardware reference](hardware.md) — what's in the glasses, with sources
- [Host mode](host-mode.md) — running the core inside stock 2.2.6.10 (rung 2): where to hook, the lease, the hook ladder

## Why

The stock firmware is a product, not a platform. Apps get a fixed set of widgets (12 containers, one input container, 576×288 of a 640×480 panel), a slow image path (about 9 fps), text limits, and no direct access to most sensors. Lotti works around this with tricks; so does every other third-party app. Wisp turns the glasses into a thin, fast, well-documented display-and-sensor device that the phone app fully controls.

## Goals

1. **Unopinionated.** The firmware ships no UI: no widgets, menus, fonts, or fixed gestures. Apps define everything, and can push and persist their own assets (images, fonts, animations) on the glasses.
2. **Fast pixels.** Compressed image transfer (RLE4, LZ4, delta frames), a resource cache that skips re-uploads by hash, layers with free move/scroll, and on-glass animations and tweens that cost no radio traffic per frame.
3. **All the hardware.** Wear detection, brightness and ambient light, mic (PCM and LC3), buzzer, IMU, magnetometer, touch (raw and gestures), battery and charging, temperature. Full 640×480.
4. **Light on both batteries.** Everything off by default, batched sensor data, link profiles (idle / interactive / bulk), display off when unworn, nothing running after the phone goes away.
5. **Updates over Bluetooth.** From the phone, including the very first install over stock firmware, with no cable.
6. **An SDK for everyone.** Small, documented, no Lotti concepts in it: TypeScript first (Web Bluetooth, Node, React Native), Swift next, Kotlin welcome.
7. **Never brick a temple.** See [safety.md](safety.md). This goal wins every conflict.

## Non-goals (for now)

- The R1 ring's firmware (signed, separate problem). The ring's events still reach apps once the glasses forward them.
- The charging case firmware, the touch controller (PSoC), the voice codec (GX8002) and the BLE controller (EM9305) firmware: Wisp only replaces the Apollo510 main app and keeps every other component stock.
- An app store or app runtime on the glasses. Apps run on the phone.

## Architecture

```
 phone                                        glasses (each temple)
┌──────────────────────────┐                 ┌───────────────────────────────────────────┐
│ app (Lotti, yours, …)    │                 │ Wisp core  (portable C, no hardware deps) │
│ wisp-sdk                 │  Wisp protocol  │  session · frames · compositor · resources │
│  ├ protocol codec        │◀═══════════════▶│  animation · text · input · sensors · audio│
│  ├ image encoder         │   BLE (GATT /   ├───────────────────────────────────────────┤
│  ├ font baker            │   L2CAP)        │ HAL  (one per target)                     │
│  └ transports            │                 │  native: Apollo510 drivers                │
└──────────────────────────┘                 │  host:   calls into stock firmware        │
            │ WebSocket                      │  sim:    desktop / WASM, SDL or canvas    │
            ▼                                └───────────────────────────────────────────┘
   wisp-sim (same core on the desktop)
```

The heart of the design: **the core is one portable C library**, and everything hardware-specific sits behind a small HAL. The same core runs in three places:

| Target        | What it is                                                                                                                                       | When                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| **sim**       | the core on Linux/macOS (and WASM in a browser), panel drawn in a window or canvas, link over WebSocket                                          | now — apps and SDK are built against it before any flash                                  |
| **host mode** | the core appended to the stock firmware; stock boots, stock BLE and stock OTA stay untouched; Wisp runs only while a phone session holds a lease | first on real glasses (ladder rung 2) — low brick risk, real throughput and power numbers |
| **native**    | Wisp Boot + the core + Apollo510 drivers, nothing from stock in MRAM                                                                             | the actual goal (rung 4), only after SWD recovery works                                   |

Apps never see the difference: the protocol and SDK are the same; `HELLO` caps tell what the target supports.

### Native firmware layout

| Piece                      | Where                               | Job                                                                                                                                                                   |
| -------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ambiq SBL, Even bootloader | `0x400000–0x438000`                 | stock, never touched                                                                                                                                                  |
| **Wisp Boot**              | start of the main app at `0x438000` | boot counter, confirm check, fallback-to-stock through the Even bootloader ([safety.md](safety.md#fallback-to-stock-designed-into-native-mode)), then jump to the app |
| Wisp app                   | after Wisp Boot, ≤ `0x7F8000`       | RTOS, drivers, BLE host, Wisp core                                                                                                                                    |
| NOR littlefs               | external flash                      | `ota/s200_firmware_ota.bin` (staging, used by the Even bootloader), `wisp/rescue.bin` (stock main image), `wisp/res/<app>/…` (persisted resources)                    |

Native updates use the same staging mechanism as stock: the app receives the image, verifies it, stages it, writes the flag and resets; the Even bootloader installs it. No second install path to get wrong.

## Decisions

| #   | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| W1  | Replace only the Apollo510 main app; keep the SBL, the Even bootloader and every other chip's firmware stock                                                                                                                                                                                                                                                                                                                                                                                                                               | ✅ decided                                |
| W2  | Three targets, one portable C core behind a HAL: sim, host mode, native                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | ✅ decided                                |
| W3  | Order: sim + SDK first, then host mode on hardware, then native. Native only after SWD recovery is proven ([ladder](safety.md#the-ladder))                                                                                                                                                                                                                                                                                                                                                                                                 | ✅ decided                                |
| W4  | Native safety net: Wisp Boot falls back to a stock image staged in littlefs, installed by the Even bootloader                                                                                                                                                                                                                                                                                                                                                                                                                              | ✅ designed; ⏳ verify in Renode (rung 3) |
| W5  | Own wire protocol ([protocol.md](protocol.md)): fixed little-endian structs, append-only, capability bits; byte-stream frames with CRC-16, byte credits and resync                                                                                                                                                                                                                                                                                                                                                                         | ✅ draft 0.1                              |
| W6  | Display model: layers with free move/scroll/alpha, draw into layer buffers, tear-free `COMMIT`; on-glass animations and tweens                                                                                                                                                                                                                                                                                                                                                                                                             | ✅ draft                                  |
| W7  | Pixels: 4 bpp; codecs RAW4, RLE4, LZ4, LZ4 over RLE4, XOR delta frames. No H.264 in v0 (heavy, patent notice); possible later as an extension                                                                                                                                                                                                                                                                                                                                                                                              | ✅ decided                                |
| W8  | Assets are app-owned resources, hash-addressed (upload skipped when the hash is present), optionally persisted per `app_id`. No built-in fonts                                                                                                                                                                                                                                                                                                                                                                                             | ✅ decided                                |
| W9  | Everything off by default; a session that times out stops everything it started                                                                                                                                                                                                                                                                                                                                                                                                                                                            | ✅ decided                                |
| W10 | Licenses: Wisp is MIT. Port from MIT/BSD/Apache sources (openCFW docs, webflasher, g2emu, liblc3, LZ4); read GPL sources (g2flash, faceclaw) for facts only, never copy code                                                                                                                                                                                                                                                                                                                                                               | ✅ decided                                |
| W11 | Native base: **Zephyr from Ambiq's fork** (`AmbiqMicro/ambiqzephyr`, branch `ambiq-stable`, board `apollo510b_evb` as the template): the only Zephyr with Apollo510B + EM9305 HCI on IOM6, power management, MRAM flash, PDM, MSPI, and in-tree nPM1300 / BQ25180 / BQ27427 / OPT3001 drivers (ICM-45608 needs a small addition). Fallback if Even's EM9305 firmware won't talk to `hci_ambiq`: AmbiqSuite 5.x + FreeRTOS + Cordio, the stock stack. Wisp Boot is our own tiny stage, not MCUboot: installs go through the Even bootloader | ✅ decided (2026-11-05)                   |
| W12 | Lives in the Lotti monorepo for now (`packages/wisp-*`, `apps/wisp-*`), with no dependency on Lotti code; moves to its own repository once protocol 0.x settles                                                                                                                                                                                                                                                                                                                                                                            | ✅ decided                                |
| W13 | SDK order: TypeScript (core + Web Bluetooth + Node + sim transport) first, Swift second (Lotti needs it), Kotlin later                                                                                                                                                                                                                                                                                                                                                                                                                     | ✅ decided                                |
| W15 | Emulation: Renode with g2emu's Apollo510 platform (MIT) for the native skeleton, Wisp Boot fault tests and the real Even bootloader                                                                                                                                                                                                                                                                                                                                                                                                        | ✅ decided                                |
| W16 | Host mode is based on stock **2.2.6.10**: openCFW documents exactly that build, and it leaves 399 KiB below the `0x7F8000` ceiling (2.3.2.14 leaves 9.3 KiB, too little for the core). Glasses don't block downgrades. Revisit if 2.2.6.10 lacks something we need. **Reopened 2026-11-06:** the temples run 2.4.0.24, and 2.2.6.10 lacks the GD25LE256H NOR driver (see [host-mode.md](host-mode.md#22610-vs-the-installed-24024-2026-11-06))                                                                                             | 🔄 reopened (2026-11-06)                  |
| W14 | `wisp-ota`: our own EVENOTA packer/verifier in TypeScript (so a phone app can install Wisp over stock with no cable), every brick guard hard-coded, main-only bundles, CRCs cross-checked against the C implementation                                                                                                                                                                                                                                                                                                                     | ✅ decided                                |

## Repository layout

```
docs/wisp/              this document, protocol, safety, hardware
packages/wisp-core/     portable C: protocol, frames, compositor, codecs, resources, … + host unit tests
packages/wisp-proto/    golden vectors (shared test data for every implementation)
packages/wisp-sdk-ts/   TypeScript SDK
packages/wisp-sdk-swift/ Swift SDK (later)
apps/wisp-sim/          desktop + WASM simulator (core + sim HAL)
apps/wisp-fw/           firmware targets: native (Apollo510) and host mode, Renode scripts
packages/wisp-ota/      EVENOTA inspector, packer and verifier (TS library + CLI; the SDK reuses it for
                        the first install over stock, straight from the phone)
```

All Nx projects, runnable with `pnpm nx run-many -t build test` on Linux (t3-worker). Firmware builds need no hardware.

## Milestones

| #   | Milestone                                                                                                                                                                                                                            | Done when                                                    | Needs hardware?    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ | ------------------ |
| M0  | **Foundation** — docs, protocol draft, `wisp-core` frames + codecs + session with tests, golden vectors, TS SDK core passing the vectors, `wisp-ota inspect/verify` on a stock bundle, Apollo510 firmware skeleton booting in Renode | ✅ done 2026-11-06 (PRs #44–#47)                             | no                 |
| M1  | **Simulator** — `wisp-sim` runs the core with layers, resources, text, animation; TS SDK drives it over WebSocket; example app                                                                                                       | ⏳ in review: SDK example draws, animates, reacts to touches | no                 |
| M2  | **Rung 1** — stock repacked by `wisp-ota`, flashed to the left temple and back                                                                                                                                                       | round trip logged in [safety.md](safety.md#hardware-log)     | yes, with Jan's go |
| M3  | **Host mode** — the core inside stock (rung 2): display + resources + input over the real link; throughput and battery measured                                                                                                      | SDK example runs on real glasses                             | yes                |
| M4  | **Wisp Boot proven in Renode** (rung 3)                                                                                                                                                                                              | fault injection: every fault ends in stock                   | no                 |
| M5  | **SWD access** — pads found, read-only attach, INFO0 dumped                                                                                                                                                                          | a documented recovery procedure                              | yes                |
| M6  | **Native** (rung 4) — drivers, BLE, update service; first native boot on the left temple                                                                                                                                             | ladder exit check                                            | yes                |
| M7  | **Swift SDK + Lotti on Wisp**                                                                                                                                                                                                        | Lotti uses Wisp when present, stock otherwise                | yes                |

## Work coordination

Work runs in parallel T3 threads, each in its own worktree on **t3-worker** (Linux, mostly idle) and each on a branch stacked on `t3/custom-g2-firmware` (this document, PR #43). Only the **MacBook Air** can deploy to the iPhone; it is used only for iOS/Swift work and on-device BLE tests. Threads coordinate through this repository: the protocol file is the contract, golden vectors are the shared truth, and each thread updates the milestone table when it lands.

Threads never flash glasses. Flashing is a manual step with Jan's go, following [safety.md](safety.md).
