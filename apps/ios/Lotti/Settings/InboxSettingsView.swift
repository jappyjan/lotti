import LottiKit
import SwiftUI

/// Inbox and catch-up: the inbox itself, and when Lotti briefs you after you were away.
struct InboxSettingsView: View {
    var body: some View {
        Loaded(load: { model in
            let settings = CatchupSettings(try await model.call("catchup.get_settings"))
            let recent = (try? await model.call("catchup.recent", ["limit": 10]))?.items ?? []
            return (settings, recent)
        }) { loaded, _ in
            CatchupForm(initial: loaded.0, recent: loaded.1)
        }
        .navigationTitle("Inbox & catch-up")
    }
}

private struct CatchupForm: View {
    @Environment(AppModel.self) private var model
    @State private var settings: CatchupSettings
    @State private var recent: [JSONValue]
    @State private var generating = false
    @State private var error: String?

    init(initial: CatchupSettings, recent: [JSONValue]) {
        _settings = State(initialValue: initial)
        _recent = State(initialValue: recent)
    }

    var body: some View {
        Form {
            Section {
                NavigationLink("Inbox") { InboxView() }
            }
            Section {
                Toggle("Brief me when I'm back", isOn: $settings.enabled)
                Stepper("Away for \(settings.awayHours.formatted()) h or more", value: $settings.awayHours, in: 0.5...24, step: 0.5)
                Toggle("Include the weather", isOn: $settings.useWeather)
            } header: {
                Text("Catch-up")
            } footer: {
                Text("One brief per return: when you were away from phone and glasses for that long, or slept through the night window. It arrives in the chat and on the glasses.")
            }
            Section {
                DatePicker("Night starts", selection: time($settings.nightStart), displayedComponents: .hourAndMinute)
                DatePicker("Night ends", selection: time($settings.nightEnd), displayedComponents: .hourAndMinute)
                Stepper("Counts as slept after \(settings.sleepMinHours.formatted()) h", value: $settings.sleepMinHours, in: 0...12, step: 0.5)
            } header: {
                Text("Night window")
            } footer: {
                Text("While the phone is charging or still inside this window, a long gap counts as a night's sleep.")
            }
            Section {
                Button { generate() } label: { if generating { ProgressView() } else { Text("Brief me now") } }
                    .disabled(generating)
            }
            Section("Last briefs") {
                if recent.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(Array(recent.enumerated()), id: \.offset) { _, brief in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shortDate(brief.date("at"))).font(.caption).foregroundStyle(.secondary)
                        Text(brief.text("text") ?? "").textSelection(.enabled)
                    }
                }
            }
        }
        .errorAlert($error)
        .onChange(of: settings) { save() }
    }

    private func save() {
        Task { await attempt($error) { _ = try await model.call("catchup.set_settings", settings.json) } }
    }

    private func generate() {
        generating = true
        Task {
            defer { generating = false }
            await attempt($error) {
                _ = try await model.call("catchup.run_now")
                recent = (try? await model.call("catchup.recent", ["limit": 10]))?.items ?? recent
            }
        }
    }

    /// "22:00" as a Date for the picker, and back.
    private func time(_ text: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = text.wrappedValue.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(from: DateComponents(hour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0)) ?? .now
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                text.wrappedValue = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            })
    }
}
