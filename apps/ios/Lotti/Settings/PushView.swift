import LottiKit
import SwiftUI
import UniformTypeIdentifiers

/// Push notifications (APNs): whether this build can receive them, whether the backend can send
/// them, and the APNs key you give the backend.
struct PushView: View {
    @Environment(AppModel.self) private var model
    @State private var status: JSONValue?
    @State private var hasToken = false
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var topic = "de.janjaap.lotti"
    @State private var production = false
    @State private var keyText = ""
    @State private var keyName: String?
    @State private var importing = false
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                StatusRow(title: "This build", value: PushRegistration.isCompiledIn ? "Push enabled" : "Push off (free signing)",
                          good: PushRegistration.isCompiledIn)
                StatusRow(title: "Device token", value: hasToken ? "Registered" : "None", good: hasToken)
                if let problem = PushRegistration.lastError { Text(problem).font(.footnote).foregroundStyle(.red) }
                if PushRegistration.isCompiledIn {
                    Button("Enable notifications") { Task { await PushRegistration.register() } }
                }
            } header: {
                Text("This phone")
            } footer: {
                if !PushRegistration.isCompiledIn {
                    Text("Push needs a paid developer account. Build with LOTTI_APNS=1 (see apps/ios/README.md). Without it Lotti still gets everything while the app is open or woken by the glasses.")
                }
            }
            if model.isPaired {
                backendSection
                keySection
            }
        }
        .navigationTitle("Push notifications")
        .errorAlert($error)
        .task {
            hasToken = model.store.apnsToken != nil
            await loadStatus()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                keyText = text
                keyName = url.lastPathComponent
                if keyID.isEmpty, let id = url.lastPathComponent.split(separator: "_").last?.split(separator: ".").first { keyID = String(id) }
            } else {
                error = "That file couldn't be read."
            }
        }
    }

    @ViewBuilder private var backendSection: some View {
        Section("Lotti Brain") {
            let configured = status?.flag("apnsConfigured") ?? false
            StatusRow(title: "APNs key", value: configured ? "Configured" : "Not set", good: configured)
            LabeledContent("Queued items", value: "\(Int(status?["queued"]?.number ?? 0))")
            ForEach(Array((status?["devices"]?.array ?? []).enumerated()), id: \.offset) { _, device in
                LabeledContent(device.text("name") ?? "Device") {
                    Text(device.flag("hasApnsToken") ? "Token known" : "No token").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var keySection: some View {
        Section {
            TextField("Key ID", text: $keyID).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Team ID", text: $teamID).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Topic (bundle id)", text: $topic).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Production APNs", isOn: $production)
            Button(keyName.map { "Key file: \($0)" } ?? "Choose .p8 key file", systemImage: "key") { importing = true }
            Button("Send key to Lotti Brain") { saveKey() }
                .disabled(keyID.isEmpty || teamID.isEmpty || keyText.isEmpty)
            if status?.flag("apnsConfigured") == true {
                Button("Send a test push") { sendTest() }
                Button("Remove the APNs key", role: .destructive) { removeKey() }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("APNs key")
        } footer: {
            Text("Create a key with the APNs capability at developer.apple.com → Keys and download the .p8 file. It is stored encrypted on your Lotti Brain and never shown again. Use Production for TestFlight and App Store builds.")
        }
    }

    private func saveKey() {
        var input: [String: JSONValue] = ["key": .string(keyText.trimmingCharacters(in: .whitespacesAndNewlines)), "keyId": .string(keyID),
                                          "teamId": .string(teamID), "topic": .string(topic), "production": .bool(production)]
        input["keyId"] = .string(keyID.trimmingCharacters(in: .whitespaces))
        Task {
            await attempt($error) {
                _ = try await model.call("push.configure", .object(input))
                keyText = ""
                keyName = nil
                note = "Saved."
                await loadStatus()
            }
        }
    }

    private func sendTest() {
        Task {
            await attempt($error) {
                let results = try await model.call("push.test").items
                note = results.isEmpty ? "Sent." : results.map { ($0.text("device") ?? "device") + ": " + ($0.flag("ok") ? "sent" : ($0.text("error") ?? "failed")) }.joined(separator: "\n")
            }
        }
    }

    private func removeKey() {
        Task {
            await attempt($error) {
                _ = try await model.call("push.clear")
                note = "APNs key removed."
                await loadStatus()
            }
        }
    }

    private func loadStatus() async { status = try? await model.call("push.status") }
}
