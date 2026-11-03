import Foundation

/// Something you can undo right after Lotti did it for you (a Bring! item added, a setting
/// changed). The backend hands it out with the answer; tapping "Undo" sends it back.
public struct UndoAction: Equatable, Sendable {
    public var id: String
    /// The rail title ("Undo", "Undo: milk").
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Undo" : label
    }
}

/// Lotti's answer in a chat: one or two short sentences, plus choices for the rail.
public struct Answer: Equatable, Sendable {
    public var sentence: String
    /// Things you might ask next, each 1 to 3 words. At most three.
    public var followUps: [String]
    /// Actions the brain prepared; each runs only when you tap it (phone actions on the phone,
    /// server actions through the backend's `perform`). At most two.
    public var actions: [ProposedAction]
    /// Set when the backend already did something for you: tapping it takes it back.
    public var undo: UndoAction?

    public init(sentence: String, followUps: [String] = [], actions: [ProposedAction] = [], undo: UndoAction? = nil) {
        self.sentence = sentence
        self.followUps = Array(followUps.prefix(3))
        self.actions = Array(actions.prefix(2))
        self.undo = undo
    }
}

/// The offline chat model behind Lotti (on-device). A conversation keeps its context until
/// `endConversation()`. It only handles timers, navigation, reminders and the local day;
/// everything else gets a short "I'm offline" sentence (see `OfflineSentences`).
@MainActor
public protocol Brain: AnyObject {
    /// Load the model ahead of the first question, so the first answer is faster.
    func prewarm()
    /// Answer `message`. `context` is the current date and time; everything else comes from
    /// tools. `status` gets short lines for the glasses while it works.
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer
    func endConversation()
}

/// The backend ("Lotti Brain"), which answers whenever it can be reached. It keeps one ongoing
/// conversation on its side; nothing here ends it. Cancelling the calling task cancels the ask.
@MainActor
public protocol RemoteBrain: AnyObject {
    /// True while the backend socket is up. The router asks the backend only then.
    var isReachable: Bool { get }
    /// Answer `message`. `status` gets short lines for the glasses while it works; `activity`
    /// fires on any sign of life from the backend (a status line, a tool call), so the caller can
    /// tell "still working" from "silent".
    func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer
}

/// Your words, as far as the recognizer has heard them.
public struct Transcript: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(_ text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Speech-to-text. `transcribe` reads 16 kHz mono PCM until `audio` finishes, yielding the
/// transcript as it grows, and finishes after the final result.
@MainActor
public protocol SpeechRecognizer: AnyObject {
    func prepare() async
    func transcribe(_ audio: AsyncStream<[Int16]>) -> AsyncThrowingStream<Transcript, Error>
}

/// A microphone that isn't the glasses' (the phone's), used when the glasses' mic fails.
@MainActor
public protocol Microphone: AnyObject {
    /// 16 kHz mono PCM chunks until `stop()`.
    func start() async throws -> AsyncStream<[Int16]>
    func stop() async
}
