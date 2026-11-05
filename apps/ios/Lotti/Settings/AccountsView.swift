import AuthenticationServices
import LottiKit
import SwiftUI

/// Accounts Lotti Brain reads for you: Google, iCloud, mail (IMAP), calendars (CalDAV), Bring!.
/// Passwords and tokens are write-only: they go to the backend and never come back.
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @State private var adding: AccountKind?
    @State private var googleSetup = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Loaded(load: { model in try await model.call("accounts.list").items.compactMap(AccountInfo.init) }) { accounts, reload in
            List {
                Section("Accounts") {
                    if accounts.isEmpty { Text("No accounts yet.").foregroundStyle(.secondary) }
                    ForEach(accounts.filter { $0.kind != "bring" }) { account in
                        NavigationLink { AccountDetailView(account: account) } label: {
                            LabeledContent {
                                Text(account.isConnected ? "Connected" : account.status.isEmpty ? "Not checked" : account.status.capitalized)
                                    .foregroundStyle(account.isConnected ? .green : .secondary)
                            } label: {
                                Label(account.label, systemImage: AccountKind(rawValue: account.kind)?.icon ?? "person.crop.circle")
                            }
                        }
                    }
                }
                Section {
                    Button { signInWithGoogle(reload) } label: {
                        Label("Google (Mail, Calendar)", systemImage: AccountKind.google.icon)
                    }
                    .disabled(working)
                    ForEach([AccountKind.icloud, .imap, .caldav], id: \.self) { kind in
                        Button { adding = kind } label: { Label(kind.title, systemImage: kind.icon) }
                    }
                    Button("Google OAuth client…", systemImage: "key") { googleSetup = true }
                } header: {
                    Text("Add an account")
                } footer: {
                    Text("Google needs an OAuth client of your own (Google Cloud console → Credentials). Enter it once under \"Google OAuth client\".")
                }
                BringSection(accounts: accounts) { await reload() }
            }
            .sheet(item: $adding) { kind in
                NavigationStack { AddAccountView(kind: kind) { await reload() } }
            }
            .sheet(isPresented: $googleSetup) { NavigationStack { GoogleClientView() } }
            .errorAlert($error)
        }
        .navigationTitle("Accounts")
    }

    /// Google's OAuth in the system browser sheet: the backend builds the login URL, the browser
    /// comes back to `lotti://oauth?code=…&state=…`, the backend trades the code for tokens.
    private func signInWithGoogle(_ reload: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            defer { working = false }
            await attempt($error) {
                let start = try await model.call("accounts.google_auth_url")
                guard let text = start.text("url"), let url = URL(string: text) else { throw BackendError.badResponse }
                let callback: URL
                do {
                    callback = try await webAuthentication.authenticate(using: url, callbackURLScheme: "lotti")
                } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
                    return  // you closed the login sheet: nothing went wrong
                }
                guard let result = OAuthCallback(callback) else { throw BackendError.badResponse }
                if let problem = result.error { throw BackendError.server(problem) }
                guard let code = result.code, let state = result.state ?? start.text("state") else { throw BackendError.badResponse }
                _ = try await model.call("accounts.google_exchange", ["code": .string(code), "state": .string(state)])
                await reload()
            }
        }
    }
}

/// `lotti://oauth?code=…&state=…` (or `error=…`) after a browser login.
struct OAuthCallback: Equatable {
    var code: String?
    var state: String?
    var error: String?

    init?(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        code = value("code")
        state = value("state")
        error = value("error")
        if code == nil && error == nil { return nil }
    }
}

enum AccountKind: String, Identifiable, CaseIterable {
    case google, icloud, imap, caldav
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .icloud: "iCloud (Mail, Calendar)"
        case .imap: "Mail (IMAP)"
        case .caldav: "Calendar (CalDAV)"
        }
    }

    var icon: String {
        switch self {
        case .google: "g.circle"
        case .icloud: "icloud"
        case .imap: "envelope"
        case .caldav: "calendar"
        }
    }
}

