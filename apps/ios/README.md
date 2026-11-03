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
