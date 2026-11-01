# Spike: Even app APK recon (`com.even.sg`)

Status: done 2026-11-01. Goal: answer the three open protocol questions from the shipped Even app — the second display layer, notifications, and the map view — instead of guessing them.

## What we did

- The Even app has an Android build, `com.even.sg` (Google Play, 10K+ downloads). Pulled the APK (85.8 MB) and unpacked it.
- It is Flutter + Mapbox (routing) + HERE SDK (map tiles), packed with **Tencent Jiagu** (`assets/libjiagu_a64.so`). The `com.even.*` classes — the BLE and protobuf code — are encrypted inside the dex, so a static decompile stops there. No `g2.*.proto` files ship in the APK; the only `.proto` files present are Google/Firebase/cloud ones.

## Findings

### Second display layer: the model is real, the spawn command is unmapped

The firmware's UI service table (`g2.service_id_def.SID`, decoded in g2-kit) separates two planes:

| plane                  | SIDs                                                                    |
| ---------------------- | ----------------------------------------------------------------------- |
| background (content)   | `DASHBOARD` 1, `NAVIGATION` 8, `EVENHUB` 224                            |
| foreground (popup)     | `MEUN` 3, `NOTIFICATION` 4, `EVEN_AI` 7, `SYSTEM_ALERT` 33, `SYSTEM_CLOSE` 34 |

So the Even app really does draw content below and popups above. What we still don't have is the EvenHub `Cmd` that spawns a foreground page above the running background one — g2-kit's own notes say the notification/animation/widget-binding commands are unmapped.

### Notifications: the control channel is decoded, the content push is not

`g2.notification` is settings, not the payload: `NotificationControl` (`notifEnable`, `autoDispEnable`, `dispTime`, `avoidDisturbEnable`) and `NotificationIOS` (`appID` + `displayName`, the per-iOS-app whitelist). Showing an actual title/body is a foreground app (SID 4); the `Cmd` that pushes its content is still unmapped.

### Map view: fully decoded, and the phone routes with Mapbox

`g2.navigation` (sid `0x08`) is complete in g2-kit / even-g2-protocol:

- `Navigation_Cmd_list`: heartbeat, request/response location list, start-up, basic info, mini map, max map, recalcs, exit, plus the OS→app events (menu start-up, location selected, exit, review changed, compass changed / calibrate).
- `extend_info_msg`: `directionSignIndex` (the turn arrow), `distance`, `roadName`, `spendTime`, `remainDistance`, `etaTime`, `speed`, `navigateWorkMethod`.
- Mini and max map stream as bitmaps: `mapSessionId`, `mapTotalSize`, `compressMode`, `mapFragmentIndex`, `mapFragmentPacketSize`, `mapRawData` (fragmented), and `rotationAngle` / `miniMapBorderEn` on the max map.
- The phone routes with **Mapbox** (`com.mapbox.navigation`), so the glasses only ever receive the arrow + text + bitmaps, never the route.

## What this changes

- The "second layer" is no longer a guess: the layer model is in the firmware's service table. It stays open only for the spawn command.
- The navigation plan can rely on the decoded proto instead of re-decoding it.

## Getting the last two Cmds (foreground spawn + notification content)

Two ways, in order of effort:

1. **BLE capture** (fastest, no new tooling): run the official app and capture the sid `0xe0` traffic while it opens a popup or shows a notification. g2-kit already has the envelope + protobuf scaffolding.
2. **Runtime dex dump** (if we want the app's own Java/Kotlin logic): Jiagu decrypts the real classes in memory at launch, so the reliable route is a runtime dump, not a static one — see below.

### Unpacking Jiagu (reference)

Jiagu decrypts the real dex and the real native lib in memory at launch. To get them:

- Rooted device, or a Magisk-patched emulator **with KVM** (a software-rendered emulator is too slow to be useful).
- `pip install frida-tools`, push `frida-server`, then `frida-dexdump -U -f com.even.sg` dumps every dex loaded into memory, including the decrypted `com.even.*` classes.
- The native lib can be dumped from `/proc/<pid>/maps` + `dd`, or hooked with Frida once the real `.so` is mapped.
- Jiagu usually adds anti-debug / anti-emulator / root checks — hook `android.os.Debug.isDebuggerConnected`, the `/proc/self/maps` read, and the emulator-property checks first.

Our CI host has no `/dev/kvm` (no nested virtualization), so the emulator route runs on a Mac or a real device, not here.
