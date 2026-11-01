import Foundation
import Testing
@testable import LottiKit

struct RailTests {
    @Test func highlightStopsAtTheEnds() {
        var rail = Rail([RailItem("A", .dismiss), RailItem("B", .dismiss)])
        rail.moveUp()
        #expect(rail.highlighted == 0)
        rail.moveDown()
        rail.moveDown()
        #expect(rail.highlighted == 1)
        #expect(rail.current?.title == "B")
    }

    @Test func keepsAtMostFourItems() {
        let rail = Rail((1...6).map { RailItem("\($0)", .dismiss) })
        #expect(rail.items.count == 4)
    }

    @Test func anEmptyRailIsNoRail() {
        #expect(Screen(.says, "Hi", rail: Rail([])).rail == nil)
    }
}

struct ScreenRendererTests {
    let renderer = ScreenRenderer(layout: TextLayout(fullWidthColumns: 20, mainColumnsWithRail: 12, railColumns: 8, lines: 5))

    @Test func wrapsAtWordBoundaries() {
        #expect(ScreenRenderer.wrap("Mara asks if you are still coming", columns: 12)
            == ["Mara asks if", "you are", "still coming"])
    }

    @Test func cutsWordsLongerThanALine() {
        #expect(ScreenRenderer.wrap("Donaudampfschiff", columns: 6) == ["Donaud", "ampfsc", "hiff"])
    }

    @Test func fullWidthWithoutRail() {
        let frame = renderer.render(Screen(.says, "Mara asks if you are still coming"))
        #expect(frame == GlassesFrame(main: "Mara asks if you are\nstill coming"))
    }

    @Test func railMarksTheHighlight() {
        let rail = Rail([RailItem("On my way", .dismiss), RailItem("Late", .dismiss)], highlighted: 1)
        let frame = renderer.render(Screen(.says, "Hi", rail: rail))
        #expect(frame.rail == "  On my…\n> Late")
    }

    @Test func detailsGoBelowABlankLine() {
        let frame = renderer.render(Screen(.today, "All quiet.", details: ["Sun 1 Nov · 14:32"]))
        #expect(frame.main == "All quiet.\n\nSun 1 Nov · 14:32")
    }

    @Test func longTextIsCutToTheScreen() {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let lines = renderer.render(Screen(.says, text, details: ["dropped"])).main.components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines.last?.hasSuffix("…") == true || lines.last!.count <= 20)
        #expect(!lines.contains("dropped"))
    }

    @Test func wideRailGivesTheChoicesMoreRoom() {
        let renderer = ScreenRenderer(style: .wideRail)
        // 17 characters: would be clipped in the 13-column rail (11 usable), fits in the wide one.
        let rail = Rail([RailItem("Send my location", .dismiss), RailItem("On my way", .dismiss)])
        let frame = renderer.render(Screen(.says, "Mara asks if you are still coming and wants pizza", rail: rail))
        #expect(frame.style == .wideRail)
        #expect(frame.rail == "> Send my location\n  On my way")
        #expect(frame.main.components(separatedBy: "\n").first!.count <= TextLayout.wideRail.mainColumnsWithRail)
    }

    @Test func choicesBelowUsesTheFullWidth() {
        let renderer = ScreenRenderer(style: .choicesBelow)
        let rail = Rail([RailItem("On my way", .dismiss), RailItem("Running late", .dismiss)])
        let frame = renderer.render(Screen(.says, "Mara asks if you are still coming", rail: rail))
        #expect(frame.style == .choicesBelow)
        #expect(frame.main == "Mara asks if you are still coming")
        #expect(frame.rail == "> On my way\n  Running late")
    }

    @Test func choicesBelowCutsTheSentenceToSixLines() {
        let renderer = ScreenRenderer(style: .choicesBelow)
        let text = Array(repeating: "word", count: 60).joined(separator: " ")
        let frame = renderer.render(Screen(.says, text, rail: Rail([RailItem("Yes", .dismiss)])))
        let lines = frame.main.components(separatedBy: "\n")
        #expect(lines.count == 6)
        #expect(frame.rail == "> Yes")
    }

    @Test func wideRailCapsAtThreeItems() {
        let rail = Rail((1...4).map { RailItem("\($0)", .dismiss) }, limit: DisplayStyle.wideRail.maxRailItems)
        #expect(rail.items.count == 3)
    }
}

struct TodayComposerTests {
    let composer: TodayComposer = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return TodayComposer(calendar: calendar)
    }()

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        composer.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: minute))!
    }

    @Test func freeDay() {
        let screen = composer.screen(for: TodayInfo(now: at(9)))
        #expect(screen.text == "Your calendar is free today.")
        #expect(screen.details == ["Sun 1 Nov · 09:00"])
        #expect(screen.rail == nil)
    }

    @Test func nextEventLaterToday() {
        let info = TodayInfo(now: at(9), events: [
            CalendarEntry(title: "Dentist", start: at(15), end: at(16)),
            CalendarEntry(title: "Pizza at Mara's", start: at(20), end: at(22)),
        ], weather: Weather(temperature: 12, condition: "cloudy", high: 14, low: 7, rainFrom: at(18)))
        let screen = composer.screen(for: info)
        #expect(screen.text == "Next: Dentist at 15:00. 12° and cloudy, rain from 18:00.")
        #expect(screen.details == ["Sun 1 Nov · 09:00", "+1 more today"])
        #expect(screen.rail?.items.map(\.title) == ["Agenda", "Weather"])
    }

    @Test func soonAndOngoing() {
        let dentist = CalendarEntry(title: "Dentist", start: at(15), end: at(16))
        #expect(composer.screen(for: TodayInfo(now: at(14, 35), events: [dentist])).text == "Dentist in 25 min.")
        #expect(composer.screen(for: TodayInfo(now: at(15, 10), events: [dentist])).text == "Dentist until 16:00.")
        #expect(composer.screen(for: TodayInfo(now: at(17), events: [dentist])).text == "Nothing else on your calendar today.")
    }

    @Test func agendaListsWhatIsLeft() {
        let info = TodayInfo(now: at(9), events: [
            CalendarEntry(title: "Dentist", start: at(15), end: at(16)),
            CalendarEntry(title: "Birthday Lea", start: at(0), end: at(23, 59), isAllDay: true),
        ])
        let agenda = composer.agenda(info)
        #expect(agenda.text == "One more thing today.")
        #expect(agenda.details == ["All day  Birthday Lea", "15:00  Dentist"])
    }

    @Test func promptSummary() {
        let info = TodayInfo(now: at(9), events: [CalendarEntry(title: "Dentist", start: at(15), end: at(16), location: "Kastanienallee")],
                             weather: Weather(temperature: 12, condition: "cloudy"))
        #expect(composer.promptSummary(info) == """
            Now: Sunday 1 November 2026, 09:00
            Calendar today: 15:00–16:00: Dentist (Kastanienallee)
            Weather now: 12°C, cloudy
            """)
    }
}
