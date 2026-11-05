import AlarmKit
import CoreLocation
import EventKit
import Foundation
import LottiKit
import MapKit
import SwiftUI

/// The phone tools both brains can use. Reads run when a brain asks; actions run only after
/// you tap them on the glasses (see `Toolbox`).
enum PhoneTools {
    static func all(
        today: DeviceToday,
        startNavigation: @escaping @MainActor (String, NavigationMode) async throws -> String
    ) -> [any PhoneTool] {
        [CalendarTool(today: today), WeatherTool(today: today), LocationTool(today: today),
         RemindersTool(), SetTimerTool(), CreateReminderTool(), StartNavigationTool(start: startNavigation)]
    }

    /// The tools the on-device brain may pick from (all of them; its planner sees only names).
    static let onDevice: Set<String> = [
        "calendar", "weather", "location", "reminders", "set_timer", "create_reminder", "start_navigation",
    ]

    /// Ask for alarm and reminder access while the app is open; a locked phone can't show the prompt.
    static func requestAccess() async {
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await RemindersTool.store.requestFullAccessToReminders()
        }
    }
}

// MARK: - Reads

struct CalendarTool: PhoneTool {
    let today: DeviceToday
    let spec = PhoneToolSpec(
        name: "calendar", description: "Jan's calendar events for one or more days.",
        parameters: [
            ToolParameter("from", .string, "first day: today, tomorrow, a weekday like monday, or YYYY-MM-DD", optional: true),
            ToolParameter("days", .integer, "how many days, 1 to 14; default 1", optional: true),
        ],
        effect: .read, progress: "Checking your calendar…")

    func run(_ arguments: ToolArguments) async throws -> String {
        let text = ToolText()
        guard let start = text.day(arguments.string("from"), now: Date()) else {
            throw ToolError("calendar: from should be YYYY-MM-DD")
        }
        let days = min(max(arguments.int("days") ?? 1, 1), 14)
        let end = text.calendar.date(byAdding: .day, value: days, to: start)!
        let events = try await today.events(from: start, to: end)
        return text.events(events, from: start, days: days)
    }
}

struct WeatherTool: PhoneTool {
    let today: DeviceToday
    let spec = PhoneToolSpec(
        name: "weather", description: "The weather where Jan is: now, today and tomorrow.",
        effect: .read, progress: "Checking the weather…")

    func run(_ arguments: ToolArguments) async throws -> String {
        let now = Date()
        guard let weather = await today.currentWeather(now: now) else { throw ToolError("No weather right now.") }
        return ToolText().weather(weather, now: now)
    }
}

struct LocationTool: PhoneTool {
    let today: DeviceToday
    let spec = PhoneToolSpec(
        name: "location", description: "Where Jan is right now: street, neighbourhood and city.",
        effect: .read, progress: "Checking where you are…")

    func run(_ arguments: ToolArguments) async throws -> String {
        guard let coordinate = await today.freshLocation() else { throw ToolError("Lotti doesn't know where Jan is.") }
        let place = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let position = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: place),
              let item = try? await request.mapItems.first else { return position }
        let name = item.address?.shortAddress ?? item.addressRepresentations?.cityWithContext ?? ""
        return name.isEmpty ? position : "\(name) (\(position))"
    }
}

struct RemindersTool: PhoneTool {
    /// EventKit's store is safe to use from any thread.
    nonisolated(unsafe) static let store = EKEventStore()
    let spec = PhoneToolSpec(
        name: "reminders", description: "Jan's open reminders, soonest due first (at most 15).",
        effect: .read, progress: "Checking your reminders…")

    func run(_ arguments: ToolArguments) async throws -> String {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ToolError("Lotti has no access to reminders.")
        }
        let store = Self.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [(title: String, due: Date?)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    (title: reminder.title ?? "Reminder", due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: items)
            }
        }
        guard !items.isEmpty else { return "No open reminders." }
        let text = ToolText()
        let sorted = items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(15)
        return sorted.map { item in item.due.map { "\(item.title) (due \(text.dayAndTime($0)))" } ?? item.title }
            .joined(separator: "\n")
    }
}

