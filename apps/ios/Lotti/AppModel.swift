import LottiKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let hello = "Hello from Lotti"

    let link: any GlassesLink
    private(set) var isSending = false
    private(set) var lastError: String?

    init(link: any GlassesLink) {
        self.link = link
    }

    /// Reconnect to the glasses from last time, or start looking for some.
    func launch() async {
        if link.lastGlasses != nil {
            await link.reconnectToLast()
        } else {
            link.startScan()
        }
    }

    func sendHello() async {
        isSending = true
        defer { isSending = false }
        do {
            try await link.showText(Self.hello)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
