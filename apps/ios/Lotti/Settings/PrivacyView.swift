import LottiKit
import SwiftUI

/// Who read what: every location read (this phone's own log and the backend's) and every shell
/// command the agent ran, plus the switches that allow them.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        List {
            Section {
                NavigationLink("Location reads") { LocationLogView() }
                NavigationLink("Shell commands") { ShellLogView() }
            }
            if model.isPaired {
                Section {
                    SafetyToggle(title: "Lotti may read my location", key: "location.enabled")
                    SafetyToggle(title: "Lotti may run shell commands", key: "shell.enabled")
                    SafetyToggle(title: "Lotti may fetch web pages", key: "web_fetch.enabled")
                } header: {
                    Text("Allowed")
                } footer: {
                    Text("Safety switches. Changing one asks the backend with your tap here; Lotti itself can only propose a change.")
                }
            }
        }
        .navigationTitle("Privacy")
    }
}

/// A backend safety setting as a switch (`settings.list` for the value, `settings.set_safety` to change it).
private struct SafetyToggle: View {
    @Environment(AppModel.self) private var model
    let title: String
    let key: String
    /// Unknown until the backend said; the switch stays off and disabled until then.
    @State private var on: Bool?
    @State private var loadError: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { on ?? false }, set: { value in
                let previous = on
                on = value
                Task {
                    do {
                        _ = try await model.call("settings.set_safety", ["key": .string(key), "value": .bool(value)])
                    } catch {
                        on = previous  // the backend kept the old value
                        self.error = error.localizedDescription
                    }
                }
            }))
            .disabled(on == nil)
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
        }
        .errorAlert($error)
        .task { await load() }
    }

    private func load() async {
        do {
            if let value = try await model.call("settings.get", ["key": .string(key)])["value"]?.boolValue {
                on = value
                loadError = nil
            } else {
                loadError = "Lotti Brain didn't send this setting."
            }
        } catch {
            loadError = "Couldn't load: \(error.localizedDescription)"
        }
    }
}

struct LocationLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if model.locationLog.entries.isEmpty { Text("No reads since this log started.").foregroundStyle(.secondary) }
                ForEach(model.locationLog.entries) { entry in
                    LabeledContent(shortDate(entry.start)) {
                        Text(entry.end.map { String(format: "%.1f s", $0.timeIntervalSince(entry.start)) } ?? "…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("On this phone")
            } footer: {
                Button("Clear this phone's log", role: .destructive) { model.locationLog.clear() }
            }
            if model.isPaired {
                BackendLocationLog()
            }
        }
        .navigationTitle("Location reads")
    }
}

private struct BackendLocationLog: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LocationLogEntry] = []
    @State private var failure: String?

    var body: some View {
        Section {
            if let failure { Text(failure).foregroundStyle(.red) }
            ForEach(entries) { entry in
                LabeledContent(shortDate(entry.at)) {
                    Text("\(entry.source)\(entry.ok ? "" : " · failed")").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("On Lotti Brain")
        }
        .task {
            do {
                entries = try await model.call("privacy.location_log", ["limit": 50]).items.compactMap(LocationLogEntry.init)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct ShellLogView: View {
    var body: some View {
        Loaded(load: { model in try await model.call("privacy.shell_log", ["limit": 50]).items.compactMap(ShellLogEntry.init) }) { entries, _ in
            List {
                if entries.isEmpty { Text("The agent hasn't run any command.").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    NavigationLink {
                        List {
                            Section("Command") { Text(entry.command).font(.callout.monospaced()).textSelection(.enabled) }
                            Section("Result") {
                                LabeledContent("Exit code", value: entry.exitCode.map(String.init) ?? "–")
                                LabeledContent("Duration", value: "\(entry.durationMs) ms")
                                if entry.timedOut { Text("Timed out").foregroundStyle(.red) }
                            }
                            Section("Output") { Text(entry.output.isEmpty ? "(none)" : entry.output).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        .navigationTitle("Command")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.command).font(.callout.monospaced()).lineLimit(2)
                            Text("\(shortDate(entry.at)) · exit \(entry.exitCode.map(String.init) ?? "–")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Shell commands")
    }
}
