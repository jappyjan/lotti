import Foundation
import Testing
@testable import Lotti

/// Fixed zones, so the expectations hold wherever the tests run.
struct ActionCardTests {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private var german: Bool { lang("de", "en") == "de" }

    @Test func timesAreFormattedNotRawISO() throws {
        let text = try #require(ActionCard.when("2026-11-04T10:00:00+01:00", "2026-11-04T11:30:00+01:00", timeZone: berlin))
        // The German weekday's punctuation depends on the ICU version ("Mi." / "Mi.,"): pin the rest.
        #expect(text.hasPrefix(german ? "Mi" : "Wed 4 Nov") && text.contains("4. Nov") == german, "\(text)")
        #expect(text.hasSuffix(" 10:00–11:30") && !text.contains("2026"), "\(text)")
    }

    @Test func shownInThePhonesZone() throws {
        let text = try #require(ActionCard.when("2026-11-04T10:00:00+01:00", "2026-11-04T11:30:00+01:00", timeZone: tokyo))
        #expect(text.hasSuffix("18:00–19:30"), "\(text)")
    }

    @Test func endOnAnotherDayGetsItsOwnDate() throws {
        let text = try #require(ActionCard.when("2026-11-04T22:00:00+01:00", "2026-11-05T01:00:00+01:00", timeZone: berlin))
        #expect(text.contains(" 22:00 – ") && text.hasSuffix(" 01:00"), "\(text)")
        #expect(text.contains(german ? "5. Nov" : "Thu 5 Nov"), "\(text)")
    }

    @Test func hoursAreTwoDigits() throws {
        let text = try #require(ActionCard.when("2026-11-05T01:00:00+01:00", "2026-11-05T04:30:00+01:00", timeZone: berlin))
        #expect(text.hasSuffix("01:00–04:30"), "\(text)")
    }

    @Test func shortFormsAModelWrites() throws {
        // No seconds, and no offset at all (read in the phone's zone).
        #expect(try #require(ActionCard.when("2026-11-05T14:00+01:00", nil, timeZone: berlin)).hasSuffix("14:00"))
        #expect(try #require(ActionCard.when("2026-11-05T14:00:00", nil, timeZone: berlin)).hasSuffix("14:00"))
        #expect(try #require(ActionCard.when("2026-11-05T13:00:00.000Z", nil, timeZone: berlin)).hasSuffix("14:00"))
    }

    @Test func unparseableTimeIsNil() {
        #expect(ActionCard.when("tomorrow", nil) == nil)
        #expect(ActionCard.when(nil, nil) == nil)
    }
}
