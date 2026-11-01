import Foundation
import LottiKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let hello = "Hello from Lotti"

    /// A gesture as it arrived, for the "last input" readout.
    struct ReceivedInput: Identifiable, Equatable {
        let id = UUID()
        let event: InputEvent
        let time: Date
    }

    let link: any GlassesLink
    private(set) var isSending = false
    private(set) var lastError: String?
    /// Newest first, at most `maxInputs`.
    private(set) var inputs: [ReceivedInput] = []
    static let maxInputs = 10

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

    /// Collects touchpad and ring gestures (the ring's arrive through the glasses) until the
    /// stream ends.
    func receiveInputs() async {
        for await event in link.inputs() {
            print("[Input] \(event)")
            inputs.insert(ReceivedInput(event: event, time: .now), at: 0)
            if inputs.count > Self.maxInputs { inputs.removeLast() }
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
