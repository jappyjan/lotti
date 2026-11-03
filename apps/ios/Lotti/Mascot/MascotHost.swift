import LottiKit
import Observation

/// Owns the app's one `MascotController` and ref-counts the views that show it, so the empty-chat
/// raccoon and the header avatar can overlap for a moment (one appears before the other goes)
/// without one's `stop()` cutting the other. The controller is started while anyone holds it.
@MainActor
@Observable
final class MascotHost {
    let controller: MascotController
    @ObservationIgnored private var holders = 0

    init(link: any GlassesLink, demand: IMUDemand) {
        controller = MascotController(link: link, demand: demand)
    }

    /// Switch from Settings; off means nothing starts and the IMU is not requested.
    func setEnabled(_ enabled: Bool) {
        controller.enabled = enabled
    }

    /// False with Reduce Motion: the head stays neutral and the IMU is never requested for it.
    func setHeadSyncAllowed(_ allowed: Bool) {
        controller.headSyncAllowed = allowed
    }

    /// A view that shows the mascot is on screen in the foreground and the switch is on.
    func acquire() {
        holders += 1
        if holders == 1 { controller.start() }
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { controller.stop() }
    }

    var holderCount: Int { holders }
}
