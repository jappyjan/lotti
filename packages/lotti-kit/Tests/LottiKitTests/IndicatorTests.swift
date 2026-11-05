import Foundation
import Testing
@testable import LottiKit

struct IndicatorIconTests {
    let icons = BuiltInIndicatorIcons()

    @Test func everyIconIsDrawnAndDistinct() throws {
        let all: [IndicatorIcon] = [.mail, .calendar, .job, .reminder, .info, .location]
        let bitmaps = try all.map { try #require(icons.icon($0)) }
        for bitmap in bitmaps {
            #expect(bitmap.width == 24 && bitmap.height == 24)  // 12 × 12 drawn at 2×
            #expect(bitmap.litCount > 40)
        }
        #expect(Set(bitmaps.map(\.pixels)).count == all.count)
    }

    @Test func digitsAreDrawnAndDistinct() throws {
        let digits = try (0...9).map { try #require(icons.count($0)) }
        #expect(Set(digits.map(\.pixels)).count == 10)
        #expect(digits.allSatisfy { $0.height == 15 && $0.width == 9 })
        let twoDigits = try #require(icons.count(42))
        #expect(twoDigits.width == 9 * 2 + 3)
        #expect(icons.count(250) == icons.count(99))  // capped
    }

    @Test func aPictureScalesAndConvertsToRGBA() {
        let bitmap = MonoBitmap(rows: ["#.", ".#"]).scaled(by: 2)
        #expect(bitmap.picture == "##..\n##..\n..##\n..##")
        let rgba = bitmap.rgba()
        #expect(Array(rgba[0..<4]) == [0, 255, 0, 255])
        #expect(Array(rgba[8..<12]) == [0, 0, 0, 0])
    }

    @Test func aProviderCanOverrideSomeIcons() {
        struct Custom: IndicatorIconProvider {
            func icon(_ icon: IndicatorIcon) -> MonoBitmap? {
                icon == .mail ? MonoBitmap(width: 20, height: 20, pixels: [Bool](repeating: true, count: 400)) : nil
            }
        }
        let renderer = IndicatorRenderer(icons: Custom())
        #expect(renderer.icon(.mail).litCount == 400)
        #expect(renderer.icon(.job) == BuiltInIndicatorIcons().icon(.job))
        #expect(renderer.count(3) == BuiltInIndicatorIcons().count(3))
    }
}

struct IndicatorRendererTests {
    let renderer = IndicatorRenderer()

    @Test func noItemsNoIndicator() {
        #expect(renderer.images(for: IndicatorState(), showAttention: true, showLocation: true).isEmpty)
        #expect(renderer.attentionBitmap([]) == nil)
    }

    @Test func attentionSitsInTheTopRightCornerWithAnIconAndCountPerKind() throws {
        let state = IndicatorState(attention: [IndicatorCount(kind: .mail, count: 2), IndicatorCount(kind: .calendar, count: 1)])
        let images = renderer.images(for: state, showAttention: true, showLocation: false)
        let box = try #require(images.first)
        #expect(images.count == 1 && box.id == G2ImageBox.attentionID && box.name == "attention")
        #expect(box.x + box.width + renderer.margin == G2Layout.width)
        #expect(box.y == renderer.margin)
        #expect(box.height == 24 && box.width >= 20 && box.width < 150)
        // Two kinds are wider than one, and more kinds never leave the display.
        let one = try #require(renderer.attentionBitmap([IndicatorCount(kind: .mail, count: 2)]))
        let two = try #require(renderer.attentionBitmap(state.attention))
        #expect(two.width > one.width)
        let many = try #require(renderer.attentionBitmap(InboxKind.allCases.map { IndicatorCount(kind: $0, count: 88) }))
        #expect(many.width < 288)  // Even Hub images are at most 288 px wide
    }

    @Test func theImageIsTheGrayEncoding() throws {
        let state = IndicatorState(attention: [IndicatorCount(kind: .mail, count: 3)])
        let box = try #require(renderer.images(for: state, showAttention: true, showLocation: false).first)
        let bitmap = try #require(renderer.attentionBitmap(state.attention))
        let expected = try #require(NavMapBmp.encode(bitmap))
        #expect(box.data == expected.data && box.compression == expected.mode)
        // LZ4 wins on such a flat picture; the raw form is a full BMP of the same size.
        #expect(box.compression == .lz4)
        let bmp = NavMapBmp.file(pixels: bitmap.pixels.map { $0 ? 1 : 0 }, width: bitmap.width, height: bitmap.height)
        #expect(bmp.count == 118 + NavMapBmp.rowBytes(forWidth: bitmap.width) * bitmap.height)
        #expect(bmp[0] == 0x42 && bmp[1] == 0x4D)
    }

    @Test func locationSitsInTheBottomRightCorner() throws {
        let state = IndicatorState(locationActive: true)
        let box = try #require(renderer.images(for: state, showAttention: true, showLocation: true).first)
        #expect(box.id == G2ImageBox.locationID && box.name == "location")
        #expect(box.x + box.width + renderer.margin == G2Layout.width)
        #expect(box.y + box.height + renderer.margin == G2Layout.height)
        #expect(renderer.images(for: state, showAttention: true, showLocation: false).isEmpty)
    }

    @Test func attentionAndLocationDoNotOverlap() {
        let state = IndicatorState(attention: [IndicatorCount(kind: .mail, count: 1)], locationActive: true)
        let images = renderer.images(for: state, showAttention: true, showLocation: true)
        #expect(images.map(\.id) == [G2ImageBox.attentionID, G2ImageBox.locationID])
        #expect(images[0].y + images[0].height <= images[1].y)
    }

    @Test func stateCountsPendingItemsPerKind() async {
        let now = Date()
        let items = [
            InboxItem(id: "1", kind: .mail, title: "a"), InboxItem(id: "2", kind: .mail, title: "b"),
            InboxItem(id: "3", kind: .job, title: "c"), InboxItem(id: "4", kind: .info, title: "d", status: .dismissed),
            InboxItem(id: "5", kind: .calendar, title: "e", status: .seen),
            InboxItem(id: "6", kind: .reminder, title: "f", expiresAt: now.addingTimeInterval(-60)),
        ]
        let counts = await MainActor.run { InboxStore(items: items).pendingCounts(at: now) }
        #expect(counts == [IndicatorCount(kind: .mail, count: 2), IndicatorCount(kind: .job, count: 1)])
    }
}

struct InboxSummaryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func germanSummaryLikeTheDesign() {
        let items = [
            InboxItem(id: "1", kind: .mail, title: "a"), InboxItem(id: "2", kind: .mail, title: "b"),
            InboxItem(id: "3", kind: .calendar, title: "Zahnarzt", due: now.addingTimeInterval(10 * 60 + 5)),
        ]
        #expect(InboxSummary(german: true).line(items, now: now) == "2 Mails, Termin in 10 min")
        #expect(InboxSummary(german: false).line(items, now: now) == "2 mails, Appointment in 10 min")
    }

    @Test func singularPluralAndKinds() {
        let summary = InboxSummary(german: true)
        let items = [
            InboxItem(id: "1", kind: .mail, title: "a"), InboxItem(id: "2", kind: .job, title: "b"),
            InboxItem(id: "3", kind: .reminder, title: "c"), InboxItem(id: "4", kind: .reminder, title: "d"),
            InboxItem(id: "5", kind: .calendar, title: "e"), InboxItem(id: "6", kind: .calendar, title: "f"),
        ]
        #expect(summary.line(items, now: now) == "1 Mail, 1 Job, 2 Erinnerungen, 2 Termine")
        #expect(summary.label(.calendar) == "Termin")
    }

    @Test func aLaterEventShowsItsTime() {
        let tz = TimeZone.current
        let due = now.addingTimeInterval(3 * 3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = tz
        let line = InboxSummary(german: true).line([InboxItem(id: "1", kind: .calendar, title: "x", due: due)], now: now)
        #expect(line == "Termin um \(formatter.string(from: due))")
    }
}
