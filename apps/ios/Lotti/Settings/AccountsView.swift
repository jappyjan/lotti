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
                    ForEach([AccountKind.icloud, .imap, .caldav, .ics], id: \.self) { kind in
                        Button { adding = kind } label: { Label(kind.title, systemImage: kind.icon) }
                    }
                    Button("Google OAuth client…", systemImage: "key") { googleSetup = true }
                } header: {
                    Text("Add an account")
                } footer: {
                    Text("Google needs an OAuth client of your own (Google Cloud console → Credentials). Enter it once under \"Google OAuth client\". An ICS calendar needs no client: paste the calendar's secret link (Google: \"Secret address in iCal format\", Microsoft 365: \"Publish calendar\").")
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

    /// Google's OAuth in the system browser sheet: the backend builds the login URL and says which scheme the
    /// browser comes back to (`callbackScheme`), then trades the code for tokens.
    private func signInWithGoogle(_ reload: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            defer { working = false }
            await attempt($error) {
                let start = try await model.call("accounts.google_auth_url")
                guard let (code, state) = try await OAuthFlow.authorize(start: start, using: webAuthentication) else { return }
                _ = try await model.call("accounts.google_exchange", ["code": .string(code), "state": .string(state)])
                await reload()
            }
        }
    }
}

enum AccountKind: String, Identifiable, CaseIterable {
    case google, icloud, imap, caldav, ics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .icloud: "iCloud (Mail, Calendar)"
        case .imap: "Mail (IMAP)"
        case .caldav: "Calendar (CalDAV)"
        case .ics: "Add ICS calendar"
        }
    }

    var icon: String {
        switch self {
        case .google: "g.circle"
        case .icloud: "icloud"
        case .imap: "envelope"
        case .caldav: "calendar"
        case .ics: "calendar.badge.clock"
        }
    }
}

