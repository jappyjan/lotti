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

So the Even app really does draw content below and popups above. The spawn command is already decoded in g2-kit (`EvenHub_pb.ts`): EvenHub `Cmd 17` `OS_NOTIFY_MENU_STARTUP_PACKET` → `MenuStartUpEvent { uint32 widgetId = 1 }`, where `widgetId` is the foreground SID (3=menu, 4=notification, 7=even_ai). The glasses reply `Cmd 18` `APP_RESPONSE_MENU_STARTUP_FAILED_PACKET` (`MenuStartUpResPonse`). (g2-kit's `EvenHub_Cmd_List` runs 0–20; the app adds three more, 0x15–0x17 — see "Verified against g2-kit" below.)

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

## Verified against g2-kit (2026-11-01)

Reconciled with g2-kit's generated protos. Genuinely new (absent from g2-kit):

- Three EvenHub commands past `20`, all menu-related:
  - `OS_NOTIFY_MENU_ITEM_CLICK_PACKET = 0x15` (21) → oneof field 24 `MenuItemClick`
  - `OS_NOTIFY_MENU_SUBITEM_SWITCH_PACKET = 0x16` (22) → oneof field 25 `MenuSubReq`
  - `APP_RESPONSE_MENU_SUBITEM_SWITCH_PACKET = 0x17` (23) → oneof field 26 `MenuSubRes`
- `eNotificationCommandId.NOTIFICATION_WHITELIST_CHK = 4`.
- Two new SIDs: `UI_NOTE_APP_ID = 0x12` (18) and `UI_TRACEPOINT_APP_ID = 0x11` (17), with their `note.pb.dart` / `tracepoint.pb.dart` protos.

Already in g2-kit (so re-derived, not recovered): the foreground-spawn pair (Cmd 17/18), the whole dashboard `AppSendNewsData` / `eDashboardCommandId` news structure, and the file-service enum `ANDROID_MSG_JSON_NOTIFICATION = 1`.

## The one remaining gap: foreground notification content

The foreground notification body is not the dashboard news. It travels over the **file service** (sid `0xc4`/`0xc5`, `ANDROID_MSG_JSON_NOTIFICATION`) as a JSON payload whose title/body field names are still undecoded. That is the real remaining gap.

1. **BLE capture** (fastest): run the official app and capture the file-service traffic while it shows a notification.
2. **Dump the Dart AOT binary** (`libapp.so` with `blutter`) to read how the app builds that JSON schema.

### Unpacking Jiagu (reference — mostly unnecessary now)

Note: the protocol lives in `libapp.so`, which Jiagu does not pack, so `blutter` sidesteps this entirely. If you do need the Java/Kotlin side, Jiagu decrypts the real dex and native lib in memory at launch. To get them:

- Rooted device, or a Magisk-patched emulator **with KVM** (a software-rendered emulator is too slow to be useful).
- `pip install frida-tools`, push `frida-server`, then `frida-dexdump -U -f com.even.sg` dumps every dex loaded into memory, including the decrypted `com.even.*` classes.
- The native lib can be dumped from `/proc/<pid>/maps` + `dd`, or hooked with Frida once the real `.so` is mapped.
- Jiagu usually adds anti-debug / anti-emulator / root checks — hook `android.os.Debug.isDebuggerConnected`, the `/proc/self/maps` read, and the emulator-property checks first.

Our CI host has no `/dev/kvm` (no nested virtualization), so the emulator route runs on a Mac or a real device, not here.
