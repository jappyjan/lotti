import Foundation

/// Dates in tool arguments and the plain-text results phone tools return. Brains get compact,
/// unambiguous text: `Mon 2 Nov: 09:30–10:00 Standup (Room 2)`.
public struct ToolText: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// A day from a tool argument: "today", "tomorrow", "day after tomorrow", a weekday (the next
    /// one, today included), English or German, or `YYYY-MM-DD`. Start of that day. Small models
    /// get dates wrong, so they name the day and the code counts.
    public func day(_ text: String?, now: Date) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return today }
        switch text {
        case "today", "heute": return today
        case "tomorrow", "morgen": return calendar.date(byAdding: .day, value: 1, to: today)
        case "day after tomorrow", "the day after tomorrow", "übermorgen": return calendar.date(byAdding: .day, value: 2, to: today)
        default: break
        }
        let weekdays = [["sunday", "sonntag"], ["monday", "montag"], ["tuesday", "dienstag"], ["wednesday", "mittwoch"],
                        ["thursday", "donnerstag"], ["friday", "freitag"], ["saturday", "samstag", "sonnabend"]]
        let name = text.hasPrefix("next ") ? String(text.dropFirst(5)) : text
        if let index = weekdays.firstIndex(where: { $0.contains(name) }) {
            let ahead = (index + 1 - calendar.component(.weekday, from: today) + 7) % 7
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }
        return moment(text).map { calendar.startOfDay(for: $0) }
    }

    /// A moment from a tool argument: `YYYY-MM-DD HH:mm`, or a day as in `day(_:now:)` followed by
    /// a time ("tomorrow 09:00", "montag 18 uhr", "9:30" for today).
    public func moment(_ text: String, now: Date) -> Date? {
        if let date = moment(text) { return date }
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = lower.firstMatch(of: /(?:um |at )?(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr|h)?$/),
              let hour = Int(match.1), hour < 24
        else { return nil }
        let minute = match.2.flatMap { Int($0) } ?? 0
        let dayText = String(lower[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard let day = day(dayText.isEmpty ? nil : dayText, now: now) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// A moment from a tool argument: `YYYY-MM-DD HH:mm`, `YYYY-MM-DDTHH:mm[:ss]` (also with a zone
    /// offset), or a bare `YYYY-MM-DD` (then 09:00).
    public func moment(_ text: String) -> Date? {
        // upper case: `day(_:now:)` passes lowered text ("…t09:00z")
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        // ISO-8601 with a zone ("2026-11-05T09:00:00+01:00", "…Z", a space for the T only with seconds:
        // "… 09:00-10:00" reads as a range), as models and the backend write it: that is an exact instant,
        // so the zone is honoured. Never falls back to reading digits: that would drop the zone.
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}|[T ]\d{2}:\d{2}:\d{2}).*(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil {
            // the formatter needs a T and seconds: "… 09:00+01:00" → "…T09:00:00+01:00"
            let withSeconds = trimmed
                .replacingOccurrences(of: #"^(\d{4}-\d{2}-\d{2}) "#, with: "$1T", options: .regularExpression)
                .replacingOccurrences(
                    of: #"T(\d{2}:\d{2})(?=Z$|[+-]\d{2}:?\d{2}$)"#, with: "T$1:00", options: .regularExpression)
            let ymd = trimmed.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3,
                  DateComponents(year: ymd[0], month: ymd[1], day: ymd[2]).isValidDate(in: calendar)  // rejects 2026-02-31
            else { return nil }
            return BackendDates.parse(withSeconds)
        }
        let parts = trimmed
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

    /// Weather spelled out so a small model can't misread it: "Rain today: yes, from 15:00".
    public func weather(_ w: Weather, now: Date) -> String {
        var lines = ["Now: \(w.temperature)°C, \(w.condition)"]
        var today = "Today"
        if let low = w.low, let high = w.high { today += ": \(low) to \(high)°C" }
        lines.append(today)
        if let rain = w.rainFrom {
            lines.append(rain <= now ? "Rain today: yes, raining now" : "Rain today: yes, from \(time(rain))")
        } else {
            lines.append("Rain today: no")
        }
        if let t = w.tomorrow { lines.append("Tomorrow: \(t.condition), \(t.low) to \(t.high)°C") }
        return lines.joined(separator: "\n")
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

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
