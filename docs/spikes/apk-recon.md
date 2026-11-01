# Spike: Even app APK recon (`com.even.sg`)

Status: done 2026-11-01. Goal: answer the three open protocol questions from the shipped Even app — the second display layer, notifications, and the map view — instead of guessing them.

## What we did

- The Even app has an Android build, `com.even.sg` (Google Play, 10K+ downloads). Pulled the APK (85.8 MB) and unpacked it.
- It is Flutter + Mapbox (routing) + HERE SDK (map tiles), packed with **Tencent Jiagu** (`assets/libjiagu_a64.so`). The `com.even.*` classes — the BLE and protobuf code — are encrypted inside the dex, so a static decompile stops there. No `g2.*.proto` files ship in the APK; the only `.proto` files present are Google/Firebase/cloud ones.

## Findings

### Second display layer: confirmed, and the spawn command is already mapped

The firmware's UI service table (`g2.service_id_def.SID`, decoded in g2-kit) separates two planes:

| plane                  | SIDs                                                                    |
| ---------------------- | ----------------------------------------------------------------------- |
| background (content)   | `DASHBOARD` 1, `NAVIGATION` 8, `EVENHUB` 224                            |
| foreground (popup)     | `MEUN` 3, `NOTIFICATION` 4, `EVEN_AI` 7, `SYSTEM_ALERT` 33, `SYSTEM_CLOSE` 34 |

So the Even app really does draw content below and popups above. The spawn command is already decoded in g2-kit (`EvenHub_pb.ts`): EvenHub `Cmd 17` `OS_NOTIFY_MENU_STARTUP_PACKET` → `MenuStartUpEvent { uint32 widgetId = 1 }`, where `widgetId` is the foreground SID (3=menu, 4=notification, 7=even_ai). The glasses reply `Cmd 18` `APP_RESPONSE_MENU_STARTUP_FAILED_PACKET` (`MenuStartUpResPonse`). (g2-kit's `EvenHub_Cmd_List` runs 0–20; the app's own binary hints at a few commands past 20 — see the verification note below.)

### Notifications: control decoded; content push is dashboard news, foreground popup content still open

`g2.notification` is settings, not the payload: `NotificationControl` (`notifEnable`, `autoDispEnable`, `dispTime`, `avoidDisturbEnable`) and `NotificationIOS` (`appID` + `displayName`, the per-iOS-app whitelist). Content for the dashboard's news widget is `g2.dashboard` `eDashboardCommandId.APP_SEND_NEWS_DATA = 9` → `AppSendNewsData { sessionId, sessionStatus, sessionTotalCount, sessionNewsIndex, newsId, title=6, reportTime=7, source=8, content=9 }`. That is the **background news feed**, though — the command that fills a *foreground* notification popup (SID 4) body is still not pinned down and needs a live BLE capture.

### Map view: fully decoded, and the phone routes with Mapbox

`g2.navigation` (sid `0x08`) is complete in g2-kit / even-g2-protocol:

- `Navigation_Cmd_list`: heartbeat, request/response location list, start-up, basic info, mini map, max map, recalcs, exit, plus the OS→app events (menu start-up, location selected, exit, review changed, compass changed / calibrate).
- `extend_info_msg`: `directionSignIndex` (the turn arrow), `distance`, `roadName`, `spendTime`, `remainDistance`, `etaTime`, `speed`, `navigateWorkMethod`.
- Mini and max map stream as bitmaps: `mapSessionId`, `mapTotalSize`, `compressMode`, `mapFragmentIndex`, `mapFragmentPacketSize`, `mapRawData` (fragmented), and `rotationAngle` / `miniMapBorderEn` on the max map.
- The phone routes with **Mapbox** (`com.mapbox.navigation`), so the glasses only ever receive the arrow + text + bitmaps, never the route.

## What this changes

- The "second layer" is no longer a guess: the layer model is in the firmware's service table, and the spawn command (`Cmd 17`, `MenuStartUpEvent{widgetId}`) is already mapped in g2-kit.
- The navigation plan can rely on the decoded proto instead of re-decoding it.
- The protocol actually lives in the Flutter AOT binary (`libapp.so`), not the Jiagu-encrypted dex — so the right extraction path is `blutter` on `libapp.so`, not a dex dump (Jiagu only packs the Java dex).

## The one remaining gap: foreground notification content

The spawn command is mapped (above), so the only genuinely open piece is the command that fills a foreground notification popup's body (title/body) once it's spawned via `Cmd 17` with `widgetId=4` — and confirming the few EvenHub commands past `20` that the app's binary hints at.

1. **BLE capture** (fastest, no new tooling): run the official app and capture the sid `0xe0` traffic while it shows a notification. g2-kit already has the envelope + protobuf scaffolding.
2. **Dump the Dart AOT binary** (the actual protocol location): `libapp.so` in the APK is the Flutter AOT compiled code; extract it with `blutter` (built against the app's Dart version) and read the generated `*.pb.dart` enums / `BuilderInfo` directly. This is what recovered the fields above — Jiagu only packs the Java dex, so no dex dump is needed.

### Unpacking Jiagu (reference — mostly unnecessary now)

Note: the protocol lives in `libapp.so`, which Jiagu does not pack, so `blutter` sidesteps this entirely. If you do need the Java/Kotlin side, Jiagu decrypts the real dex and native lib in memory at launch. To get them:

- Rooted device, or a Magisk-patched emulator **with KVM** (a software-rendered emulator is too slow to be useful).
- `pip install frida-tools`, push `frida-server`, then `frida-dexdump -U -f com.even.sg` dumps every dex loaded into memory, including the decrypted `com.even.*` classes.
- The native lib can be dumped from `/proc/<pid>/maps` + `dd`, or hooked with Frida once the real `.so` is mapped.
- Jiagu usually adds anti-debug / anti-emulator / root checks — hook `android.os.Debug.isDebuggerConnected`, the `/proc/self/maps` read, and the emulator-property checks first.

Our CI host has no `/dev/kvm` (no nested virtualization), so the emulator route runs on a Mac or a real device, not here.
