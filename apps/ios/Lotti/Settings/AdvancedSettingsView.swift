import LottiKit
import SwiftUI

/// One backend setting from `settings.list`.
struct SettingInfo: Identifiable, Equatable {
    enum Kind { case bool, number, string, list, other }

    var key: String
    var value: JSONValue
    var defaultValue: JSONValue
    var description: String
    /// Safety settings change what the agent may do; they are saved with `settings.set_safety`.
    var safety: Bool
    /// Set when another screen owns the key (`providers` → AI providers); read-only here.
    var managedBy: String?

    var id: String { key }

    init?(_ json: JSONValue) {
        guard let key = json.text("key") else { return nil }
        self.key = key
        value = json["value"] ?? .null
        defaultValue = json["default"] ?? .null
        description = json.text("description") ?? ""
        safety = json.flag("safety")
        managedBy = json.text("managedBy")
    }

    /// From the default, so a value of the wrong type still gets the right editor.
    var kind: Kind {
        switch defaultValue {
        case .bool: .bool
        case .number: .number
        case .string: .string
        case .array: .list
        default: .other
        }
    }

    var isDefault: Bool { value == defaultValue }

    /// The first part of the key ("agent" for `agent.max_rounds`), for the sections.
    var group: String { String(key.split(separator: ".").first ?? Substring(key)) }

    static func display(_ value: JSONValue) -> String {
        switch value {
        case .bool(let on): on ? "On" : "Off"
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let text): text.isEmpty ? "(empty)" : text
        case .array(let items): items.isEmpty ? "(none)" : items.map { $0.string ?? $0.json }.joined(separator: ", ")
        case .null: "–"
        case .object: value.json
        }
    }
}

/// Every Lotti Brain setting (`settings.list`): what it does, its value and default. Safety
/// settings save with `settings.set_safety`, the rest with `settings.set`; keys another screen owns
/// (AI providers) are shown read-only.
struct AdvancedSettingsView: View {
    var body: some View {
        Loaded(load: { model in try await model.call("settings.list").items.compactMap(SettingInfo.init) }) { settings, reload in
            List {
                ForEach(groups(settings), id: \.self) { group in
                    Section(group) {
                        ForEach(settings.filter { $0.group == group }) { setting in
                            NavigationLink { SettingDetailView(setting: setting, onChange: reload) } label: { row(setting) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Advanced")
    }

    /// Section names in the backend's order.
    private func groups(_ settings: [SettingInfo]) -> [String] {
        var seen: [String] = []
        for setting in settings where !seen.contains(setting.group) { seen.append(setting.group) }
        return seen
    }

    private func row(_ setting: SettingInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(setting.key).font(.callout.monospaced())
                if setting.safety { Image(systemName: "shield.lefthalf.filled").font(.caption).foregroundStyle(.orange) }
            }
            Text(SettingInfo.display(setting.value)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// One setting: its description, current value and default, an editor that fits its type, Save,
/// and Reset to default (not for safety settings: the backend refuses).
struct SettingDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var setting: SettingInfo
    let onChange: @MainActor () async -> Void

    @State private var flag = false
    @State private var number = 0.0
    @State private var text = ""
    @State private var busy = false
    @State private var outcome: Outcome?

    struct Outcome: Equatable {
        var ok: Bool
        var text: String
    }

    init(setting: SettingInfo, onChange: @escaping @MainActor () async -> Void) {
        _setting = State(initialValue: setting)
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section {
                if !setting.description.isEmpty { Text(setting.description) }
                LabeledContent("Current", value: SettingInfo.display(setting.value))
                LabeledContent("Default", value: SettingInfo.display(setting.defaultValue))
                if setting.safety {
                    Label("Safety setting: it changes what Lotti may do.", systemImage: "shield.lefthalf.filled")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(setting.key)
            }
            if setting.managedBy != nil {
                Section {
                    Text(setting.managedBy == "providers" ? "Change in AI providers." : "Changed on its own settings screen.")
                        .foregroundStyle(.secondary)
                }
            } else if setting.kind == .other {
                Section { Text("This setting can't be edited here.").foregroundStyle(.secondary) }
            } else {
                Section {
                    editor
                    Button {
                        save()
                    } label: {
                        if busy { ProgressView() } else { Text("Save") }
                    }
                    .disabled(busy || !changed)
                    if !setting.safety {
                        Button("Reset to default") { reset() }
                            .disabled(busy || setting.isDefault)
                    }
                } footer: {
                    if setting.kind == .list { Text("Separate the entries with commas.") }
                }
            }
            if let outcome {
                Section {
                    Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(outcome.ok ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle(setting.key)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fill(from: setting.value) }
    }

    @ViewBuilder private var editor: some View {
        switch setting.kind {
        case .bool:
            Toggle("Value", isOn: $flag)
        case .number:
            TextField("Value", value: $number, format: .number)
                .keyboardType(.decimalPad)
        case .string:
            TextField("Value", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .list:
            TextField("Entries", text: $text, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .other:
            EmptyView()
        }
    }

    /// What the editor holds now, as the backend's JSON.
    private var edited: JSONValue? {
        switch setting.kind {
        case .bool: .bool(flag)
        case .number: .number(number)
        case .string: .string(text)
        case .list:
            .array(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { .string($0) })
        case .other: nil
        }
    }

    private var changed: Bool { edited.map { $0 != setting.value } ?? false }

    private func fill(from value: JSONValue) {
        switch value {
        case .bool(let on): flag = on
        case .number(let value): number = value
        case .string(let value): text = value
        case .array(let items): text = items.compactMap(\.string).joined(separator: ", ")
        default: break
        }
    }

    private func save() {
        guard let value = edited else { return }
        run(setting.safety ? "settings.set_safety" : "settings.set", ["key": .string(setting.key), "value": value], done: "Saved.")
    }

    private func reset() {
        run("settings.reset", ["key": .string(setting.key)], done: "Back to the default.")
    }

    private func run(_ op: String, _ input: JSONValue, done: String) {
        busy = true
        outcome = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.call(op, input)
                let value = result["value"] ?? input["value"] ?? setting.defaultValue
                setting.value = value
                fill(from: value)
                outcome = Outcome(ok: true, text: done)
                await onChange()
            } catch {
                outcome = Outcome(ok: false, text: error.localizedDescription)
            }
        }
    }
}
