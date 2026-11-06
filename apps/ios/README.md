# Lotti (iOS app)

SwiftUI app for the Lotti glasses assistant: a chat with Lotti (the app opens to it), settings for
everything Lotti Brain does, and the glasses link (`LottiKit`). It talks to Lotti Brain (`apps/brain`)
over the contract in `docs/protocol.md`: a live WebSocket for asks, answers, inbox and presence, and the
HTTP management API (`/api/v1/ops`) behind the Settings screens.

- **Pair**: Settings → Lotti Brain: enter the server address and the one-time code, paste the
  `lotti://pair?url=…&code=…` link, scan its QR code, or open that link (the iPhone camera app can).
  The device token lives in the Keychain, the server address in UserDefaults.
- **Offline**: without a connection the same chat answers timers, navigation, reminders and the local
  day on the phone (Apple's on-device model when available, rules otherwise).
- **Build**: `pnpm nx build ios`, `pnpm nx test ios`, `pnpm nx run-device ios` (see `scripts/xcode.sh`).

## Push notifications (APNs), opt-in

The default build signs with a free Personal Team, which cannot use push. So `Lotti.entitlements` is
empty, `Info.plist` has no `remote-notification` background mode, and the registration code is not
compiled. Everything still works while the app is open or woken by the glasses over Bluetooth.

To turn push on you need a paid Apple developer account:

1. Create an APNs key (developer.apple.com → Keys → Apple Push Notifications service) and download the `.p8`.
2. Build with `LOTTI_APNS=1`: either create `apps/ios/Config/Local.xcconfig` (git-ignored) containing
   `LOTTI_APNS = 1`, or pass it on the command line (`xcodebuild … LOTTI_APNS=1`). That switches
   `CODE_SIGN_ENTITLEMENTS` to `Lotti-APNs.entitlements` (`aps-environment`; change `development` to
   `production` for TestFlight/App Store), `INFOPLIST_FILE` to `Info-APNs.plist` (adds
   `remote-notification`) and defines the `LOTTI_APNS` Swift condition (`Backend/Push.swift`).
   Keep `Info.plist` and `Info-APNs.plist` in step.
3. Run the app, then Settings → Push notifications: allow notifications, enter the key ID, team ID, topic
   (the bundle id) and choose the `.p8` file, then "Send key to Lotti Brain" (`push.configure`) and "Send a
   test push". The device token goes to the backend in the socket's `hello`.

## Wisp update screen (developer, rung 1)

Settings → Developer → **Wisp update screen** (off by default) shows "Wisp update (rung 1)": the phone-side
tool for rung 1 of [docs/wisp/safety.md](../../docs/wisp/safety.md). It reads one temple's version and battery,
gets the matching pinned stock bundle from Even's CDN (size + SHA-256 like `wisp-ota fetch`, cached in the
app container), repacks it (only the version string changes, CRCs recomputed), shows the guard report and the
structural diff, and sends it to that one temple with the stock OTA sender, or sends pure stock back.

- **Single source.** The guards, repacker, diff and sender are `packages/wisp-ota`, bundled for JavaScriptCore
  by `packages/wisp-ota-jsc` and run by `LottiKit/Wisp/WispOtaEngine.swift`. Swift only adds the link
  (`G2Link.openExclusiveArm`), the download and the UI. `scripts/xcode.sh` copies `wisp-ota.js` into
  `Lotti/Wisp/Generated/` (git-ignored); the fake stock temple goes into Simulator builds only, and
  `run-device` refuses to install a build that contains it.
- **The link.** One arm, nothing else on it: no Lotti session, no other arm, no heartbeat, page or mic. The arm
  gets sid 0x80 auth and sid 0x09 READ (versions, battery), then the stock OTA characteristics `…0001/…0002`.
- **Send gates** (all required, shown as a checklist): guard report sendable, no Lotti glasses session, the
  installed version fits the bundle, battery of that temple above 80 % (unreadable = refused), the Even app
  acknowledged as force-quit, and the temple name typed (`left`). Right before sending the temple is read
  again on the same connection. The acknowledgement and the typed name are used up by each send. One temple
  per send; there is no "both".
- **While sending** the screen keeps the phone awake and hides Back. Abort works until RESULT_CHECK (the
  sender refuses later). The end state is **Success** (staged; the temple resets and installs it),
  **Failed, stock intact**, or **Result unknown** (do nothing else; read the version).
- **Log.** Every step with its SHA-256s goes to `Application Support/wisp/wisp-update.log` (Full log, Export
  log). A successful send also prints a ready row for the hardware log in safety.md.
- **Simulator.** No Bluetooth there, so the screen uses wisp-ota's fake stock temple (2.2.6.10, battery 95 %).

### First real use (left temple, with Jan, after his explicit "go")

1. Build and install from this branch: `pnpm nx run ios:run-device`.
2. Temples charged above 80 %, out of the case, nothing on the table that can bump them, only this phone near.
   Force-quit the Even app.
3. In Lotti, make sure the glasses were connected once (Settings → Glasses), then press **Disconnect** there.
   The update screen refuses while a Lotti session is active.
4. Settings → Developer → turn on **Wisp update screen** → **Wisp update (rung 1)**. Temple: **Left**.
5. **Read version and battery.** Note the version. If the read fails, stop: the left arm didn't answer the
   settings query, and the screen won't send without a battery reading.
6. **Get stock <version>** (needs internet). It must say "Pinned ✓ matches the catalog".
7. **Repack for rung 1** (default: last digit changed, e.g. 2.2.6.10 → 2.2.6.19). The guard report must say
   **SENDABLE**; open the diff: only the version strings and the CRCs.
8. Jan gives the "go" in chat for this flash (rule 4).
9. Turn on the Even-app acknowledgement, type `left`, **Send to the left temple**. Keep Lotti in the foreground
   and the phone next to the glasses until the result shows.
10. **Success:** wait about 2 minutes, then **Read version**: it must show the repack version. Check the temple
    boots, advertises and the Even app works (then force-quit it again).
    **Failed, stock intact:** read the version (unchanged), export the log, report.
    **Result unknown:** touch nothing for 3 minutes, then read the version and report.
11. Round trip: **Read version** (shows the repack, stock base known) → **Get stock** → **Prepare pure stock** →
    a new "go" → acknowledgement, `left` → **Send**. After 2 minutes **Read version** must show stock again.
12. **Export log**, add the rows to the hardware log in safety.md, turn the developer setting off again.
    The right temple stays on stock until the left one has passed this round trip (rule 5).