/// The Google OAuth client Lotti Brain signs in with (stored write-only on the backend).
struct GoogleClientView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecretField(title: "Client secret (if it has one)", text: $clientSecret)
            } footer: {
                Text("Create an OAuth client in the Google Cloud console and allow the redirect lotti://oauth. Both values are stored encrypted on your Lotti Brain.")
            }
        }
        .navigationTitle("Google OAuth client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var input: [String: JSONValue] = ["clientId": .string(clientId.trimmingCharacters(in: .whitespaces))]
                    if !clientSecret.isEmpty { input["clientSecret"] = .string(clientSecret) }
                    Task {
                        await attempt($error) {
                            _ = try await model.call("accounts.set_google_client", .object(input))
                            dismiss()
                        }
                    }
                }
                .disabled(clientId.isEmpty)
            }
        }
        .errorAlert($error)
    }
}

/// A new iCloud, IMAP or CalDAV account: non-secret settings go in `config`, the password
/// is stored write-only.
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: AccountKind
    let done: @MainActor () async -> Void
    @State private var label = ""
    @State private var user = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = ""
    @State private var url = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label, prompt: Text(kind.title))
                TextField(kind == .icloud ? "Apple ID" : "User name", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                SecretField(title: kind == .icloud ? "App-specific password" : "Password", text: $password)
                if kind == .imap {
                    TextField("Server (imap.example.com)", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port (993)", text: $port).keyboardType(.numberPad)
                }
                if kind == .caldav {
                    TextField("Server URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
            } footer: {
                if kind == .icloud {
                    Text("Create an app-specific password at account.apple.com → Sign-In and Security. Your Apple ID password does not work.")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { save() }.disabled(saving || user.isEmpty || password.isEmpty || (kind == .imap && host.isEmpty) || (kind == .caldav && url.isEmpty))
            }
        }
        .errorAlert($error)
    }

    /// Non-secret settings as the backend reads them (`username`, `imapHost`/`imapPort`, CalDAV `url`).
    var config: [String: JSONValue] {
        var config: [String: JSONValue] = ["username": .string(user)]
        if kind == .imap {
            config["imapHost"] = .string(host)
            if let number = Int(port) { config["imapPort"] = .number(Double(number)) }
        }
        if kind == .caldav { config["url"] = .string(url) }
        return config
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            await attempt($error) {
                let added = try await model.call("accounts.add", ["kind": .string(kind.rawValue), "label": .string(label.isEmpty ? kind.title : label),
                                                                  "config": .object(config)])
                guard let id = added.text("id") else { throw BackendError.badResponse }
                _ = try await model.call("accounts.set_credential", ["id": .string(id), "key": "password", "value": .string(password)])
                _ = try? await model.call("accounts.check", ["id": .string(id)])
                await done()
                dismiss()
            }
        }
    }
}

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: AccountInfo
    @State private var label: String
    @State private var enabled: Bool
    @State private var calendarService: Bool
    @State private var mailService: Bool
    @State private var status: String
    @State private var problem: String?
    @State private var lastSync: Date?
    @State private var password = ""
    @State private var calendars: [Selectable]?
    @State private var mailboxes: [Selectable]?
    @State private var allMailboxes: Bool
    /// Config as last saved from this screen: `accounts.update` replaces the whole config.
    @State private var config: [String: JSONValue]
    @State private var selectionNote: String?
    @State private var checking = false
    @State private var confirmDelete = false
    @State private var error: String?

    init(account: AccountInfo) {
        self.account = account
        _label = State(initialValue: account.label)
        _enabled = State(initialValue: account.isEnabled)
        _calendarService = State(initialValue: account.service("calendar") ?? (account.kind != "imap"))
        _mailService = State(initialValue: account.service("mail") ?? (account.kind != "caldav"))
        _status = State(initialValue: account.status)
        _problem = State(initialValue: account.lastError)
        _lastSync = State(initialValue: account.lastSync)
        _allMailboxes = State(initialValue: account.config["allMailboxes"]?.boolValue ?? false)
        _config = State(initialValue: account.config)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label).onSubmit { saveSettings() }
                StatusRow(title: "Status", value: status.isEmpty ? "Not checked" : status.capitalized, good: ["ok", "connected"].contains(status))
                LabeledContent("Last sync", value: shortDate(lastSync))
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Button { check() } label: { if checking { ProgressView() } else { Text("Check connection") } }
                    .disabled(checking)
            }
            Section {
                Toggle("Use this account", isOn: $enabled)
                Toggle("Calendar", isOn: $calendarService)
                Toggle("Mail", isOn: $mailService)
                Button("Save") { saveSettings() }
            } header: {
                Text("What it is used for")
            }
            if account.kind != "google" {
                Section("Password") {
                    SecretField(title: "Replace password", text: $password)
                    Button("Save password") {
                        Task {
                            await attempt($error) {
                                _ = try await model.call("accounts.set_credential", ["id": .string(account.id), "key": "password", "value": .string(password)])
                                password = ""
                                check()
                            }
                        }
                    }
                    .disabled(password.isEmpty)
                }
            }
            selectionSection("Calendars", items: $calendars, empty: "Check the connection to list the calendars.", note: "No selection means all of them.") {
                config["calendars"] = .array($0.map { .string($0) })
                return try await model.call("accounts.set_calendars", ["id": .string(account.id), "calendars": .array($0.map { .string($0) })])
            }
            if account.kind != "google" {
                Section {
                    Toggle("All folders", isOn: Binding(get: { allMailboxes }, set: { setAllMailboxes($0) }))
                } footer: {
                    Text("Searches every folder except Trash, Spam, Drafts and the duplicate \"All Mail\", Starred and Important folders. Folders you add later are included.")
                }
                if allMailboxes {
                    Section {
                        ForEach(mailboxes ?? []) { box in
                            LabeledContent(box.name, value: box.selected ? "Included" : "Left out")
                        }
                    } header: {
                        Text("Mailboxes")
                    }
                } else {
                    selectionSection("Mailboxes", items: $mailboxes, empty: "Check the connection to list the mailboxes.", note: "No selection means the inbox only.") {
                        config["mailboxes"] = .array($0.map { .string($0) })
                        return try await model.call("accounts.set_mailboxes", ["id": .string(account.id), "mailboxes": .array($0.map { .string($0) })])
                    }
                }
            }
            Section {
                Button("Remove account", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(account.label)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .task { await loadSelections() }
        .confirmationDialog("Remove \(account.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await attempt($error) {
                        _ = try await model.call("accounts.delete", ["id": .string(account.id)])
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Its stored credentials are deleted on Lotti Brain.")
        }
    }

    /// Toggles for the calendars or mailboxes the account offers; each change is saved at once.
    @ViewBuilder private func selectionSection(
        _ title: String, items: Binding<[Selectable]?>, empty: String, note: String,
        save: @escaping @MainActor ([String]) async throws -> JSONValue
    ) -> some View {
        Section {
            if let list = items.wrappedValue {
                if list.isEmpty { Text(empty).foregroundStyle(.secondary) }
                ForEach(list) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { items.wrappedValue?.first { $0.id == item.id }?.selected ?? false },
                        set: { on in
                            guard var current = items.wrappedValue, let index = current.firstIndex(where: { $0.id == item.id }) else { return }
                            current[index].selected = on
                            items.wrappedValue = current
                            let chosen = current.filter(\.selected).map(\.id)
                            Task { await attempt($error) { _ = try await save(chosen) } }
                        }))
                }
            } else {
                Text(empty).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            Text(note)
        }
    }

    private func loadSelections() async {
        calendars = (try? await model.call("accounts.calendars", ["id": .string(account.id)]))?.items.compactMap(Selectable.init)
        if account.kind != "google" {
            mailboxes = (try? await model.call("accounts.mailboxes", ["id": .string(account.id)]))?.items.compactMap(Selectable.init)
        }
    }

    private func setAllMailboxes(_ on: Bool) {
        allMailboxes = on
        Task {
            // Only the mode: the server keeps the explicit selection, so switching off restores it.
            let saved = await attempt($error) {
                _ = try await model.call("accounts.set_mailboxes", ["id": .string(account.id), "all": .bool(on)])
            }
            if saved { config["allMailboxes"] = .bool(on) } else { allMailboxes = !on }
            await loadSelections()
        }
    }

    private func saveSettings() {
        config["enabled"] = .bool(enabled)
        config["calendar"] = .bool(calendarService)
        config["mail"] = .bool(mailService)
        Task {
            await attempt($error) {
                _ = try await model.call("accounts.update", ["id": .string(account.id), "label": .string(label), "config": .object(config)])
            }
        }
    }

    private func check() {
        checking = true
        Task {
            defer { checking = false }
            await attempt($error) {
                let result = try await model.call("accounts.check", ["id": .string(account.id)])
                status = result.text("status") ?? (result.flag("ok") ? "ok" : "error")
                problem = result.text("error")
                if status == "ok" { lastSync = .now }
                await loadSelections()
            }
        }
    }
}

