import LottiKit
import SwiftUI

/// The glasses: connection, head tracking, wear detection, the mascot, and a test for the indicators.
struct GlassesSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MascotSetting.key) private var mascotEnabled = MascotSetting.defaultValue
    @AppStorage(Settings.wakeWordKey) private var wakeWord = Settings.wakeWordEnabled
    @State private var note: String?
    @State private var error: String?

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

    var body: some View {
        List {
            connectionSection
            wearSection
            lookUpSection
            voiceSection
            Section {
                Toggle("Mascot", isOn: $mascotEnabled)
            } footer: {
                Text("Lotti's raccoon in the chat. It wears glasses when yours are on and follows your head.")
            }
            indicatorSection
        }
        .navigationTitle("Glasses")
        .errorAlert($error)
    }

    // MARK: Connection

    @ViewBuilder private var connectionSection: some View {
        Section {
            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(link.status.isConnected ? .green : .primary)
            if link.status.isConnected {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            } else {
                ForEach(link.discovered) { glasses in
                    Button {
                        Task { await model.connect(glasses) }
                    } label: {
                        LabeledContent(glasses.name, value: "Connect")
                    }
                    .disabled(isConnecting)
                }
                if let last = link.lastGlasses, !link.discovered.contains(where: { $0.id == last.id }) {
                    Button("Reconnect to \(last.name)") { Task { await model.connect(last) } }
                        .disabled(isConnecting)
                }
                if link.status == .scanning {
                    Button("Stop scanning") { link.stopScan() }
                } else {
                    Button("Scan for glasses") { link.startScan() }
                        .disabled(isConnecting)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(link.status.isConnected
                 ? "Display off? Double tap, or look up (if switched on below), to open Today. A \"Catch-up\" choice appears there for 12 hours after Lotti sends one. To talk: double tap, then hold and speak (just hold while something is showing). Scroll and tap to pick, double tap to go back."
                 : "Force-quit the Even app first. Lotti replaces it while connected.")
        }
    }

    @ViewBuilder private var wearSection: some View {
        Section {
            StatusRow(title: "On your head", value: wearText, good: link.wearState == .worn ? true : nil)
        } header: {
            Text("Wear detection")
        } footer: {
            Text("From the glasses' own sensor. Lotti Brain uses it to know when you're around; the display goes dark when you take them off. \"Unknown\" means the glasses haven't sent a wear signal yet; Debug → Wear capture records what they do send.")
        }
    }

    @ViewBuilder private var lookUpSection: some View {
        Section {
            Toggle("Open today when I look up", isOn: Binding(
                get: { conductor.headTracking },
                set: { on in
                    Settings.headUpEnabled = on
                    Task { await conductor.setHeadTracking(on) }
                }))
            if conductor.headTracking {
                VStack(alignment: .leading) {
                    Text(String(format: "Look up by %.0f°", link.headUpSettings.lookUp))
                    Slider(value: Binding(
                        get: { link.headUpSettings.lookUp },
                        set: { value in update { $0.lookUp = value.rounded() } }), in: 5...40, step: 1)
                }
                Button("Set straight ahead") {
                    guard let pitch = link.headPitch else { return }
                    update { $0.straightAhead = pitch.rounded() }
                }
                .disabled(link.headPitch == nil)
            }
        } header: {
            Text("Head tracking")
        } footer: {
            Text("Wear the glasses, look straight ahead and press \"Set straight ahead\".")
        }
    }

    @ViewBuilder private var voiceSection: some View {
        Section {
            Toggle("Listen for \"Hey Lotti\"", isOn: $wakeWord)
                .onChange(of: wakeWord) { _, on in conductor.setWakeWord(enabled: on) }
            if wakeWord {
                StatusRow(title: "Hey Lotti", value: wakeText, good: conductor.wakeState == .listening ? true : nil)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Say \"Hey Lotti, …\" with the glasses on, even with the phone locked and the display off. Uses the glasses' microphone while they're connected.")
        }
    }

    private var wakeText: String {
        switch conductor.wakeState {
        case .off: link.status.isConnected ? "Off" : "Waiting for glasses"
        case .listening: "Listening"
        case .unavailable: "Glasses mic unavailable"
        }
    }

    /// The glasses show a small icon for waiting inbox items, and one while Lotti reads your location.
    @ViewBuilder private var indicatorSection: some View {
        Section {
            StatusRow(title: "Waiting items", value: "\(model.backend.inbox.pending(at: .now).count)")
            StatusRow(title: "Location icon", value: conductor.locationActive ? "Showing" : "Off")
            Button("Send a test item to the inbox") {
                Task {
                    await attempt($error) {
                        _ = try await model.call("inbox.create", ["kind": "info", "title": "Indicator test", "summary": "Sent from the Lotti app.",
                                                                  "expiresInHours": 1])
                        model.backend.syncInbox()
                        note = "Sent. While the display is off, the glasses show the info icon until you open or dismiss it."
                    }
                }
            }
            .disabled(!model.isPaired)
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Indicators")
        }
    }

    private func update(_ change: (inout HeadUpSettings) -> Void) {
        var settings = link.headUpSettings
        change(&settings)
        link.headUpSettings = settings
        Settings.headUp = settings
    }

    private var wearText: String {
        switch link.wearState {
        case .unknown: "Unknown"
        case .worn: "Worn"
        case .removed: "Taken off"
        }
    }

    private var isConnecting: Bool {
        if case .connecting = link.status { return true }
        return false
    }

    private var statusText: String {
        switch link.status {
        case .bluetoothUnavailable(let reason): reason
        case .disconnected: "Not connected"
        case .scanning: "Scanning…"
        case .connecting(let step): step
        case .connected(let glasses): "Connected to \(glasses.name)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    private var statusIcon: String {
        switch link.status {
        case .connected: "eyeglasses"
        case .scanning, .connecting: "antenna.radiowaves.left.and.right"
        case .failed, .bluetoothUnavailable: "exclamationmark.triangle"
        case .disconnected: "circle.dashed"
        }
    }
}