// MARK: - Actions

struct TimerMetadata: AlarmMetadata {}

struct SetTimerTool: PhoneTool {
    let spec = PhoneToolSpec(
        name: "set_timer", description: "Start a countdown timer that rings on the phone.",
        parameters: [
            ToolParameter("minutes", .integer, "length in minutes, 1 to 720"),
            ToolParameter("label", .string, "what it's for, 1 to 3 words", optional: true),
        ],
        effect: .action, progress: "Setting the timer…")

    func title(for arguments: ToolArguments) -> String {
        "Timer \(arguments.int("minutes") ?? 0) min"
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        let minutes = arguments.int("minutes") ?? 0
        guard (1...720).contains(minutes) else { throw ToolError("A timer has to be 1 to 720 minutes.") }
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined { _ = try? await manager.requestAuthorization() }
        guard manager.authorizationState == .authorized else {
            throw ToolError("Lotti may not set alarms. Allow it in Settings.")
        }
        let named = arguments.string("label")
        let label = named ?? "Timer"
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: label),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        let attributes = AlarmAttributes<TimerMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .green)
        let id = UUID()
        // Before scheduling, so the glasses know the name even if the first update is quick.
        AlarmTimers.remember(id, label: named, duration: TimeInterval(minutes * 60))
        _ = try await manager.schedule(id: id, configuration: .timer(duration: TimeInterval(minutes * 60), attributes: attributes))
        return "Timer set for \(minutes) min."
    }
}

struct CreateReminderTool: PhoneTool {
    let spec = PhoneToolSpec(
        name: "create_reminder", description: "Add a reminder to Jan's default reminders list.",
        parameters: [
            ToolParameter("text", .string, "what to remember, short"),
            ToolParameter("due", .string, "when: a day and time like \"tomorrow 09:00\" or \"monday 18:30\"", optional: true),
        ],
        effect: .action, progress: "Adding the reminder…")

    func title(for arguments: ToolArguments) -> String {
        let text = arguments.string("text") ?? ""
        return "Remind: " + text
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        let store = RemindersTool.store
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let list = store.defaultCalendarForNewReminders()
        else { throw ToolError("Lotti has no access to reminders.") }
        let text = ToolText()
        let reminder = EKReminder(eventStore: store)
        reminder.title = arguments.string("text")
        reminder.calendar = list
        var when = ""
        if let dueText = arguments.string("due") {
            guard let due = text.moment(dueText, now: Date()) else {
                throw ToolError("create_reminder: due should be a day and time like \"tomorrow 09:00\"")
            }
            reminder.dueDateComponents = text.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            when = ", " + text.dayAndTime(due)
        }
        try store.save(reminder, commit: true)
        return "Reminder added\(when)."
    }
}

/// Starts turn-by-turn navigation on the glasses (walking or by bike). The trip runs on the
/// firmware's own nav screen, driven by `NavigationSession`; see `NavigationController`.
struct StartNavigationTool: PhoneTool {
    let start: @MainActor (String, NavigationMode) async throws -> String
    let spec = PhoneToolSpec(
        name: "start_navigation",
        description: "Start turn-by-turn navigation on the glasses, walking or by bike.",
        parameters: [
            ToolParameter("destination", .string, "the place as Jan said it, e.g. \"Mauerpark\" or \"Kastanienallee 12\""),
            ToolParameter("mode", .oneOf(["walk", "bike"]), "how Jan wants to go; default walk", optional: true),
        ],
        effect: .action, progress: "Planning the route…",
        // Planning needs a location fix plus a MapKit search and route: give it room.
        timeout: .seconds(30))

    func title(for arguments: ToolArguments) -> String {
        "Navigation: " + (arguments.string("destination") ?? "Ziel")
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        let mode = arguments.string("mode") == "bike" ? NavigationMode.cycling : .walking
        return try await start(arguments.string("destination") ?? "", mode)
    }
}