/// Bring! (shopping list): login with its e-mail and password, default list, status, logout.
struct BringSection: View {
    @Environment(AppModel.self) private var model
    let accounts: [AccountInfo]
    let changed: @MainActor () async -> Void
    @State private var status: JSONValue?
    @State private var lists: [Selectable] = []
    @State private var email = ""
    @State private var password = ""
    @State private var confirmLogout = false
    @State private var error: String?

    var body: some View {
        Section {
            let connected = status?.flag("connected") ?? false
            StatusRow(title: "Status", value: connected ? "Connected" : "Not connected", good: connected)
            if let problem = status?.text("error"), !connected { Text(problem).font(.footnote).foregroundStyle(.red) }
            if connected {
                if let who = status?.text("account") ?? status?.text("email") { LabeledContent("Account", value: who) }
                if !lists.isEmpty {
                    Picker("Default list", selection: Binding(
                        get: { status?.text("defaultList") ?? "" },
                        set: { id in
                            Task {
                                await attempt($error) { _ = try await model.call("bring.set_default_list", ["listId": .string(id)]) }
                                await load()
                            }
                        })) {
                        ForEach(lists) { Text($0.name).tag($0.id) }
                    }
                }
            }
            if let account = accounts.first(where: { $0.kind == "bring" }), connected || !account.status.isEmpty {
                Button("Log out of Bring!", role: .destructive) { confirmLogout = true }
                    .confirmationDialog("Log out of Bring!?", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("Log out", role: .destructive) {
                            Task {
                                await attempt($error) { _ = try await model.call("accounts.delete", ["id": .string(account.id)]) }
                                await load()
                                await changed()
                            }
                        }
                    } message: {
                        Text("Lotti can't change your shopping list until you log in again.")
                    }
            }
            if !connected {
                TextField("E-mail", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                SecretField(title: "Password", text: $password)
                Button("Log in") {
                    Task {
                        await attempt($error) {
                            _ = try await model.call("bring.login", ["email": .string(email), "password": .string(password)])
                            password = ""
                        }
                        await load()
                        await changed()
                    }
                }
                .disabled(email.isEmpty || password.isEmpty)
            }
        } header: {
            Text("Bring! shopping list")
        } footer: {
            Text("Lotti adds and removes items by voice; every change has an Undo.")
        }
        .errorAlert($error)
        .task { await load() }
    }

    private func load() async {
        status = try? await model.call("bring.status")
        if status?.flag("connected") == true {
            lists = (try? await model.call("bring.lists"))?.items.compactMap(Selectable.init) ?? []
        } else {
            lists = []
        }
    }
}
