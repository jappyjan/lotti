import LottiKit
import SwiftUI
import UIKit

/// Lotti Brain: where it is, pairing (code, pasted link or QR), status, other devices, the admin MCP token.
struct BrainSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var code = ""
    @State private var scanning = false
    @State private var error: String?
    @State private var confirmUnpair = false

    var body: some View {
        List {
            connectionSection
            if model.isPaired {
                BrainStatusSection()
                DevicesSection()
                AdminTokenSection()
            }
            pairSection
        }
        .navigationTitle("Lotti Brain")
        .errorAlert($error)
        .sheet(isPresented: $scanning) { scanner }
        .confirmationDialog("Forget this Lotti Brain on the phone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("The phone stops talking to it until you pair again. The server keeps its data.")
        }
        .onAppear { if address.isEmpty { address = model.baseURL?.absoluteString ?? "" } }
    }

    // MARK: Connection

    @ViewBuilder private var connectionSection: some View {
        Section {
            StatusRow(title: "Status", value: statusText, good: model.backend.state == .connected)
            if let url = model.baseURL { LabeledContent("Server", value: url.absoluteString) }
            if let welcome = model.backend.welcome { LabeledContent("Version", value: welcome.serverVersion) }
            if let problem = model.backend.lastError, model.backend.state != .connected {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if model.isPaired {
                Button("Reconnect now") { model.backend.reconnectNow() }
                Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
            }
        } header: {
            Text("Connection")
        } footer: {
            if !model.isPaired { Text("Run Lotti Brain on your server, then pair this phone with the one-time code from its first start.") }
        }
    }

    private var statusText: String {
        if !model.isPaired { return "Not paired" }
        switch model.backend.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Offline"
        }
    }

    // MARK: Pairing

    @ViewBuilder private var pairSection: some View {
        Section {
            TextField("Server address (https://…)", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Pairing code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                guard let url = BackendStore.normalizedURL(address) else { return error = "That isn't a server address." }
                pair { try await model.pair(url: url, code: code) }
            } label: {
                if model.isPairing { ProgressView() } else { Text(model.isPaired ? "Pair again" : "Pair") }
            }
            .disabled(model.isPairing || code.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Paste pairing link", systemImage: "doc.on.clipboard") { pastePairingLink() }
            if QRScannerView.isAvailable {
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
            }
        } header: {
            Text(model.isPaired ? "Pair again" : "Pair")
        } footer: {
            Text("The server prints a QR code and a lotti://pair link at its first start. Scanning it with the camera app opens Lotti and pairs.")
        }
    }

    private var scanner: some View {
        NavigationStack {
            QRScannerView { text in
                scanning = false
                pair(link: text)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
        }
    }

    private func pastePairingLink() {
        guard let text = UIPasteboard.general.string, PairingLink(text) != nil else {
            return error = "The clipboard has no lotti://pair link."
        }
        pair(link: text)
    }

    private func pair(link text: String) {
        guard let link = PairingLink(text) else { return error = "That isn't a Lotti pairing link." }
        address = link.url.absoluteString
        code = link.code
        pair { try await model.pair(url: link.url, code: link.code) }
    }

    private func pair(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            await attempt($error) {
                try await work()
                code = ""
            }
        }
    }
}

// MARK: - Status

private struct BrainStatusSection: View {
    @Environment(AppModel.self) private var model
    @State private var status: JSONValue?
    @State private var failure: String?

