import Foundation

/// Where things go on the G2's 576 × 288 display, and roughly how much text fits.
///
/// The firmware has one fixed proportional font. g2-kit (`ble/docs/text.md`) measured a planning
/// grid of about 50 columns × 10 rows on a full-width container, so one "column" is ~11.5 px and
/// one row ~29 px. Narrow letters pack tighter, `W` and `M` wider, so the character counts below
/// leave a little room. Text that doesn't fit wraps at word boundaries and shows a scroll bar, but
/// the firmware never scrolls it: lay text out to fit.
public enum G2Layout {
    public static let width = 576
    public static let height = 288

    /// One line of text is about this high (≈ 10 rows on the display; plan with 9).
    public static let lineHeight = 29
    /// Where the choices block starts under a plain sentence: six lines above it, four choices in it.
    public static let choicesY = 174
    /// The SDK allows at most 8 text containers on a page.
    public static let maxTextBoxes = 8

    /// What a blank container gets. MentraOS blanks text in place with "\n" (keeps the page and
    /// the event pipeline alive); an empty Cmd 5 isn't confirmed to work.
    static let blank = "\n"
}

/// One text container on the page. Ids are the routing key for Cmd 5 updates (even-g2-protocol
/// found the name is only metadata); names must be ≤ 14 characters.
public struct G2TextBox: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Only one container should capture touch events: text taps don't say which container they
    /// were on (g2-kit `text.md`).
    public var capturesEvents: Bool
    public var text: String

    public static let mainID = 1
    /// Header and card boxes start here: the indicator images own ids 3 and 4.
    public static let firstExtraID = 10

    public init(id: Int, name: String, x: Int, y: Int, width: Int, height: Int, capturesEvents: Bool, text: String) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.capturesEvents = capturesEvents
        self.text = text
    }

    /// The text containers for a frame. The main box is id 1, everything else counts up from
    /// `firstExtraID`. The main box takes the events unless the frame has a list of choices
    /// (`G2ListBox`), which then takes them.
    static func boxes(for frame: GlassesFrame) -> [G2TextBox] {
        var next = firstExtraID
        return frame.boxes.prefix(G2Layout.maxTextBoxes).enumerated().map { index, box in
            let id: Int
            if index == 0 {
                id = mainID
            } else {
                id = next
                next += 1
            }
            return G2TextBox(id: id, name: String(box.name.prefix(14)), x: box.x, y: box.y, width: box.width,
                             height: box.height, capturesEvents: index == 0 && frame.list == nil,
                             text: box.text.isEmpty ? G2Layout.blank : box.text)
        }
    }

    /// The same container without its text: what decides between an update and a rebuild.
    var geometry: G2TextBox {
        var shape = self
        shape.text = ""
        return shape
    }
}

/// The list of choices: the firmware's own list container (`ListContainerProperty`). The glasses
/// draw a border around the selected item, move it when you scroll (no redraw, nothing bounces)
/// and report a pick with the item's index. It takes the events.
public struct G2ListBox: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var items: [String]

    /// Text containers use 1 and 10+, the indicators 3 and 4.
    public static let id = 2

    public init(id: Int = Self.id, name: String, x: Int, y: Int, width: Int, height: Int, items: [String]) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.items = items
    }

    init(_ list: FrameList) {
        self.init(name: String(list.name.prefix(14)), x: list.x, y: list.y, width: list.width, height: list.height,
                  items: list.items)
    }
}

/// One image container on the page: a small monochrome bitmap (the attention and location
/// indicators). The bitmap is already encoded as the 4 bpp BMP (+ LZ4) the nav maps use
/// (`NavMapBmp`); the container's size is the bitmap's size.
///
/// **Unverified on hardware:** the container and upload layouts in `G2Payload` are reconstructed
/// from the Even Hub / even-g2-protocol schemas and the map upload they share a format with; no
/// capture of an EvenHub image container exists yet.
public struct G2ImageBox: Equatable, Sendable {
    public var id: Int
    /// ≤ 14 characters, like text containers.
    public var name: String
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// The BMP, LZ4-compressed when that is smaller (see `compression`).
    public var data: [UInt8]
    public var compression: NavMapBmp.Compression

