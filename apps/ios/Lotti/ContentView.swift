import LottiKit
import SwiftUI

struct ContentView: View {
    let model: AppModel
    let speech: AppleSpeechRecognizer
    let brain: AppleBrain
    @AppStorage(Settings.speechLanguageKey) private var speechLanguage = Settings.speechLanguage

    private var link: any GlassesLink { model.link }
    private var conductor: Conductor { model.conductor }

    var body: some View {
        NavigationStack {
            List {
                Section("Glasses") {
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(link.status.isConnected ? .green : .primary)
                    if model.reconnects > 0 {
                        LabeledContent("Reconnects", value: "\(model.reconnects)")
                    }
                }

                glassesScreen

                Section("Lotti") {
                    LabeledContent("Brain", value: brain.unavailableReason ?? "Ready")
                    LabeledContent("Microphone", value: conductor.microphoneSource ?? "Not used yet")
                    if let heard = conductor.lastHeard {
                        LabeledContent("Last heard", value: heard.isEmpty ? "(nothing)" : heard)
                    }
                    if let error = conductor.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    Picker("I speak", selection: $speechLanguage) {
                        ForEach(Settings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: speechLanguage) { _, new in
                        speech.locale = Locale(identifier: new)
                        Task { await speech.prepare() }
                    }
                }

                lookUpSection

                if link.status.isConnected {
                    Section {
                        Button("Show today view") { conductor.handle(InputEvent(.tap, from: .unknown)) }
                        Button("Ask \"What's on today?\"") { conductor.ask("What's on today?") }
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    } footer: {
                        Text("On the glasses: tap or look up for today, hold to talk, scroll and tap to pick, double tap to go back.")
                    }
                } else {
                    connectSection
                }

                inputSection
            }
            .navigationTitle("Lotti")
        }
        .tint(.green)
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
                LabeledContent("Head now", value: link.headPitch.map { String(format: "%.0f°", $0) } ?? "–")
                LabeledContent("Straight ahead", value: String(format: "%.0f°", link.headUpSettings.straightAhead))
                Button("This is straight ahead") {
                    guard let pitch = link.headPitch else { return }
                    update { $0.straightAhead = pitch.rounded() }
                }
                .disabled(link.headPitch == nil)
                VStack(alignment: .leading) {
                    Text(String(format: "Look up by %.0f°", link.headUpSettings.lookUp))
                    Slider(value: Binding(
                        get: { link.headUpSettings.lookUp },
                        set: { value in update { $0.lookUp = value.rounded() } }), in: 5...40, step: 1)
                }
            }
        } header: {
            Text("Look up")
        } footer: {
            Text("Look straight ahead and press the button, then pick how far up opens the today view.")
        }
    }

    private func update(_ change: (inout HeadUpSettings) -> Void) {
        var settings = link.headUpSettings
        change(&settings)
        link.headUpSettings = settings
        Settings.headUp = settings
    }

    /// What the glasses show right now, so you can check without wearing them.
    @ViewBuilder private var glassesScreen: some View {
        Section("On the glasses") {
            if let screen = conductor.screen {
                Text(screen.text).font(.headline)
                ForEach(screen.details, id: \.self) { Text($0).foregroundStyle(.secondary) }
                if let rail = screen.rail {
                    ForEach(Array(rail.items.enumerated()), id: \.offset) { index, item in
                        Label(item.title, systemImage: index == rail.highlighted ? "chevron.right.circle.fill" : "circle")
                            .foregroundStyle(index == rail.highlighted ? .green : .secondary)
                    }
                }
            } else {
                Text("Display off").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Last input") {
            if model.inputs.isEmpty {
                Text("Tap a touchpad or use the ring.").foregroundStyle(.secondary)
            }
            ForEach(model.inputs) { input in
                LabeledContent {
                    Text(input.time, format: .dateTime.hour().minute().second())
                } label: {
                    Text(input.event.gesture.rawValue)
                    Text(input.event.source.rawValue)
                }
            }
        }
    }

    @ViewBuilder private var connectSection: some View {
        Section {
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
        } header: {
            Text("Connect")
        } footer: {
            Text("Force-quit the Even app first. Lotti replaces it while connected.")
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
