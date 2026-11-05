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
    let renderer = ScreenRenderer(layout: TextLayout(fullWidthColumns: 20, lines: 5))

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

    @Test func choicesAreTheListsItems() {
        // The glasses draw the selection: no marker, and moving it changes nothing on the page.
        let rail = Rail([RailItem("On my way to you now", .dismiss), RailItem("Late", .dismiss)], highlighted: 1)
        let frame = renderer.render(Screen(.says, "Hi", rail: rail))
        #expect(frame.list?.items == ["On my way to you …", "Late"])
        #expect(frame == renderer.render(Screen(.says, "Hi", rail: Rail(rail.items))))
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

    @Test func anOpenedItemKeepsItsHeaderUnderALongBody() {
        let body = Array(repeating: "word", count: 40).joined(separator: " ")
        let rail = Rail([RailItem("Dismiss", .dismiss)])
        let lines = ScreenRenderer().render(Screen(.original, body, details: ["Mail · Mara"], rail: rail)).main
            .components(separatedBy: "\n")
        #expect(lines.last == "Mail · Mara")
        #expect(lines[lines.count - 2] == "")
        #expect(lines.count == ScreenRenderer.choicesBelowMainLines)
    }

    @Test func choicesSitBelowAcrossTheFullWidth() {
        let rail = Rail([RailItem("On my way", .dismiss), RailItem("Running late", .dismiss)])
        let frame = ScreenRenderer().render(Screen(.says, "Mara asks if you are still coming", rail: rail))
        #expect(frame == GlassesFrame(main: "Mara asks if you are still coming", choices: ["On my way", "Running late"]))
        #expect(frame.list?.y == G2Layout.choicesY && frame.list?.width == G2Layout.width)
    }

    @Test func theSentenceAboveChoicesGetsSixLines() {
        let text = Array(repeating: "word", count: 60).joined(separator: " ")
        let frame = ScreenRenderer().render(Screen(.says, text, rail: Rail([RailItem("Yes", .dismiss)])))
        #expect(frame.main.components(separatedBy: "\n").count == 6)
        #expect(frame.rail == "Yes")
    }

    // MARK: Header and cards

    let today = Screen(.today, "Dentist in 25 min.", details: ["+2 more today"], header: Header("Thu 5 Nov", right: "14:05"),
                       cards: [Card("Pasta", ["4 min left", "Rings 14:09"], art: .icon(.timer(left: 0.5))),
                               Card("12° cloudy", ["7° / 14°"], art: .icon(.cloud))],
                       rail: Rail([RailItem("Agenda", .dismiss), RailItem("Weather", .dismiss)]))

    @Test func headerSentenceCardsAndChoicesStackUp() {
        let frame = ScreenRenderer().render(today)
        #expect(frame.boxes.map(\.name) == ["main", "date", "card1", "card2"])
        #expect(frame.main == "Dentist in 25 min.\n\n+2 more today")
        #expect(frame["card1"] == "Pasta\n4 min left\nRings 14:09")
        #expect(frame.rail == "Agenda\nWeather")
        let main = frame.boxes[0], date = frame.boxes[1], card1 = frame.boxes[2], card2 = frame.boxes[3], choices = frame.list!
        #expect(card1.y >= main.y + main.height)
        #expect(card2.x > card1.x + card1.width && card2.x + card2.width <= G2Layout.width)
        // Two choices take two lines at the bottom, not the fixed four-line block.
        #expect(choices.height == 2 * G2Layout.lineHeight && choices.y + choices.height == G2Layout.height)
        #expect(card1.y + card1.height <= choices.y)

        // The time is drawn big, the date next to it; each card's icon sits left of its text.
        #expect(frame.images.map(\.name) == ["clock", "art1", "art2"])
        let clock = frame.images[0], timerIcon = frame.images[1]
        #expect(clock.x + clock.width < date.x && clock.height == 7 * ScreenRenderer.clockScale)
        #expect(main.y >= clock.y + clock.height)
        #expect(timerIcon.x + timerIcon.width < card1.x && timerIcon.y >= card1.y)
        #expect(frame.images.map(\.id) == [20, 21, 22])
    }

    @Test func boxesStayInsideTheDisplay() {
        let forecast = Screen(.says, "12° and cloudy.", cards: (1...7).map { Card("Day \($0)", ["cloudy", "14°/7°"]) })
        let frame = ScreenRenderer().render(forecast)
        #expect(frame.boxes.count == 1 + ScreenRenderer.maxCards)
        for box in frame.boxes {
            #expect(box.x >= 0 && box.y >= 0)
            #expect(box.x + box.width <= G2Layout.width && box.y + box.height <= G2Layout.height)
        }
    }

    @Test func fourChoicesStillLeaveTwoCardLines() {
        var crowded = today
        crowded.rail = Rail((1...4).map { RailItem("Choice \($0)", .dismiss) })
        let frame = ScreenRenderer().render(crowded)
        let card = frame.boxes[2]
        #expect(card.name == "card1")
        #expect(card.height >= 2 * G2Layout.lineHeight)
        #expect(frame["card1"] == "Pasta\n4 min left")
    }

    @Test func forecastDaysHaveTheirPictureBetweenNameAndNumbers() {
        let range = 2...12
        let days = Screen(.says, "9° and cloudy.", cards: [
            Card("Today", ["Rain 80%"], art: .day(.rain, low: 6, high: 11, range: range)),
            Card("Fri", art: .day(.cloud, low: 4, high: 9, range: range)),
        ])
        let frame = ScreenRenderer().render(days)
        // Name, three lines of picture (icon, bar, the low and high at its ends), then the rain.
        #expect(frame["card1"] == "Today\n\n\n\nRain 80%")
        let card = frame.boxes[1], picture = frame.images[0]
        #expect(picture.y > card.y + G2Layout.lineHeight - 1 && picture.y + picture.height <= card.y + 4 * G2Layout.lineHeight)
        #expect(picture.x == card.x && picture.width == card.width)
    }

    @Test func aSentenceWithAnIconMovesOver() {
        let frame = ScreenRenderer().render(Screen(.says, "Time's up: Pasta", icon: .bell, rail: Rail([RailItem("Stop", .dismiss)])))
        #expect(frame.images.map(\.name) == ["icon"])
        #expect(frame.boxes[0].x > frame.images[0].x + frame.images[0].width)
        #expect(frame.rail == "Stop")
    }

    @Test func cardLinesAreCutNotWrapped() {
        let screen = Screen(.today, "Hi", header: Header("Thu", right: "14:05"),
                            cards: [Card("Later", ["16:00 Standup", "20:00 Pizza at Mara's place in Altona"], art: .icon(.calendar)),
                                    Card("9°", art: .icon(.cloud))])
        let lines = (ScreenRenderer().render(screen)["card1"] ?? "").components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[2].hasPrefix("20:00 Pizza") && lines[2].hasSuffix("…"))
    }

    @Test func theDayBarIsLabelledLowLeftHighRight() {
        let width = 108
        let bar = LensArt.day(.sun, low: 4, high: 11, of: 2...12, width: width)
        let labels = LensArt.small("4°").height
        // The bottom rows hold the labels: lit pixels on the left (the low) and the right (the high).
        let rows = (bar.height - labels)..<bar.height
        let lit = rows.flatMap { y in (0..<width).filter { bar[$0, y] } }
        #expect(lit.min()! < width / 3 && lit.max()! > 2 * width / 3)
        // A narrow day still gets both numbers, side by side and on the picture.
        let narrow = LensArt.day(.sun, low: 7, high: 8, of: -10...20, width: width)
        let narrowLit = ((narrow.height - labels)..<narrow.height).flatMap { y in (0..<width).filter { narrow[$0, y] } }
        #expect(narrowLit.max()! - narrowLit.min()! >= LensArt.small("7°").width + LensArt.small("8°").width)
        #expect(narrowLit.min()! >= 0 && narrowLit.max()! < width)
    }

    @Test func atMostFourPictures() {
        // The glasses reject a page with more than four image containers.
        let many = Screen(.says, "x", header: Header("Thu", right: "14:05"),
                          cards: (1...5).map { Card("\($0)", art: .icon(.sun)) }, rail: Rail([RailItem("A", .dismiss)]))
        let frame = ScreenRenderer().render(many)
        #expect(frame.images.count == ScreenRenderer.maxImages)
        #expect(frame.boxes.count + frame.images.count <= 12)
    }

    @Test func iconsAreDrawn() {
        for icon in [LensIcon.sun, .partlyCloudy, .cloud, .fog, .drizzle, .rain, .heavyRain, .snow, .storm, .calendar, .check,
                     .timer(left: 0.3)] {
            let bitmap = LensArt.bitmap(icon)
            #expect(bitmap.width == LensArt.iconSize && bitmap.height == LensArt.iconSize)
            #expect(bitmap.litCount > 30)
        }
        #expect(LensArt.bitmap(.timer(left: 1)).litCount > LensArt.bitmap(.timer(left: 0.2)).litCount)
        #expect(LensIcon(condition: "heavy rain") == .heavyRain && LensIcon(condition: "mixed") == .cloud)
        #expect(LensArt.digits("14:05").height == 28)
        #expect(LensArt.small("-3°").width > LensArt.small("3°").width)
    }

    @Test func thePlainLayoutListsCardsAsLines() {
        let frame = ScreenRenderer().renderPlain(today)
        #expect(frame.main == "Dentist in 25 min.\n\nThu 5 Nov · 14:05\n+2 more today\nPasta, 4 min left, Rings 14:09\n12° cloudy, 7° / 14°")
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
        #expect(screen.header == Header("Sun 1 Nov", right: "09:00"))
        #expect(screen.details == [])
        #expect(screen.cards == [])
        #expect(screen.rail == nil)
    }

    @Test func nextEventLaterToday() {
        let info = TodayInfo(now: at(9), events: [
            CalendarEntry(title: "Dentist", start: at(15), end: at(16)),
            CalendarEntry(title: "Pizza at Mara's", start: at(20), end: at(22)),
        ], weather: Weather(temperature: 12, condition: "cloudy", high: 14, low: 7, rainFrom: at(18)))
        let screen = composer.screen(for: info)
        #expect(screen.text == "Next: Dentist at 15:00.")
        #expect(screen.details == ["+1 more today"])
        #expect(screen.cards == [Card("12° cloudy", ["7° / 14°", "Rain from 18:00"], art: .icon(.cloud)),
                                 Card("Later", ["20:00 Pizza at Mara's"], art: .icon(.calendar))])
        #expect(screen.rail?.items.map(\.title) == ["Agenda", "Weather"])
    }

    @Test func runningTimersComeFirst() {
        let pasta = PhoneTimer(id: UUID(), label: "Pasta", state: .running(ends: at(9, 4).addingTimeInterval(20)), duration: 600)
        let ringing = PhoneTimer(id: UUID(), label: "Tea", state: .ringing)
        let info = TodayInfo(now: at(9), weather: Weather(temperature: 12, condition: "cloudy"), timers: [pasta, ringing])
        // 4 min 20 s of 10 min left: the dial shows 6/12.
        #expect(composer.screen(for: info).cards == [Card("Pasta", ["5 min left", "Rings 09:04"], art: .icon(.timer(left: 0.5))),
                                                     Card("12° cloudy", art: .icon(.cloud))])

        let eggs = PhoneTimer(id: UUID(), state: .running(ends: at(10, 30)))
        let two = composer.screen(for: TodayInfo(now: at(9), timers: [pasta, eggs]))
        #expect(two.cards == [Card("Timers", ["Pasta 5 min", "Timer 1 h 30 min"], art: .icon(.timer(left: 0.5)))])
    }

    @Test func forecastHasACardPerDay() {
        let days = (0..<6).map { offset in
            DayForecast(date: composer.calendar.date(byAdding: .day, value: offset, to: at(0))!, condition: "light rain",
                        high: 10 + offset, low: 5, rainChance: offset == 0 ? 80 : 10)
        }
        let weather = Weather(temperature: 12, condition: "cloudy", high: 14, low: 7, days: days)
        let screen = composer.forecast(weather, now: at(9))
        #expect(screen.text == "12° and cloudy, between 7° and 14° today.")
        #expect(screen.cards.count == 4)  // one picture each, and a page takes four
        #expect(screen.cards[0] == Card("Today", ["Rain 80%"], art: .day(.rain, low: 5, high: 10, range: 5...13)))
        #expect(screen.cards[1] == Card("Mon", art: .day(.rain, low: 5, high: 11, range: 5...13)))
        let today = composer.screen(for: TodayInfo(now: at(9), weather: weather))
        #expect(today.rail?.items.last?.action == .show(screen))
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
