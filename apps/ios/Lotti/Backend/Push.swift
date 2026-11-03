import Foundation
import UIKit
import UserNotifications

/// Push notifications (APNs) wake the app when Lotti Brain has something and no socket is open.
///
/// They are opt-in because they need a paid developer account: build with `LOTTI_APNS=1`
/// (Config/Local.xcconfig, see apps/ios/README.md). Without it nothing here registers and the app
/// signs with a free Personal Team.
@MainActor
enum PushRegistration {
    /// True in a build with the `aps-environment` entitlement.
    static var isCompiledIn: Bool {
        #if LOTTI_APNS
        true
        #else
        false
        #endif
    }

    /// Called with the hex device token once iOS hands it out; AppModel keeps it and sends it in `hello`.
    static var onToken: (@MainActor (String) -> Void)?
    static var lastError: String?

    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    /// Asks for permission to show notifications and registers with APNs. No-op without APNs.
    static func register() async {
        #if LOTTI_APNS
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            lastError = "Notifications are off for Lotti (Settings → Lotti → Notifications)."
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

#if LOTTI_APNS
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.onToken?(PushRegistration.hex(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushRegistration.lastError = error.localizedDescription
    }
}
#endif
