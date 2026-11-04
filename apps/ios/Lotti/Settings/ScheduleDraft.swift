import Foundation

/// The friendly schedule picker behind a job: what you pick becomes the text the backend
/// understands ("daily at 08:00", "weekdays at 07:30", "every monday at 09:00", "every 30 minutes"),
/// or a cron expression you type.
struct ScheduleDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case everyMinutes, hourly, daily, weekdays, weekly, monthly, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyMinutes: "Every few minutes"
            case .hourly: "Every hour"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            case .monthly: "Every month"
            case .custom: "Cron expression"
            }
        }
    }

    static let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    var kind: Kind = .daily
    var minutes = 30
    var hour = 8
    var minute = 0
    /// 0 = Monday … 6 = Sunday.
    var weekday = 0
    var custom = ""

    init() {}

    /// Reads a schedule back: the friendly text the job was made with, else its cron.
    init(text: String?, cron: String = "") {
        let t = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let m = Self.match(#"^every (\d+) minutes?$"#, t) {
            kind = .everyMinutes
            minutes = Int(m[0]) ?? 30
        } else if t == "hourly" {
            kind = .hourly
        } else if let m = Self.match(#"^daily at (\d{1,2}):(\d{2})$"#, t) {
            kind = .daily
            (hour, minute) = (Int(m[0]) ?? 8, Int(m[1]) ?? 0)
        } else if let m = Self.match(#"^weekdays at (\d{1,2}):(\d{2})$"#, t) {
            kind = .weekdays
            (hour, minute) = (Int(m[0]) ?? 8, Int(m[1]) ?? 0)
        } else if let m = Self.match(#"^every (\w+) at (\d{1,2}):(\d{2})$"#, t), let day = Self.weekdayNames.firstIndex(of: m[0]) {
            kind = .weekly
            weekday = day
            (hour, minute) = (Int(m[1]) ?? 8, Int(m[2]) ?? 0)
        } else if let m = Self.match(#"^monthly at (\d{1,2}):(\d{2})$"#, t) {
            kind = .monthly
            (hour, minute) = (Int(m[0]) ?? 8, Int(m[1]) ?? 0)
        } else {
            kind = .custom
            custom = (text?.isEmpty == false ? text! : cron)
        }
    }

    /// What to send as the job's `schedule`.
    var text: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .everyMinutes: return "every \(max(1, minutes)) minutes"
        case .hourly: return "hourly"
        case .daily: return "daily at \(time)"
        case .weekdays: return "weekdays at \(time)"
        case .weekly: return "every \(Self.weekdayNames[min(max(weekday, 0), 6)]) at \(time)"
        case .monthly: return "monthly at \(time)"
        case .custom: return custom.trimmingCharacters(in: .whitespaces)
        }
    }

    var isValid: Bool { !text.isEmpty }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<found.numberOfRanges).compactMap { Range(found.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
