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
    /// The next days, today first (up to 5).
    public var days: [DayForecast]

    public init(temperature: Int, condition: String, high: Int? = nil, low: Int? = nil, rainFrom: Date? = nil,
                days: [DayForecast] = []) {
        self.temperature = temperature
        self.condition = condition
        self.high = high
        self.low = low
        self.rainFrom = rainFrom
        self.days = days
    }

    public var tomorrow: DayForecast? { days.count > 1 ? days[1] : nil }
}

public struct DayForecast: Equatable, Sendable {
    /// The start of the day.
    public var date: Date
    public var condition: String
    public var high: Int
    public var low: Int
    /// Highest chance of rain that day, in percent.
    public var rainChance: Int?

    public init(date: Date, condition: String, high: Int, low: Int, rainChance: Int? = nil) {
        self.date = date
        self.condition = condition
        self.high = high
        self.low = low
        self.rainChance = rainChance
    }
}

/// Everything the today view and the chat know about today.
public struct TodayInfo: Equatable, Sendable {
    public var now: Date
    public var events: [CalendarEntry]
    public var weather: Weather?
    /// Lotti's timers that are counting down, soonest first.
    public var timers: [PhoneTimer]

    public init(now: Date, events: [CalendarEntry] = [], weather: Weather? = nil, timers: [PhoneTimer] = []) {
        self.now = now
        self.events = events.sorted { $0.start < $1.start }
        self.weather = weather
        self.timers = timers.filter { !$0.isRinging }
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

    /// The date and time on top, what's next, then cards: running timers, the weather, and what's
    /// later today if there's room.
    public func screen(for info: TodayInfo) -> Screen {
        var details: [String] = []
        let more = info.remaining.count - 1
        if more > 0 { details.append("+\(more) more today") }

        var cards: [Card] = []
        if let timers = timersCard(info) { cards.append(timers) }
        if let weather = info.weather { cards.append(weatherCard(weather, now: info.now)) }
        if cards.count < 2, info.remaining.count > 1 {
            cards.append(Card("Later", info.remaining.dropFirst().prefix(3).map { "\(time($0.start)) \($0.title)" },
                              art: .icon(.calendar)))
        }

        var items: [RailItem] = []
        if !info.events.isEmpty { items.append(RailItem("Agenda", .show(agenda(info)))) }
        if let weather = info.weather { items.append(RailItem("Weather", .show(forecast(weather, now: info.now)))) }
        return Screen(.today, nextUp(info), details: details, header: Header(format(info.now, "EEE d MMM"), right: time(info.now)),
                      cards: cards, rail: Rail(items))
    }

    /// The weather now, then a card per day (up to 5): its icon, a bar from low to high on the
    /// scale of the whole forecast with the numbers at its ends, and the chance of rain if it's
    /// worth saying.
    public func forecast(_ weather: Weather, now: Date) -> Screen {
        let days = Array(weather.days.prefix(ScreenRenderer.maxCards))
        let range = (days.map(\.low).min() ?? 0)...(days.map(\.high).max() ?? 0)
        let cards = days.enumerated().map { index, day in
            Card(index == 0 ? "Today" : format(day.date, "EEE"),
                 day.rainChance.flatMap { $0 >= 20 ? "Rain \($0)%" : nil }.map { [$0] } ?? [],
                 art: .day(LensIcon(condition: day.condition), low: day.low, high: day.high, range: range))
        }
        return Screen(.says, weatherSentence(weather, now: now, short: false), cards: cards)
    }

    func timersCard(_ info: TodayInfo) -> Card? {
        let running = info.timers.compactMap { timer -> (label: String?, ends: Date, duration: TimeInterval?)? in
            guard case .running(let ends) = timer.state else { return nil }
            return (timer.label, ends, timer.duration)
        }
        guard let first = running.first else { return nil }
        // The dial shows what's left of the soonest timer.
        let share = first.duration.map { first.ends.timeIntervalSince(info.now) / max($0, 1) } ?? 1
        let art = Card.Art.icon(.timer(left: (share * 12).rounded(.up) / 12))  // twelve steps: redraws stay rare
        if running.count == 1 {
            return Card(first.label ?? "Timer", [left(until: first.ends, now: info.now) + " left", "Rings \(time(first.ends))"],
                        art: art)
        }
        return Card("Timers", running.prefix(3).map { "\($0.label ?? "Timer") \(left(until: $0.ends, now: info.now))" }, art: art)
    }

    func weatherCard(_ w: Weather, now: Date) -> Card {
        var lines: [String] = []
        if let high = w.high, let low = w.low { lines.append("\(low)° / \(high)°") }
        if let rain = w.rainFrom { lines.append(rain <= now ? "Raining" : "Rain from \(time(rain))") }
        return Card("\(w.temperature)° \(w.condition)", lines, art: .icon(LensIcon(condition: w.condition)))
    }

    /// "4 min", "1 h 20 min"; rounded up, so a timer never says 0 min before it rings.
    func left(until end: Date, now: Date) -> String {
        let minutes = max(Int((end.timeIntervalSince(now) / 60).rounded(.up)), 1)
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
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
        var lines = [nowLine(info)]
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

    /// "Now: Sunday 1 November 2026, 14:05".
    public func nowLine(_ info: TodayInfo) -> String {
        "Now: " + format(info.now, "EEEE d MMMM yyyy") + ", " + time(info.now)
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
