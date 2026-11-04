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

    @Test func unparseableTimeIsNil() {
        #expect(ActionCard.when("tomorrow", nil) == nil)
        #expect(ActionCard.when(nil, nil) == nil)
    }
}
