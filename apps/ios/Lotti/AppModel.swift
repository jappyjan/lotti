import Foundation
import LottiKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let hello = "Hello from Lotti"

    /// A gesture as it arrived, for the "last input" readout.
    struct ReceivedInput: Identifiable, Equatable {
        enum Path: String { case glasses, ringDirect = "ring (direct)" }

        let id = UUID()
        let event: InputEvent
        let path: Path
        let time: Date
    }

    let link: any GlassesLink
    let ring: any RingLink
    private(set) var isSending = false
    private(set) var lastError: String?
    /// Newest first, at most `maxInputs`.
    private(set) var inputs: [ReceivedInput] = []
    static let maxInputs = 10

    init(link: any GlassesLink, ring: any RingLink) {
        self.link = link
        self.ring = ring
    }

    /// Reconnect to the glasses from last time, or start looking for some.
    func launch() async {
        if link.lastGlasses != nil {
            await link.reconnectToLast()
        } else {
            link.startScan()
        }
    }

    /// Collects gestures from the glasses and the ring until both streams end.
    func receiveInputs() async {
        let glasses = link.inputs(), ring = ring.inputs()
        await withDiscardingTaskGroup { group in
            group.addTask { for await e in glasses { await self.record(e, via: .glasses) } }
            group.addTask { for await e in ring { await self.record(e, via: .ringDirect) } }
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

    private func record(_ event: InputEvent, via path: ReceivedInput.Path) {
        print("[Input] \(event) via \(path.rawValue)")
        inputs.insert(ReceivedInput(event: event, path: path, time: .now), at: 0)
        if inputs.count > Self.maxInputs { inputs.removeLast() }
    }
}
