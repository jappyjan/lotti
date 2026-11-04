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
            Text(headline).font(.headline)
            ForEach(details, id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(role: destructive ? .destructive : nil, action: confirm) {
                    Text(confirmTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : .green)
                Button(lang("Nicht jetzt", "Not now"), action: dismiss)
                    .buttonStyle(.bordered)
                    .tint(.primary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
    }

    private var destructive: Bool { action.tool == "delete_calendar_event" }

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
            if let when = ActionCard.when(args.string("start"), args.string("end")) { lines.append(when) }
            if let place = args.string("location"), !place.isEmpty { lines.append(place) }
            if case .array(let people)? = args.values["attendees"], !people.isEmpty {
                lines.append(people.compactMap(\.string).joined(separator: ", "))
            }
            return lines
        case "delete_calendar_event":
            return [ActionCard.when(args.string("start"), nil)].compactMap { $0 } + [lang("Das lässt sich nicht rückgängig machen.", "This can't be undone.")]
        default:
            return []
        }
    }

    /// "Tue 3 Nov, 14:30–15:30" in the phone's own time zone and 24-hour clock.
    static func when(_ startISO: String?, _ endISO: String?) -> String? {
        guard let start = date(startISO) else { return nil }
        let day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "de_DE"))
        guard let end = date(endISO) else { return "\(day), \(start.formatted(time))" }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(day), \(start.formatted(time))–\(end.formatted(time))"
        }
        let endDay = end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day), \(start.formatted(time)) – \(endDay), \(end.formatted(time))"
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: iso) ?? fractional.date(from: iso)
    }
}
