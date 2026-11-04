import LottiKit

/// The brain for when Lotti Brain can't be reached: Apple's on-device model (it plans with rules
/// first) when the phone has it, the rules-only `OfflineBrain` otherwise. Either way only timers,
/// navigation, reminders and the local day work; everything else is the short offline sentence.
@MainActor
final class OfflineChoice: Brain {
    private let primary: any Brain
    private let primaryAvailable: @MainActor () -> Bool
    private let fallback: any Brain

    init(primary: any Brain, primaryAvailable: @escaping @MainActor () -> Bool, fallback: any Brain) {
        self.primary = primary
        self.primaryAvailable = primaryAvailable
        self.fallback = fallback
    }

    private var current: any Brain { primaryAvailable() ? primary : fallback }

    func prewarm() { current.prewarm() }

    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer {
        try await current.answer(message, context: context, status: status)
    }

    func endConversation() {
        primary.endConversation()
        fallback.endConversation()
    }
}
