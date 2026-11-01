import Foundation

/// One calendar entry for today.
public struct CalendarEntry: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }
}

public struct Weather: Equatable, Sendable {
    /// Degrees Celsius, rounded.
    public var temperature: Int
    /// A short description in plain words ("cloudy", "light rain").
    public var condition: String
    public var high: Int?
    public var low: Int?
    /// When rain starts later today, if it does.
    public var rainFrom: Date?
    public var tomorrow: DayForecast?

    public init(temperature: Int, condition: String, high: Int? = nil, low: Int? = nil, rainFrom: Date? = nil,
                tomorrow: DayForecast? = nil) {
        self.temperature = temperature
        self.condition = condition
        self.high = high
        self.low = low
        self.rainFrom = rainFrom
        self.tomorrow = tomorrow
    }
}

public struct DayForecast: Equatable, Sendable {
    public var condition: String
    public var high: Int
    public var low: Int

    public init(condition: String, high: Int, low: Int) {
        self.condition = condition
        self.high = high
        self.low = low
    }
}

/// Everything the today view and the chat know about today.
public struct TodayInfo: Equatable, Sendable {
    public var now: Date
    public var events: [CalendarEntry]
    public var weather: Weather?

    public init(now: Date, events: [CalendarEntry] = [], weather: Weather? = nil) {
        self.now = now
        self.events = events.sorted { $0.start < $1.start }
        self.weather = weather
    }

    /// Timed events that haven't ended yet, in order.
    public var remaining: [CalendarEntry] {
        events.filter { !$0.isAllDay && $0.end > now }
    }

    public var allDay: [CalendarEntry] { events.filter(\.isAllDay) }
}

/// Where today's facts come from (calendar, weather). The app implements it with EventKit and a
/// weather service; tests use fixed values.
public protocol TodayProvider: Sendable {
    func today(at now: Date) async -> TodayInfo
}

/// Builds the today view and a short text version of the day for the chat prompt. Plain rules,
/// no model: it has to be instant when you look up.
public struct TodayComposer: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB")) {
        self.calendar = calendar
        self.locale = locale
    }

    public func screen(for info: TodayInfo) -> Screen {
        var parts = [nextUp(info)]
        if let weather = info.weather { parts.append(weatherSentence(weather, now: info.now, short: true)) }

        var details = [format(info.now, "EEE d MMM") + " · " + time(info.now)]
        let more = info.remaining.count - 1
        if more > 0 { details.append("+\(more) more today") }

        var items: [RailItem] = []
        if !info.events.isEmpty { items.append(RailItem("Agenda", .show(agenda(info)))) }
        if let weather = info.weather {
            items.append(RailItem("Weather", .show(Screen(.says, weatherSentence(weather, now: info.now, short: false)))))
        }
        return Screen(.today, parts.joined(separator: " "), details: details, rail: Rail(items))
    }

    /// Today's events as Lotti tells them, with one dim line per event.
    public func agenda(_ info: TodayInfo) -> Screen {
        let left = info.remaining
        let lines = info.allDay.map { "All day  \($0.title)" } + left.map { "\(time($0.start))  \($0.title)" }
        let text: String
        switch left.count {
        case 0: text = info.allDay.isEmpty ? "Nothing on your calendar today." : "Nothing else today."
        case 1: text = "One more thing today."
        default: text = "\(left.count) things left today."
        }
        return Screen(.says, text, details: lines)
    }

    /// A compact description of today for the chat prompt.
    public func promptSummary(_ info: TodayInfo) -> String {
        var lines = ["Now: " + format(info.now, "EEEE d MMMM yyyy") + ", " + time(info.now)]
        let events = info.allDay.map { "all day: \($0.title)" }
            + info.remaining.map { e in "\(time(e.start))–\(time(e.end)): \(e.title)" + (e.location.map { " (\($0))" } ?? "") }
        lines.append("Calendar today: " + (events.isEmpty ? "nothing left" : events.joined(separator: "; ")))
        if let w = info.weather {
            var weather = "Weather now: \(w.temperature)°C, \(w.condition)"
            if let high = w.high, let low = w.low { weather += ", today between \(low)° and \(high)°" }
            if let rain = w.rainFrom { weather += ", rain from \(time(rain))" }
            lines.append(weather)
            if let t = w.tomorrow { lines.append("Weather tomorrow: \(t.condition), \(t.low)–\(t.high)°C") }
        }
        return lines.joined(separator: "\n")
    }

    func nextUp(_ info: TodayInfo) -> String {
        guard let next = info.remaining.first else {
            return info.events.isEmpty ? "Your calendar is free today." : "Nothing else on your calendar today."
        }
        if next.start <= info.now { return "\(next.title) until \(time(next.end))." }
        let minutes = Int(next.start.timeIntervalSince(info.now) / 60)
        if minutes < 60 { return "\(next.title) in \(max(minutes, 1)) min." }
        return "Next: \(next.title) at \(time(next.start))."
    }

    func weatherSentence(_ w: Weather, now: Date, short: Bool) -> String {
        var sentence = "\(w.temperature)° and \(w.condition)"
        if !short, let high = w.high, let low = w.low { sentence += ", between \(low)° and \(high)° today" }
        if let rain = w.rainFrom, rain > now { sentence += ", rain from \(time(rain))" }
        return sentence + "."
    }

    func time(_ date: Date) -> String { format(date, "HH:mm") }

    func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
