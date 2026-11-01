import LottiKit
import SwiftUI

/// The phone app: connection, a few settings, and a debug screen. You shouldn't need it day to day.
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
                glassesSection

                Section("Lotti") {
                    if let problem = brain.unavailableReason {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    NavigationLink("Calendars") { CalendarsView() }
                    Picker("I speak", selection: $speechLanguage) {
                        ForEach(Settings.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: speechLanguage) { _, new in
                        speech.locale = Locale(identifier: new)
                        Task { await speech.prepare() }
                    }
                }

                lookUpSection

                Section {
                    NavigationLink("Debug") { DebugView(model: model, brain: brain) }
                }
            }
            .navigationTitle("Lotti")
        }
        .tint(.green)
    }

    @ViewBuilder private var glassesSection: some View {
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
            Text("Glasses")
        } footer: {
            Text(link.status.isConnected
                 ? "Tap or look up for today. Hold to talk. Scroll and tap to pick, double tap to go back."
                 : "Force-quit the Even app first. Lotti replaces it while connected.")
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
            Text("Look up")
        } footer: {
            Text("Wear the glasses, look straight ahead and press \"Set straight ahead\".")
        }
    }

    private func update(_ change: (inout HeadUpSettings) -> Void) {
        var settings = link.headUpSettings
        change(&settings)
        link.headUpSettings = settings
        Settings.headUp = settings
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
