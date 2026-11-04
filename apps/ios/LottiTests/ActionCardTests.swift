import Foundation
import Testing
@testable import Lotti

struct ActionCardTests {
    @Test func timesAreFormattedNotRawISO() throws {
        let text = try #require(ActionCard.when("2026-11-04T10:00:00+01:00", "2026-11-04T11:30:00+01:00"))
        #expect(!text.contains("2026-"))
        #expect(!text.contains("T10"))
        #expect(!text.localizedCaseInsensitiveContains("pm"))
        #expect(text.contains("–"))
    }

    @Test func endOnAnotherDayGetsItsOwnDate() throws {
        let text = try #require(ActionCard.when("2026-11-04T22:00:00+01:00", "2026-11-05T01:00:00+01:00"))
        #expect(text.contains(" – "))
    }

    @Test func hoursAreTwoDigits() throws {
        // Early hours in most zones near UTC: "1:30" would read differently from the "01:30" in the card title.
        let text = try #require(ActionCard.when("2026-11-05T01:00:00+00:00", "2026-11-05T04:30:00+00:00"))
        let times = text.matches(of: /\d+:\d\d/).map { String($0.output) }
        #expect(times.count == 2)
        #expect(times.allSatisfy { $0.count == 5 }, "\(text)")
    }

    @Test func unparseableTimeIsNil() {
        #expect(ActionCard.when("tomorrow", nil) == nil)
        #expect(ActionCard.when(nil, nil) == nil)
    }
}
