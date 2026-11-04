import Foundation
import LottiKit
import UIKit

/// Tells Lotti Brain what the phone is doing (`presence`): unlocked, plugged in or not. The
/// glasses' events (worn, removed, connected) come from the `Conductor`, `app_open` from the app
/// coming to the foreground. Motion (`phone_still` / `phone_moving`) is not reported: it would
/// need the Motion & Fitness permission for little gain.
@MainActor
final class PresenceMonitor {
    private let backend: BackendClient
    private var observers: [any NSObjectProtocol] = []
    private var started = false

    init(backend: BackendClient) {
        self.backend = backend
    }

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backend.presence(.phoneUnlock) }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportCurrent() }
        })
    }

    private var lastReported: PresenceEvent?

    /// Sends the charging state if it changed since the last report. Called on a battery change
    /// and after every (re)connect, when the backend has forgotten it.
    func reportCurrent(force: Bool = false) {
        let event: PresenceEvent
        switch UIDevice.current.batteryState {
        case .charging, .full: event = .phoneCharging
        case .unplugged: event = .phoneUnplugged
        default: return
        }
        guard force || event != lastReported else { return }
        lastReported = event
        backend.presence(event)
    }
}