    var body: some View {
        Section("Server") {
            if let status {
                if let version = status.text("version") { LabeledContent("Version", value: version) }
                if let provider = status.text("activeProvider") { LabeledContent("Active model", value: provider) }
                LabeledContent("Memories", value: "\(Int(status["memories"]?.number ?? 0))")
                LabeledContent("Scheduled jobs", value: "\(Int(status["jobs"]?.number ?? 0))")
                LabeledContent("Inbox", value: "\(Int(status["inboxPending"]?.number ?? 0)) waiting")
                LabeledContent("Paired phones", value: "\(Int(status["pairedDevices"]?.number ?? 0))")
            } else if let failure {
                Text(failure).foregroundStyle(.red)
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
        .task(id: model.backend.state) {
            do {
                status = try await model.call("status.get")
                failure = nil
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

// MARK: - Devices and pairing codes

private struct DevicesSection: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [JSONValue] = []
    @State private var newCode: String?
    @State private var error: String?
    /// The device whose Revoke was tapped, waiting for the confirmation.
    @State private var revoking: JSONValue?

    var body: some View {
        Section {
            ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
                LabeledContent(device.flag("isSelf") ? "This iPhone" : device.text("name") ?? "Device") {
                    Text(device.flag("connected") ? "Online" : shortDate(device.date("lastSeenAt"))).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Revoke", role: .destructive) { revoking = device }
                }
            }
            if let newCode {
                LabeledContent("Code") { Text(newCode).font(.body.monospaced()).textSelection(.enabled) }
                if let url = model.baseURL {
                    let link = "lotti://pair?url=\(url.absoluteString)&code=\(newCode)"
                    Button("Copy pairing link", systemImage: "doc.on.doc") { UIPasteboard.general.string = link }
                }
            }
            Button("New pairing code for another device") {
                Task {
                    await attempt($error) { newCode = try await model.call("pairing.new_code").text("code") }
                }
            }
        } header: {
            Text("Paired devices")
        } footer: {
            Text("Swipe a device to revoke it. A pairing code works once.")
        }
        .errorAlert($error)
        .confirmationDialog(revoking?.flag("isSelf") == true ? "Revoke this iPhone?" : "Revoke \(revoking?.text("name") ?? "this device")?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { device in
            Button(device.flag("isSelf") ? "Revoke and unpair this iPhone" : "Revoke", role: .destructive) { revoke(device) }
        } message: { device in
            if device.flag("isSelf") {
                Text("This is the phone you are holding. It loses access to Lotti Brain right away and has to be paired again with a new code.")
            } else {
                Text("It can't reach Lotti Brain any more until it is paired again.")
            }
        }
        .task { await load() }
    }

    private func load() async {
        devices = (try? await model.call("pairing.devices"))?.items ?? []
    }

    private func revoke(_ device: JSONValue) {
        guard let id = device.text("id") else { return }
        let isSelf = device.flag("isSelf")
        Task {
            await attempt($error) {
                _ = try await model.call("pairing.revoke_device", ["id": .string(id)])
                // Our own token is gone: forget the server here too instead of failing every call.
                if isSelf { model.unpair() }
            }
            if !isSelf { await load() }
        }
    }
}

// MARK: - Admin MCP token

/// The admin MCP server (`/mcp/admin`) lets another AI client (Claude, Codex …) manage Lotti. It is
/// off until you create a token, which is shown once.
private struct AdminTokenSection: View {
    @Environment(AppModel.self) private var model
    @State private var status: JSONValue?
    @State private var created: JSONValue?
    @State private var error: String?

    var body: some View {
        Section {
            let enabled = status?.flag("enabled") ?? false
            StatusRow(title: "Admin MCP server", value: enabled ? "On" : "Off", good: enabled)
            ForEach(Array((status?["tokens"]?.array ?? []).enumerated()), id: \.offset) { _, token in
                LabeledContent(token.text("name") ?? "token") {
                    Text(shortDate(token.date("lastUsedAt"))).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Revoke", role: .destructive) {
                        guard let id = token.text("id") else { return }
                        Task {
                            await attempt($error) { _ = try await model.call("admin_token.revoke", ["id": .string(id)]) }
                            await load()
                        }
                    }
                }
            }
            if let created, let token = created.text("token") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copy this token now. It is shown only once.").font(.footnote).foregroundStyle(.orange)
                    Text(token).font(.caption.monospaced()).textSelection(.enabled)
                    if let url = created.text("url") { Text(url).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Copy token", systemImage: "doc.on.doc") { UIPasteboard.general.string = token }
            }
            Button("Create admin token") {
                Task {
                    await attempt($error) { created = try await model.call("admin_token.create", ["name": "app"]) }
                    await load()
                }
            }
        } header: {
            Text("Admin MCP (off by default)")
        } footer: {
            Text("A token lets an AI client manage Lotti's jobs, memory and settings through /mcp/admin. It cannot read your keys or accounts.")
        }
        .errorAlert($error)
        .task { await load() }
    }

    private func load() async {
        status = try? await model.call("admin_token.status")
    }
}
