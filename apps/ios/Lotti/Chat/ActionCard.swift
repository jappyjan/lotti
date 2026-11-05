import LottiKit
import SwiftUI

/// A proposed action as a card: what will happen in plain words (calendar events with local 24-hour
/// times), a Confirm button and "Not now". Nothing runs until Confirm is tapped.
struct ActionCard: View {
    let action: ProposedAction
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(destructive ? .red : .green)
                .accessibilityAddTraits(.isHeader)
            Text(headline).font(.headline)
            ForEach(details, id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
            // Side by side while they fit; stacked at large text sizes so the labels don't break mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { confirmButton; dismissButton }
                VStack(spacing: 10) { confirmButton; dismissButton }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }

    private var confirmButton: some View {
        Button(role: destructive ? .destructive : nil, action: confirm) {
            Text(confirmTitle).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(destructive ? .red : .green)
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Text(lang("Nicht jetzt", "Not now")).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.primary)
    }

    private var destructive: Bool { action.isDestructive }

    private var heading: String {
        switch action.tool {
        case "create_calendar_event": lang("Neuer Termin", "New event")
        case "delete_calendar_event": lang("Termin löschen", "Delete event")
        case "send_mail_reply": lang("Antwort senden", "Send reply")
        case "set_timer": "Timer"
        case "create_reminder": lang("Erinnerung", "Reminder")
        case "start_navigation": lang("Navigation", "Navigation")
        default: lang("Vorschlag", "Suggestion")
        }
    }

    private var icon: String {
        switch action.tool {
        case "create_calendar_event": "calendar.badge.plus"
        case "delete_calendar_event": "calendar.badge.minus"
        case "send_mail_reply": "envelope"
        case "set_timer": "timer"
        case "create_reminder": "bell"
        case "start_navigation": "location"
        default: action.target == .server ? "bolt.horizontal" : "iphone"
        }
    }

    private var confirmTitle: String {
        switch action.tool {
        case "create_calendar_event": lang("Hinzufügen", "Add")
        case "delete_calendar_event": lang("Löschen", "Delete")
        case "send_mail_reply": lang("Senden", "Send")
        default: lang("Bestätigen", "Confirm")
        }
    }

    private var headline: String {
        if action.tool.hasSuffix("_calendar_event"), let title = action.arguments.string("title"), !title.isEmpty { return title }
        return action.title
    }

    private var details: [String] {
        let args = action.arguments
        switch action.tool {
        case "create_calendar_event":
            var lines: [String] = []
            if let when = ActionCard.when(args.string("start"), args.string("end")) {
                lines.append(when)
            } else if args.string("start") != nil {
                // A time the phone can't read: the backend's title, which formats it on its own.
                lines.append(action.title)
            }
            if let place = args.string("location"), !place.isEmpty { lines.append(place) }
            if case .array(let people)? = args.values["attendees"], !people.isEmpty {
                lines.append(people.compactMap(\.string).joined(separator: ", "))
            }
            return lines
        case "delete_calendar_event":
            let allDay = args.bool("allDay") == true
            var lines = [allDay ? ActionCard.day(args.string("start")) : ActionCard.when(args.string("start"), args.string("end"))].compactMap { $0 }
            if args.bool("occurrence") == true {
                lines.append(lang("Nur dieser Termin, nicht die ganze Serie.", "Only this occurrence, not the whole series."))
            }
            return lines + [lang("Das lässt sich nicht rückgängig machen.", "This can't be undone.")]
        default:
            return []
        }
    }

    /// "Tue 3 Nov 14:30–15:30" (German: "Di., 3. Nov. 14:30–15:30"), 24-hour, in the phone's zone: the
    /// same shape as the backend's confirmation titles.
    static func when(_ startISO: String?, _ endISO: String?, timeZone: TimeZone = .current) -> String? {
        guard let start = date(startISO, timeZone: timeZone), let day = day(start, timeZone: timeZone) else { return nil }
        var time = Date.FormatStyle(timeZone: timeZone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        time.locale = Locale(identifier: "de_DE")
        guard let end = date(endISO, timeZone: timeZone) else { return "\(day) \(start.formatted(time))" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(day) \(start.formatted(time))–\(end.formatted(time))"
        }
        return "\(day) \(start.formatted(time)) – \(ActionCard.day(end, timeZone: timeZone) ?? "") \(end.formatted(time))"
    }

    /// The date alone (all-day events): "Tue 3 Nov".
    static func day(_ iso: String?, timeZone: TimeZone = .current) -> String? {
        date(iso, timeZone: timeZone).flatMap { day($0, timeZone: timeZone) }
    }

    private static func day(_ date: Date, timeZone: TimeZone) -> String? {
        var style = Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).day().month(.abbreviated)
        style.locale = Locale(identifier: lang("de_DE", "en_GB"))
        return date.formatted(style)
    }

    /// ISO 8601 as the backend sends it, and the shorter forms a model writes too: no seconds, or no
    /// offset (then the phone's zone). A bare date (all-day events) is that day in the phone's zone.
    static func date(_ iso: String?, timeZone: TimeZone = .current) -> Date? {
        guard let iso else { return nil }
        if let date = BackendDates.parse(iso) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: iso) { return date }
        }
        return nil
    }
}
