import Foundation
import LottiKit
import Observation

@MainActor
@Observable
final class AppModel {
    /// A gesture as it arrived, for the "last input" readout.
    struct ReceivedInput: Identifiable, Equatable {
        let id = UUID()
        let event: InputEvent
        let time: Date
    }

    let link: any GlassesLink
    let conductor: Conductor
    /// Newest first, at most `maxInputs`.
    private(set) var inputs: [ReceivedInput] = []
    static let maxInputs = 10
    /// How many times the link came back on its own since launch.
    private(set) var reconnects = 0

    /// You pressed Disconnect: don't reconnect until you connect again.
    private var stayDisconnected = false
    private var wasConnected = false

    init(link: any GlassesLink, conductor: Conductor) {
        self.link = link
        self.conductor = conductor
    }

    /// Reconnect to the glasses from last time, or start looking for some.
    func launch() async {
        if link.lastGlasses != nil {
            await link.reconnectToLast()
        } else {
            link.startScan()
        }
    }

    /// Notices connects and drops: redraws after a connect, and reconnects after a drop, with a
    /// growing pause between attempts. Runs until cancelled.
    func keepConnected(pollEvery: Duration = .seconds(2)) async {
        var attempt = 0
        while !Task.isCancelled {
            let connected = link.status.isConnected
            if connected && !wasConnected {
                print("[App] glasses connected")
                attempt = 0
                await conductor.glassesConnected()
            }
            wasConnected = connected
            if shouldReconnect {
                attempt += 1
                let pause = min(30, 2 * attempt)
                print("[App] reconnecting (attempt \(attempt))")
                reconnects += 1
                await link.reconnectToLast()
                if !link.status.isConnected { try? await Task.sleep(for: .seconds(pause)) }
                continue
            }
            try? await Task.sleep(for: pollEvery)
        }
    }

    var shouldReconnect: Bool {
        guard !stayDisconnected, link.lastGlasses != nil else { return false }
        switch link.status {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    func connect(_ glasses: DiscoveredGlasses) async {
        stayDisconnected = false
        await link.connect(glasses)
    }

    func disconnect() {
        stayDisconnected = true
        link.disconnect()
    }

    /// Collects gestures for the phone's readout until the stream ends. The conductor reads its
    /// own copy of the stream.
    func receiveInputs() async {
        for await event in link.inputs() {
            print("[Input] \(event)")
            inputs.insert(ReceivedInput(event: event, time: .now), at: 0)
            if inputs.count > Self.maxInputs { inputs.removeLast() }
        }
    }

    /// Debug launch arguments, so a run can be checked from the log without touching the glasses:
    /// `--ask "question"` asks Lotti once connected, `--today` opens the today view, `--listen`
    /// holds "talk" for 5 s (checks the mic and speech pipeline).
    func runLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) async {
        let wantsToday = arguments.contains("--today")
        let question = arguments.firstIndex(of: "--ask").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let wantsListen = arguments.contains("--listen")
        guard wantsToday || question != nil || wantsListen else { return }
        while !link.status.isConnected { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(1))
        if wantsToday { conductor.handle(InputEvent(.tap, from: .unknown)) }
        if wantsListen {
            if wantsToday { try? await Task.sleep(for: .seconds(4)) }
            print("[App] listening for 5 s")
            conductor.handle(InputEvent(.doubleTap, from: .unknown))
            try? await Task.sleep(for: .milliseconds(500))
            conductor.handle(InputEvent(.longPress, from: .unknown))
            try? await Task.sleep(for: .seconds(5))
            conductor.handle(InputEvent(.longPressEnd, from: .unknown))
            try? await Task.sleep(for: .seconds(6))
        }
        if let question {
            if wantsToday { try? await Task.sleep(for: .seconds(4)) }
            print("[App] asking: \(question)")
            conductor.ask(question)
        }
    }
}
