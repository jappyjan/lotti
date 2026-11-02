import LottiKit
import Security
import SwiftUI

/// Where your Hermes is, and which phone facts it may read.
struct HermesView: View {
    let client: HermesClient
    /// Its conversation is forgotten when it could reach another server or a hidden read.
    let hermes: HermesBrain
    let readTools: [PhoneToolSpec]

    @State private var address = Settings.hermesAddress
    @State private var key = Settings.hermesKey
    @State private var hiddenReads = Settings.hermesHiddenReads
    @State private var conversationMinutes = Settings.hermesConversationMinutes
    @State private var check: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                TextField("https://hermes.example.ts.net", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API key (API_SERVER_KEY)", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(checking ? "Checking…" : "Save and test") { Task { await saveAndTest() } }
                    .disabled(checking || address.isEmpty || key.isEmpty)
                if let check { Text(check).foregroundStyle(.secondary) }
            } header: {
                Text("Your Hermes")
            } footer: {
                Text("Hermes's API server, e.g. through Tailscale. Say \"Hermes, …\" or pick \"Ask Hermes\" on the glasses; Lotti also asks Hermes when she can't answer herself.")
            }

            Section {
                ForEach(readTools, id: \.name) { tool in
                    Toggle(isOn: Binding(
                        get: { !hiddenReads.contains(tool.name) },
                        set: { shared in
                            if shared { hiddenReads.remove(tool.name) } else { hiddenReads.insert(tool.name) }
                            Settings.hermesHiddenReads = hiddenReads
                            // What Hermes already read stays in the conversation; hiding it starts fresh.
                            if !shared { hermes.endConversation() }
                        })) {
                        Text(tool.name.capitalized)
                        Text(tool.description)
                    }
                }
            } header: {
                Text("Hermes may read")
            } footer: {
                Text("Hermes asks for these only when a question needs them. Timers and reminders always wait for your tap on the glasses.")
            }

            Section {
                Picker("Start fresh after", selection: Binding(
                    get: { conversationMinutes },
                    set: { conversationMinutes = $0; Settings.hermesConversationMinutes = $0 })) {
                    ForEach(Self.conversationMinutes, id: \.self) { minutes in
                        Text(Self.conversationLabel(minutes)).tag(minutes)
                    }
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("After this long without a question, Hermes starts a new conversation. Say \"Neues Gespräch\" or \"New chat\" to start one right away.")
            }

            if Settings.hermesConfig != nil {
                Section {
                    Button("Remove Hermes", role: .destructive) {
                        address = ""
                        key = ""
                        Settings.hermesAddress = ""
                        Settings.hermesKey = ""
                        check = nil
                        hermes.endConversation()
                    }
                }
            }
        }
        .navigationTitle("Hermes")
    }

    private static let conversationMinutes = [15, 30, 60, 120, 240, 480, 1440]

    private static func conversationLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return "1 day" }
        if minutes >= 60, minutes.isMultiple(of: 60) { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }

    private func saveAndTest() async {
        guard HermesConfig(address: address, key: key) != nil else {
            check = "That address doesn't look right."
            return
        }
        // Another server must not get the old conversation.
        if HermesConfig(address: address, key: key)?.url != Settings.hermesConfig?.url { hermes.endConversation() }
        Settings.hermesAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.hermesKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        defer { checking = false }
        do {
            check = "Connected to \(try await client.check())."
        } catch {
            check = "Saved, but: \(error.localizedDescription)"
        }
    }
}

extension Settings {
    static let hermesAddressKey = "hermesAddress"
    static let hermesHiddenReadsKey = "hermesHiddenReads"
    static let hermesConversationMinutesKey = "hermesConversationMinutes"

    /// How long Hermes remembers a conversation after your last question, in minutes (default 2 h).
    static var hermesConversationMinutes: Int {
        get { UserDefaults.standard.object(forKey: hermesConversationMinutesKey) as? Int ?? 120 }
        set { UserDefaults.standard.set(newValue, forKey: hermesConversationMinutesKey) }
    }

    /// The conversation limit as a `Duration`, read by `HermesBrain` at every question.
    static var hermesConversationLimit: Duration {
        .seconds(hermesConversationMinutes * 60)
    }

    static var hermesAddress: String {
        get { UserDefaults.standard.string(forKey: hermesAddressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hermesAddressKey) }
    }

    /// In the Keychain, not in UserDefaults.
    static var hermesKey: String {
        get { Keychain.read("hermesKey") ?? "" }
        set { Keychain.write("hermesKey", newValue) }
    }

    /// Nil until both address and key are set.
    static var hermesConfig: HermesConfig? {
        HermesConfig(address: hermesAddress, key: hermesKey)
    }

    /// Read tools you don't share with Hermes. New tools are shared by default.
    static var hermesHiddenReads: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hermesHiddenReadsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hermesHiddenReadsKey) }
    }
}

/// A few strings in the Keychain, readable after the first unlock (Lotti works with the phone locked).
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.janjaap.lotti",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
