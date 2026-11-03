import Foundation

/// Reads the arguments of the offline tasks straight from Jan's words, German and English: how
/// long a timer runs, where to navigate. Instant and exact where a small model guesses, so timers
/// and navigation work offline even without Apple Intelligence (`OfflineBrain`). Returns nil when
/// the words don't say enough.
public enum OfflineIntents {
    /// Tool arguments for `tool`, or nil if `message` doesn't contain them.
    public static func arguments(for tool: String, message: String) -> [String: JSONValue]? {
        switch tool {
        case "set_timer":
            guard let minutes = timerMinutes(message) else { return nil }
            return ["minutes": .number(Double(minutes))]
        case "start_navigation":
            guard let place = destination(message) else { return nil }
            var arguments: [String: JSONValue] = ["destination": .string(place.destination)]
            if let mode = place.mode { arguments["mode"] = .string(mode) }
            return arguments
        case "create_reminder":
            guard let reminder = reminder(message) else { return nil }
            var arguments: [String: JSONValue] = ["text": .string(reminder.text)]
            if let due = reminder.due { arguments["due"] = .string(due) }
            return arguments
        default:
            return nil
        }
    }

    // MARK: Timer

    private static let numberWords: [String: Int] = [
        "ein": 1, "eine": 1, "einen": 1, "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7,
        "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12, "fünfzehn": 15, "zwanzig": 20, "fünfundzwanzig": 25,
        "dreißig": 30, "vierzig": 40, "fünfundvierzig": 45, "fünfzig": 50, "sechzig": 60,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty-five": 25, "thirty": 30, "forty": 40,
        "forty-five": 45, "fifty": 50, "sixty": 60, "a": 1, "an": 1,
    ]

    /// Minutes of a timer: "Timer auf 10 Minuten", "set a timer for 1 hour 30 minutes",
    /// "eine halbe Stunde", "fünf Minuten". 1 to 720, or nil.
    public static func timerMinutes(_ message: String) -> Int? {
        let text = message.lowercased().replacingOccurrences(of: ",", with: ".")
        var total = 0.0
        var found = false
        // Fixed fractions first.
        for (pattern, minutes) in [(#"dreiviertel\s*stunde|three quarters? of an hour"#, 45.0), (#"halbe stunde|half an hour|half hour"#, 30.0),
                                   (#"viertelstunde|quarter of an hour|quarter hour"#, 15.0)] {
            if text.range(of: pattern, options: .regularExpression) != nil { return Int(minutes) }
        }
        let number = #"(\d+(?:\.\d+)?|[a-zäöüß]+(?:-[a-z]+)?)"#
        for (unit, factor) in [(#"(?:stunden?|std\.?|hours?|hrs?|h)"#, 60.0), (#"(?:minuten?|min\.?|minutes?|mins?|m)"#, 1.0)] {
            guard let regex = try? NSRegularExpression(pattern: number + #"\s*"# + unit + #"(?![a-zäöü])"#) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let word = Range(match.range(at: 1), in: text).map({ String(text[$0]) }), let value = Double(word) ?? numberWords[word].map(Double.init)
                else { continue }
                total += value * factor
                found = true
            }
        }
        // "Timer 10": a bare number next to the word timer counts as minutes.
        if !found, let match = text.firstMatch(of: /timer\s+(?:auf\s+|for\s+)?(\d+)\b/), let value = Double(match.1) {
            total = value
            found = true
        }
        let minutes = Int(total.rounded())
        return found && (1...720).contains(minutes) ? minutes : nil
    }

    // MARK: Navigation

    /// Where to and how, from "Bring mich mit dem Rad zum Mauerpark" or "Walk me home".
    public static func destination(_ message: String) -> (destination: String, mode: String?)? {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let bike = lower.range(of: #"\b(rad|fahrrad|bike|cycle|cycling|biking)\b"#, options: .regularExpression) != nil
        let mode = bike ? "bike" : nil

        if lower.range(of: #"\b(nach hause|nach haus|heim|nachhause)\b"#, options: .regularExpression) != nil { return ("Zuhause", mode) }
        if lower.range(of: #"\b(me|us|to|take|bring|walk|guide|get)\b.*\bhome\b"#, options: .regularExpression) != nil { return ("home", mode) }

        let patterns = [
            #"\b(?:bis zum|bis zur|bis zu den|zum|zur|zu den|zu dem|zu der|zu|nach|ins|in die|in den|in das|an den|an die)\s+(.+)$"#,
            #"\b(?:to|towards|toward)\s+(?:the\s+)?(.+)$"#,
            #"\bwo ist\s+(?:der|die|das)\s+(.+)$"#,
            #"\bwhere(?: is|'s|s)?\s+the\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { continue }
            text = String(text[range])
            // Drop the trailing mode and politeness: "Mauerpark mit dem Rad", "…, please".
            for tail in [#"\s+(?:mit dem (?:fahr)?rad|mit dem bike|by (?:bike|bicycle)|on (?:my )?bike|zu fuß|on foot)\s*$"#, #"[\s,]+(?:bitte|please)\s*$"#, #"[\s.?!,]+$"#] {
                text = text.replacingOccurrences(of: tail, with: "", options: [.regularExpression, .caseInsensitive])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return (text, mode) }
        }
        return nil
    }

    // MARK: Reminder

    /// What to remember and when, from "Erinner mich morgen um 9 an die Wäsche" or "Remind me to call Mara".
    public static func reminder(_ message: String) -> (text: String, due: String?)? {
        var rest = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = rest.range(of: #"(?:erinner(?:e|n)? mich|vergiss nicht|remind me|don'?t let me forget)\s*"#,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        rest = String(rest[start.upperBound...])
        var due: String?
        let dayWords = #"(heute|morgen|übermorgen|today|tomorrow|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#
        if let regex = try? NSRegularExpression(pattern: #"\b"# + dayWords + #"?\s*(?:um|at)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr|h)?"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let hourRange = Range(match.range(at: 2), in: rest) {
            let day = Range(match.range(at: 1), in: rest).map { String(rest[$0]).lowercased() } ?? "today"
            let minutes = Range(match.range(at: 3), in: rest).map { String(rest[$0]) } ?? "00"
            due = "\(day) \(rest[hourRange]):\(minutes)"
            rest.removeSubrange(Range(match.range, in: rest)!)
        } else if let regex = try? NSRegularExpression(pattern: #"\b"# + dayWords + #"\b"#, options: .caseInsensitive),
                  let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let range = Range(match.range, in: rest) {
            due = "\(rest[range].lowercased()) 09:00"
            rest.removeSubrange(range)
        }
        let text = rest.replacingOccurrences(of: #"^\s*(?:daran,?\s*|an\s+|dass\s+|zu\s+|to\s+|about\s+|that\s+)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        return text.isEmpty ? nil : (text, due)
    }
}
