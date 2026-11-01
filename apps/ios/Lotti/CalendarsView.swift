import EventKit
import SwiftUI

/// Pick which calendars Lotti reads for the today view and the chat.
struct CalendarsView: View {
    @State private var groups: [(source: String, calendars: [EKCalendar])] = []
    @State private var hidden = Settings.hiddenCalendars
    @State private var allowed = true

    var body: some View {
        List {
            if !allowed {
                Text("Lotti has no access to your calendars. Turn it on in Settings → Lotti → Calendars.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: calendar.cgColor))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Calendars")
        .task { await load() }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(id) },
            set: { shown in
                if shown { hidden.remove(id) } else { hidden.insert(id) }
                Settings.hiddenCalendars = hidden
            })
    }

    private func load() async {
        let store = EKEventStore()
        allowed = (try? await store.requestFullAccessToEvents()) ?? false
        guard allowed else { return }
        let bySource = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.title ?? "Other" }
        groups = bySource.keys.sorted().map { key in
            (key, bySource[key]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }
}
