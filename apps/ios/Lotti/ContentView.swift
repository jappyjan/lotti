import LottiKit
import SwiftUI

struct ContentView: View {
    let model: AppModel
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
        }
    }

    @ViewBuilder private var glassesSection: some View {
        Section {
            ForEach(link.discovered) { glasses in
                Button {
                    Task { await link.connect(glasses) }
                } label: {
                    LabeledContent(glasses.name, value: glasses.isComplete ? "Connect" : "One arm found…")
                }
                .disabled(!glasses.isComplete || isConnecting)
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
