import LottiKit
import SwiftUI
import UIKit

/// AI providers: which one answers (and which one is the fallback), API keys (write-only),
/// subscription logins (Codex, Claude) and models.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Loaded(load: { model in try await model.call("providers.list").items.compactMap(ProviderInfo.init) }) { providers, reload in
            List {
                Section {
                    Picker("Answers with", selection: Binding(
                        get: { providers.first(where: \.active)?.id ?? "" },
                        set: { id in
                            // The fallback can't be the active one too: picking it clears the fallback.
                            let fallback = providers.first(where: \.fallback)?.id ?? ""
                            select(active: id, fallback: fallback == id ? "" : fallback, reload)
                        })) {
                        ForEach(providers) { Text(pickerLabel($0)).tag($0.id) }
                    }
                    Picker("Fallback", selection: Binding(
                        get: { providers.first(where: \.fallback)?.id ?? "" },
                        set: { id in select(active: providers.first(where: \.active)?.id ?? "", fallback: id, reload) })) {
                        Text("None").tag("")
                        ForEach(providers.filter { !$0.active }) { Text(pickerLabel($0)).tag($0.id) }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("The fallback answers when the active provider fails or is too slow.")
                }
                WebSearchKeySection()
                Section("Providers") {
                    ForEach(providers) { provider in
                        NavigationLink { ProviderDetailView(provider: provider) } label: {
                            LabeledContent(provider.label) {
                                HStack(spacing: 6) {
                                    Circle().fill(provider.configured ? Color.green : Color.secondary).frame(width: 8, height: 8)
                                    Text(provider.active ? "Active" : provider.fallback ? "Fallback" : provider.configured ? "Ready" : "Not set up")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .errorAlert($error)
        }
        .navigationTitle("AI providers")
    }

    private func pickerLabel(_ provider: ProviderInfo) -> String {
        provider.configured ? provider.label : "\(provider.label) (not set up)"
    }

    private func select(active: String, fallback: String, _ reload: @escaping @MainActor () async -> Void) {
        guard !active.isEmpty else { return }
        Task {
            await attempt($error) { _ = try await model.call("providers.set_active", ["active": .string(active), "fallback": .string(fallback)]) }
            await reload()
        }
    }
}

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo
    @State private var configured: Bool
    @State private var apiKey = ""
    @State private var token = ""
    @State private var modelName: String
    @State private var thinking: String?
    @State private var suggestions: [String] = []
    @State private var login: DeviceLogin?
    @State private var loginMessage: String?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemove = false
    /// The model the backend has, to put back when the field is emptied.
    @State private var savedModel: String

    init(provider: ProviderInfo) {
        self.provider = provider
        _configured = State(initialValue: provider.configured)
        _modelName = State(initialValue: provider.model)
        _thinking = State(initialValue: provider.thinking)
        _savedModel = State(initialValue: provider.model)
    }

    /// What a subscription device login shows: open the page, type the code.
    struct DeviceLogin: Equatable {
        var url: String
        var code: String
    }

    var body: some View {
        List {
            Section {
                StatusRow(title: "Status", value: configured ? "Ready" : "Not set up", good: configured)
                if let problem = provider.lastError { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            if provider.isRuntime { subscriptionSection } else { keySection }
            modelSection
        }
        .navigationTitle(provider.label)
        .errorAlert($error)
        .confirmationDialog(provider.isRuntime ? "Sign out of \(provider.label)?" : "Remove the \(provider.label) API key?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(provider.isRuntime ? "Sign out" : "Remove key", role: .destructive) { removeCredential() }
        } message: {
            Text(provider.active ? "Lotti answers with this provider: it stops working until you set it up again." : "You can set it up again any time.")
        }
        .task { await loadModels() }
        .task(id: login) { await pollLogin() }
    }

    // MARK: Keys

    @ViewBuilder private var keySection: some View {
        Section {
            SecretField(title: configured ? "Replace API key" : "API key", text: $apiKey)
            Button("Save key") { saveCredential(apiKey) { apiKey = "" } }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            if configured {
                Button("Remove key", role: .destructive) { confirmRemove = true }
            }
        } header: {
            Text("API key")
        } footer: {
            Text("The key is stored encrypted on your Lotti Brain and is never shown again.")
        }
    }

    // MARK: Subscriptions

    @ViewBuilder private var subscriptionSection: some View {
        if provider.id == "codex" {
            Section {
                if let login {
                    LabeledContent("Code") { Text(login.code).font(.title3.monospaced()).textSelection(.enabled) }
                    if let url = URL(string: login.url) { Link("Open \(url.host() ?? "login page")", destination: url) }
                    Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = login.code }
                    ProgressView("Waiting for you to sign in…")
                }
                if let loginMessage { Text(loginMessage).font(.footnote).foregroundStyle(.secondary) }
                if model.supports("providers.codex_login_start") {
                    Button(configured ? "Sign in again" : "Sign in with ChatGPT") { startCodexLogin() }
                        .disabled(busy)
                } else {
                    Text("This Lotti Brain has no Codex login yet. Update it.").foregroundStyle(.secondary)
                }
            } header: {
                Text("ChatGPT subscription")
            } footer: {
                Text("Lotti shows a page and a code: open the page on any device, enter the code, and approve.")
            }
        } else {
            Section {
                SecretField(title: "Setup token", text: $token)
                Button("Save token") { saveCredential(token) { token = "" } }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Claude subscription")
            } footer: {
                Text("On a computer with Claude Code, run `claude setup-token`, then paste the token here. It is stored encrypted and never shown again.")
            }
        }
        if configured {
            Section {
                Button("Sign out", role: .destructive) { confirmRemove = true }
            }
        }
    }

    /// Remove key (API providers) or Sign out (subscriptions), after the confirmation.
    private func removeCredential() {
        Task {
            await attempt($error) {
                _ = try await model.call(provider.id == "codex" ? "providers.codex_logout" : "providers.clear_credential",
                                         ["provider": .string(provider.id)])
                configured = false
            }
        }
    }

    private func saveCredential(_ key: String, done: @escaping @MainActor () -> Void) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await attempt($error) {
                _ = try await model.call("providers.set_credential", ["provider": .string(provider.id), "apiKey": .string(value)])
                configured = true
                done()
            }
        }
    }

    private func startCodexLogin() {
        busy = true
        loginMessage = nil
        Task {
            defer { busy = false }
            await attempt($error) {
                let result = try await model.call("providers.codex_login_start")
                guard let found = Self.deviceLogin(result) else {
                    loginMessage = "Lotti Brain didn't send a login page and code."
                    return
                }
                login = found
            }
        }
    }

    /// Accepts the few spellings a device login answer comes in.
    static func deviceLogin(_ result: JSONValue) -> DeviceLogin? {
        let url = ["url", "verificationUrl", "verification_uri", "verificationUri"].compactMap { result.text($0) }.first
        let code = ["code", "userCode", "user_code"].compactMap { result.text($0) }.first
        guard let url, let code else { return nil }
        return DeviceLogin(url: url, code: code)
    }

    /// Asks every 3 s whether the login went through, for up to 10 minutes.
    private func pollLogin() async {
        guard login != nil else { return }
        for _ in 0..<200 {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            guard let result = try? await model.call("providers.codex_login_status") else { continue }
            let state = (result.text("state") ?? result.text("status") ?? "").lowercased()
            if result.flag("loggedIn") || result.flag("configured") || ["ok", "done", "success", "connected", "complete", "completed"].contains(state) {
                configured = true
                login = nil
                loginMessage = "Signed in."
                return
            }
            if ["error", "failed", "expired", "denied"].contains(state) {
                login = nil
                loginMessage = result.text("error") ?? "The login didn't go through."
                return
            }
        }
        login = nil
        loginMessage = "The login timed out."
    }

    // MARK: Model

    @ViewBuilder private var modelSection: some View {
        Section {
            TextField("Model", text: $modelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { setModel(modelName) }
            if !suggestions.isEmpty {
                Picker("Pick", selection: Binding(get: { modelName }, set: { modelName = $0; setModel($0) })) {
                    if !suggestions.contains(modelName) { Text(modelName.isEmpty ? "Default" : modelName).tag(modelName) }
                    ForEach(suggestions, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Return saves a typed model id. Leave it as it is to keep the current model.")
        }
        if let level = thinking {
            Section {
                Picker("Thinking", selection: Binding(get: { level }, set: { setThinking($0) })) {
                    ForEach(["off", "low", "high", "max"], id: \.self) { Text($0.capitalized).tag($0) }
                }
            } footer: {
                Text("Off answers fastest. Thinking takes longer but helps with harder questions.")
            }
        }
    }

    private func setThinking(_ level: String) {
        let previous = thinking
        thinking = level
        Task {
            let ok = await attempt($error) {
                _ = try await model.call("providers.set_thinking", ["provider": .string(provider.id), "level": .string(level)])
            }
            if !ok { thinking = previous }
        }
    }

    private func setModel(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespaces)
        // The backend needs a model id: an emptied field just shows the current one again.
        guard !value.isEmpty else { return modelName = savedModel }
        Task {
            await attempt($error) {
                _ = try await model.call("providers.set_model", ["provider": .string(provider.id), "model": .string(value)])
                savedModel = value
            }
        }
    }

    private func loadModels() async {
        guard let result = try? await model.call("providers.models", ["provider": .string(provider.id)]) else { return }
        suggestions = (result["models"]?.array ?? []).compactMap { $0.string ?? $0.text("id") }
    }
}

/// The Brave Search key behind Lotti's web search: write-only, stored as the backend secret
/// `search.brave.api_key`. The status comes from `secrets.list` (names only, never values).
private struct WebSearchKeySection: View {
    @Environment(AppModel.self) private var model
    static let secretName = "search.brave.api_key"
    @State private var isSet: Bool?
    @State private var key = ""
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        Section {
            StatusRow(title: "Key", value: isSet.map { $0 ? "Set" : "Not set" } ?? "…", good: isSet)
            SecretField(title: isSet == true ? "Replace key" : "Brave Search API key", text: $key)
            Button(isSet == true ? "Replace key" : "Save key") { save() }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isSet == true {
                Button("Remove key", role: .destructive) { confirmRemove = true }
            }
        } header: {
            Text("Web search (Brave)")
        } footer: {
            Text("Lets Lotti search the web. The key is stored encrypted on your Lotti Brain and is never shown again.")
        }
        .errorAlert($error)
        .confirmationDialog("Remove the web search key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { remove() }
        } message: {
            Text("Lotti can't search the web until you add a key again.")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let secrets = try await model.call("secrets.list", ["prefix": .string("search.brave.")]).items
            isSet = secrets.contains { $0.text("name") == Self.secretName }
        } catch {
            isSet = nil
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await attempt($error) {
                _ = try await model.call("secrets.set", ["name": .string(Self.secretName), "value": .string(value)])
                key = ""
                isSet = true
            }
        }
    }

    private func remove() {
        Task {
            await attempt($error) {
                _ = try await model.call("secrets.delete", ["name": .string(Self.secretName)])
                isSet = false
            }
        }
    }
}