/// The Google OAuth client Lotti Brain signs in with (stored write-only on the backend). The redirect URI
/// depends on the client type: an iOS client needs none, a Web client needs the one shown here in the console.
struct GoogleClientView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var redirect = ""
    @State private var info: GoogleClientInfo?
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecretField(title: "Client secret (Web client only)", text: $clientSecret)
                TextField("Redirect URI (optional)", text: $redirect).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } footer: {
                Text("An iOS client has no secret and needs nothing else. A Web client has a secret and needs the redirect below in the console. Values are stored encrypted on your Lotti Brain.")
            }
            if let info, info.configured {
                Section {
                    if let problem = info.error {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    } else {
                        LabeledContent("Client type", value: info.modeTitle)
                        if let uri = info.consoleRedirect {
                            Text(uri).font(.footnote.monospaced()).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy redirect URI", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = uri
                                copied = true
                            }
                        } else {
                            Text("iOS client: none needed").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Redirect URI")
                }
            }
        }
        .navigationTitle("Google OAuth client")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var input: [String: JSONValue] = ["clientId": .string(clientId.trimmingCharacters(in: .whitespaces))]
                    if !clientSecret.isEmpty { input["clientSecret"] = .string(clientSecret) }
                    if !redirect.isEmpty { input["redirectUri"] = .string(redirect.trimmingCharacters(in: .whitespaces)) }
                    Task {
                        await attempt($error) {
                            info = GoogleClientInfo(try await model.call("accounts.set_google_client", .object(input)))
                            copied = false
                            clientSecret = ""
                        }
                    }
                }
                .disabled(clientId.isEmpty)
            }
        }
        .errorAlert($error)
        .task { info = (try? await model.call("accounts.google_client")).map(GoogleClientInfo.init) }
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
    @State private var checked: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label, prompt: Text(kind.title))
                if kind == .ics {
                    SecretField(title: "Secret calendar link", text: $password)
                } else {
                    TextField(kind == .icloud ? "Apple ID" : "User name", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    SecretField(title: kind == .icloud ? "App-specific password" : "Password", text: $password)
                }
                if kind == .imap {
                    TextField("Server (imap.example.com)", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port (993)", text: $port).keyboardType(.numberPad)
                }
                if kind == .caldav {
                    TextField("Server URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
            } footer: {
                if kind == .ics {
                    Text("The calendar's secret link (https:// or webcal://). Anyone with the link can read the calendar: it is stored encrypted on your Lotti Brain and never shown again. Lotti only reads it.")
                } else if kind == .icloud {
                    Text("Create an app-specific password at account.apple.com → Sign-In and Security. Your Apple ID password does not work.")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { save() }.disabled(saving || (kind != .ics && user.isEmpty) || password.isEmpty || (kind == .imap && host.isEmpty) || (kind == .caldav && url.isEmpty))
            }
        }
        .errorAlert($error)
        .alert("Calendar added", isPresented: Binding(get: { checked != nil }, set: { if !$0 { checked = nil; dismiss() } })) {
            Button("OK") {}
        } message: {
            Text(checked ?? "")
        }
    }

    /// Non-secret settings as the backend reads them (`username`, `imapHost`/`imapPort`, CalDAV `url`).
    var config: [String: JSONValue] {
        if kind == .ics { return [:] }
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
                _ = try await model.call("accounts.set_credential", ["id": .string(id), "key": .string(kind == .ics ? "url" : "password"), "value": .string(password)])
                let result = try? await model.call("accounts.check", ["id": .string(id)])
                await done()
                if kind == .ics {
                    // "N events" when the link works, else why not (the account stays, fix the link in its details).
                    checked = result?.text("detail") ?? result?.text("error") ?? "Added."
                } else {
                    dismiss()
                }
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
    @State private var detail: String?
    @State private var password = ""
    @State private var calendars: [Selectable]?
    @State private var mailboxes: [Selectable]?
    @State private var selectionNote: String?
    @State private var checking = false
    @State private var confirmDelete = false
    @State private var error: String?

    init(account: AccountInfo) {
        self.account = account
        _label = State(initialValue: account.label)
        _enabled = State(initialValue: account.isEnabled)
        _calendarService = State(initialValue: account.service("calendar") ?? (account.kind != "imap"))
        _mailService = State(initialValue: account.service("mail") ?? (account.kind != "caldav" && account.kind != "ics"))
        _status = State(initialValue: account.status)
        _problem = State(initialValue: account.lastError)
        _lastSync = State(initialValue: account.lastSync)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label).onSubmit { saveSettings() }
                StatusRow(title: "Status", value: status.isEmpty ? "Not checked" : status.capitalized, good: ["ok", "connected"].contains(status))
                LabeledContent("Last sync", value: shortDate(lastSync))
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                Button { check() } label: { if checking { ProgressView() } else { Text("Check connection") } }
                    .disabled(checking)
            }
            Section {
                Toggle("Use this account", isOn: $enabled)
                Toggle("Calendar", isOn: $calendarService)
                if account.kind != "ics" { Toggle("Mail", isOn: $mailService) }
                Button("Save") { saveSettings() }
            } header: {
                Text("What it is used for")
            }
            if account.kind != "google" {
                Section(account.kind == "ics" ? "Calendar link" : "Password") {
                    SecretField(title: account.kind == "ics" ? "Replace the secret link" : "Replace password", text: $password)
                    Button(account.kind == "ics" ? "Save link" : "Save password") {
                        Task {
                            await attempt($error) {
                                _ = try await model.call("accounts.set_credential", ["id": .string(account.id), "key": .string(account.kind == "ics" ? "url" : "password"), "value": .string(password)])
                                password = ""
                                check()
                            }
                        }
                    }
                    .disabled(password.isEmpty)
                }
            }
            selectionSection("Calendars", items: $calendars, empty: "Check the connection to list the calendars.", note: "No selection means all of them.") {
                try await model.call("accounts.set_calendars", ["id": .string(account.id), "calendars": .array($0.map { .string($0) })])
            }
            if account.kind != "google" && account.kind != "ics" {
                selectionSection("Mailboxes", items: $mailboxes, empty: "Check the connection to list the mailboxes.", note: "No selection means the inbox only.") {
                    try await model.call("accounts.set_mailboxes", ["id": .string(account.id), "mailboxes": .array($0.map { .string($0) })])
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
        if account.kind != "google" && account.kind != "ics" {
            mailboxes = (try? await model.call("accounts.mailboxes", ["id": .string(account.id)]))?.items.compactMap(Selectable.init)
        }
    }

    private func saveSettings() {
        var config = account.config
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
                detail = result.text("detail")
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
