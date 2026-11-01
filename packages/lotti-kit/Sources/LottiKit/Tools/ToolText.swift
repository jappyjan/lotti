import Foundation

/// Dates in tool arguments and the plain-text results phone tools return. Brains get compact,
/// unambiguous text: `Mon 2 Nov: 09:30–10:00 Standup (Room 2)`.
public struct ToolText: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// A day from a tool argument: `YYYY-MM-DD`, "today" or "tomorrow". Start of that day.
    public func day(_ text: String?, now: Date) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return today }
        switch text {
        case "today", "heute": return today
        case "tomorrow", "morgen": return calendar.date(byAdding: .day, value: 1, to: today)
        default: return moment(text).map { calendar.startOfDay(for: $0) }
        }
    }

    /// A moment from a tool argument: `YYYY-MM-DD HH:mm`, `YYYY-MM-DDTHH:mm[:ss]`, or a bare
    /// `YYYY-MM-DD` (then 09:00).
    public func moment(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { "-T :".contains($0) }).map { Int($0) }
        guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.map { $0! }
        var components = DateComponents(year: n[0], month: n[1], day: n[2], hour: 9, minute: 0)
        if n.count >= 5 {
            components.hour = n[3]
            components.minute = n[4]
        }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == n[2]  // rejects 2026-02-31
        else { return nil }
        return date
    }

    /// One line per day from `from` for `days` days.
    public func events(_ entries: [CalendarEntry], from: Date, days: Int) -> String {
        (0..<max(days, 1)).compactMap { offset -> String? in
            guard let start = calendar.date(byAdding: .day, value: offset, to: from),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let onDay = entries.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
            let items = onDay.map { event in
                let place = event.location.map { " (\($0))" } ?? ""
                return event.isAllDay ? "all day: \(event.title)\(place)"
                    : "\(time(event.start))–\(time(event.end)) \(event.title)\(place)"
            }
            return "\(dayName(start)): " + (items.isEmpty ? "nothing" : items.joined(separator: "; "))
        }.joined(separator: "\n")
    }

    /// "Mon 2 Nov"
    public func dayName(_ date: Date) -> String { format(date, "EEE d MMM") }
    /// "Mon 2 Nov 18:00"
    public func dayAndTime(_ date: Date) -> String { format(date, "EEE d MMM HH:mm") }
    public func time(_ date: Date) -> String { format(date, "HH:mm") }

    func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
