import LottiKit
import SwiftUI

struct ContentView: View {
    let model: AppModel
    /// Spike S3: open the eval screen straight away when launched with `--eval`.
    @State private var showEval = ProcessInfo.processInfo.arguments.contains("--eval")
    private var link: any GlassesLink { model.link }

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Label(statusText, systemImage: statusIcon)
                        .foregroundStyle(link.status.isConnected ? .green : .primary)
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                inputSection

                if #available(iOS 27.0, *) {
                    Section("Spike S3") {
                        NavigationLink("Brain eval") { EvalView() }
                    }
                }

                if link.status.isConnected {
                    Section {
                        Button("Send hello") { Task { await model.sendHello() } }
                            .disabled(model.isSending)
                        Button("Disconnect", role: .destructive) { link.disconnect() }
                    }
                } else {
                    glassesSection
                }
            }
            .navigationTitle("Lotti")
            .navigationDestination(isPresented: $showEval) {
                if #available(iOS 27.0, *) { EvalView() }
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
                    Text(input.event.gesture.rawValue).font(input.id == model.inputs.first?.id ? .headline : .body)
                    Text(input.event.source.rawValue)
                }
            }
        }
    }

    @ViewBuilder private var glassesSection: some View {
        Section {
            ForEach(link.discovered) { glasses in
                Button {
                    Task { await link.connect(glasses) }
                } label: {
                    LabeledContent(glasses.name, value: "Connect")
                }
                .disabled(isConnecting)
            }
            if let last = link.lastGlasses, !link.discovered.contains(where: { $0.id == last.id }) {
                Button("Reconnect to \(last.name)") { Task { await link.connect(last) } }
                    .disabled(isConnecting)
            }
            if link.status == .scanning {
                Button("Stop scanning") { link.stopScan() }
            } else {
                Button("Scan for glasses") { link.startScan() }
                    .disabled(isConnecting)
            }
        } header: {
            Text("Glasses")
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
