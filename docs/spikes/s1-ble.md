# Spike S1: talk to the G2 over BLE from iOS

Status: code done, unit tests green, **hardware test pending**.
Goal: "Hello from Lotti" on the G2 from our own app, and decisions D6 (BLE layer) and D7 (Xcode project).

## Result

- `packages/lotti-kit`: Swift package. `GlassesLink` protocol plus `G2Link` (CoreBluetooth) and pure-Swift packet encoding with golden-byte tests.
- `apps/ios`: SwiftUI app. Scan, connect, status, "Send hello", reconnect to the last glasses on launch.
- Nx: `pnpm nx run-many -t build test`; `pnpm nx run ios:run-device` builds, installs and launches on a connected iPhone with the console streamed.

## D6: build our own BLE layer

**Decision: build our own small layer in LottiKit, using the open projects as protocol references.** Don't adopt an SDK for now.

| Project                                                                                                                                       | License                                   | Language                 | Last push  | G2 coverage                                                                      | Use from Swift                                                         |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | ------------------------ | ---------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| [MentraOS](https://github.com/Mentra-Community/MentraOS) iOS SDK ([SPM mirror](https://github.com/Mentra-Community/mentra-bluetooth-sdk-ios)) | Apache-2.0                                | Swift                    | 2026-10-31 | Broad: auth, text, bitmaps, touch, LC3 mic, menu, dashboard, notifications       | Real SPM package, but pre-release tags only (`3.4.0-dev.N`)            |
| [OpenEvenSdk](https://github.com/Thepizzapie/OpenEvenSdk)                                                                                     | README says MIT; no LICENSE file          | Swift, Python, Kotlin    | 2026-06-15 | Partial: auth, heartbeat, text, containers, taps. Mic removed                    | App sources, no package. Good `PROTOCOL.md`                            |
| [g2-kit](https://github.com/Commute773/g2-kit)                                                                                                | MIT                                       | TypeScript (Bun + noble) | 2026-04-16 | Framing, EvenHub protobufs, images, LC3, events                                  | Port needed. Best protocol docs (`ble/docs/`)                          |
| [even-g2-protocol](https://github.com/ithinkthisiscool/even-g2-protocol)                                                                      | MIT (README / pyproject; no LICENSE file) | Python (bleak)           | 2026-10-13 | Auth, dashboard, text, audio, IMU, settings, files. Marks what is live-confirmed | Port needed. Golden-byte tests we reuse                                |
| [even-realities-app-template](https://github.com/r4stl1n/even-realities-app-template) (unofficial)                                            | MIT                                       | Swift                    | 2026-07-24 | G1, G2, R1                                                                       | Xcode app; its BLE stack is a fork of MentraOS                         |
| [evenhub-templates](https://github.com/even-realities/evenhub-templates) (official)                                                           | MIT                                       | TypeScript               | 2026-08-07 | Through the Even Hub SDK                                                         | Not usable: web plugins that run **inside** Even's app, not direct BLE |

Also seen: [mmirman/open-g2-companion](https://github.com/mmirman/open-g2-companion) (GPL-3.0, so don't copy) and [i-soxi/even-g2-protocol](https://github.com/i-soxi/even-g2-protocol) (original protocol research, no license; reference only).

Why our own:

- **Small scope.** What Lotti needs (connect, auth, text/containers, heartbeat, later touch events and mic) is about 600 lines of Swift today. MentraOS's SDK is about 56k lines built around their multi-device model.
- **MentraOS concerns:** pre-release only, analytics hooks (`bluetooth_sdk_glasses_identified`), an ObjC core target, and their device model in our hot path.
- **We own the renderer.** The UI schema → containers mapping (D5) sits right on top of the link. Owning the link keeps that mapping simple and testable.
- **Interface seam.** The app only sees `GlassesLink`. If our layer falls behind, a MentraOS-backed implementation can replace `G2Link` without touching the app.

Rules for reuse: MentraOS (Apache-2.0) code may be ported with attribution. g2-kit (MIT) likewise. Don't copy from GPL or unlicensed projects. The current code is written from scratch; protocol facts are credited in comments.

Revisit if: the mic/LC3 or image pipeline gets expensive to build. Then port those parts from MentraOS's `G2.swift`.

## D7: plain checked-in Xcode project

**Decision: a plain `Lotti.xcodeproj`, checked in, using Xcode 16+ synchronized folders.** No XcodeGen, no Tuist.

|                                          | XcodeGen                  | Tuist                          | Plain project                                               |
| ---------------------------------------- | ------------------------- | ------------------------------ | ----------------------------------------------------------- |
| Extra tool to install (CI and every Mac) | yes (not installed here)  | yes (not installed here)       | no                                                          |
| Adding a file                            | regenerate                | regenerate                     | nothing: synchronized folders pick it up                    |
| `.pbxproj` merge conflicts               | none (generated, ignored) | none                           | rare: the file only changes when targets or settings change |
| Works from CLI / Nx                      | `xcodegen && xcodebuild`  | `tuist generate && xcodebuild` | `xcodebuild`                                                |

With synchronized folders, the old reason for generators (every new file edits the `.pbxproj`) is gone. The project has two targets (app + unit tests) and references `packages/lotti-kit` as a local Swift package, so all real code lives in the package anyway. Revisit when there are several app targets (widgets, watch, share extension) and settings start to repeat. Then Tuist.

## Protocol notes (what LottiKit does)

Each G2 arm is its **own BLE peripheral**, advertising as `Even G2_<pair>_<L|R>_<mac tail>`. Both arms are connected. Commands go to the **right arm**, which also sends replies and events; the left arm mostly stays silent.

GATT: one UUID base `00002760-08C2-11E1-9073-0E8AC72Exxxx`. Control write `…5401` (write without response), control notify `…5402`. Mic is on `…6402` (not used yet).

Packet: `AA 21 <seq> <len> <total> <num> <sid> <flag> <chunk…> [CRC]`

- `seq` is the same on every packet of one message: the firmware reassembles by it.
- `len` counts the bytes after the header, CRC included.
- CRC-16/CCITT-FALSE over the whole payload, little-endian, at the end of the last packet.
- `flag` is `0x20` for requests, `0x00` for device config (sid `0x80`).
- Replies start `AA 12` and echo the request's **magic** (protobuf field 2). Keep magics in 100–255: the firmware only reliably acks single-byte values.

Connect sequence:

1. Connect both arms, discover services, subscribe to `…5402` on both.
2. sid `0x80` auth `{1:4, 2:magic, 3:{1:true, 2:3 (iOS)}}` to the left arm, then the right arm. The right arm must reply.
3. sid `0x80` pipe role change: right arm is the command arm. Then time sync (local time sent as UTC) to both arms. (From MentraOS.)
4. sid `0x01` session prelude (fixed bytes, magic 156). Without it the glasses ignore EvenHub commands.
5. sid `0xE0` heartbeat (Cmd 12) every 4 s, or the glasses end the session.

Text: the first "Send hello" sends Cmd 0 (CreateStartUpPage) with one full-screen 576×288 text container named `lotti`. Later sends use Cmd 5 (text update). A page can only be created once per session.

Known gotchas (from g2-kit and even-g2-protocol): container names ≤ 14 characters; ~1000 bytes of text per container; don't interleave packets of two messages on one arm; sid `0x80` has dangerous developer fields (stick to the ones above).

## Hardware log

To fill in during the hardware test: firmware version, which services the arms expose, whether iOS asked to pair, what the auth reply looked like.