    public static let attentionID = 3
    public static let locationID = 4

    public init(id: Int, name: String, x: Int, y: Int, width: Int, height: Int, data: [UInt8],
                compression: NavMapBmp.Compression) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.data = data
        self.compression = compression
    }

    /// Encodes a monochrome bitmap (lit pixels full brightness, the rest off) as a container at (x, y).
    public init?(id: Int, name: String, x: Int, y: Int, bitmap: MonoBitmap) {
        guard let encoded = NavMapBmp.encode(bitmap) else { return nil }
        self.init(id: id, name: name, x: x, y: y, width: bitmap.width, height: bitmap.height,
                  data: encoded.data, compression: encoded.mode)
    }

    /// Same place and size (the data may differ): a different geometry needs a page rebuild.
    func sameGeometry(as other: G2ImageBox) -> Bool {
        id == other.id && name == other.name && x == other.x && y == other.y && width == other.width && height == other.height
    }
}

/// Decides what to send to show a frame, given what the glasses show now. Pure, so the diffing is
/// testable without Bluetooth.
///
/// - First frame of a session: Cmd 0 CreateStartUpPage with the frame's containers.
/// - Same containers in the same places: Cmd 5 text updates, only for those whose text changed.
/// - Other containers, or the page state is unknown after a failure: Cmd 7 RebuildPage.
public struct G2PagePlanner: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case create([G2TextBox], list: G2ListBox? = nil, images: [G2ImageBox] = [])
        case rebuild([G2TextBox], list: G2ListBox? = nil, images: [G2ImageBox] = [])
        case update(id: Int, name: String, text: String)
        /// Upload an image container's pixels. Always follows the create or rebuild that made the
        /// container, or comes alone when only the pixels changed.
        case uploadImage(G2ImageBox)
    }

    private enum State: Equatable, Sendable {
        /// No page yet this session.
        case none
        /// The list goes in whole: changing its items needs a rebuild.
        case live(shape: [G2TextBox], list: G2ListBox?, texts: [Int: String], images: [G2ImageBox])
        /// A page exists, but we don't know what it shows (a send failed).
        case unknown
    }

    private var state = State.none

    public init() {}

    /// Whether a page has been created this session. IMU and mic only work with a live page.
    public var hasPage: Bool { state != .none }

    /// The text containers on the page now, without their text.
    public var shape: [G2TextBox]? {
        if case .live(let shape, _, _, _) = state { return shape }
        return nil
    }

    /// The commands that show `frame`, and assumes they all succeed. Call `markUnknown()` if one
    /// fails.
    public mutating func plan(_ frame: GlassesFrame) -> [Command] {
        let boxes = G2TextBox.boxes(for: frame)
        let shape = boxes.map(\.geometry)
        let texts = Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0.text) })

        let list = frame.list.map(G2ListBox.init)
        let images = frame.images
        let commands: [Command]
        switch state {
        case .none:
            commands = [.create(boxes, list: list, images: images)] + images.map { .uploadImage($0) }
        case .live(let current, let shownList, let shown, let shownImages)
            where current == shape && shownList == list && Self.sameImageGeometry(shownImages, images):
            commands = boxes.filter { shown[$0.id] != $0.text }
                .map { .update(id: $0.id, name: $0.name, text: $0.text) }
                + images.filter { image in shownImages.first { $0.id == image.id }?.data != image.data }
                .map { .uploadImage($0) }
        case .live, .unknown:
            commands = [.rebuild(boxes, list: list, images: images)] + images.map { .uploadImage($0) }
        }
        state = .live(shape: shape, list: list, texts: texts, images: images)
        return commands
    }

    /// A send failed: the next frame rebuilds the page instead of updating it. A page can only be
    /// created once per session, so this never goes back to `create`.
    public mutating func markUnknown() {
        if state != .none { state = .unknown }
    }

    /// The session ended (disconnect): the next frame creates a new page.
    public mutating func reset() {
        state = .none
    }

    private static func sameImageGeometry(_ a: [G2ImageBox], _ b: [G2ImageBox]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.sameGeometry(as: $1) }
    }

}
