import Foundation

/// Lotti's answer in a chat: one or two short sentences, plus choices for the rail.
public struct Answer: Equatable, Sendable {
    public var sentence: String
    /// Things you might ask next, each 1 to 3 words. At most three.
    public var followUps: [String]
    /// Phone actions the brain prepared; each runs only when you tap it. At most two.
    public var actions: [ProposedAction]
    /// Set by the on-device brain when the question needs Hermes: the question to pass on.
    public var handoff: String?

    public init(sentence: String, followUps: [String] = [], actions: [ProposedAction] = [], handoff: String? = nil) {
        self.sentence = sentence
        self.followUps = Array(followUps.prefix(3))
        self.actions = Array(actions.prefix(2))
        self.handoff = handoff.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// The chat model behind Lotti. A conversation keeps its context until `endConversation()`.
@MainActor
public protocol Brain: AnyObject {
    /// Load the model ahead of the first question, so the first answer is faster.
    func prewarm()
    /// Answer `message`. `context` is the current date and time; everything else comes from
    /// tools. `status` gets short lines for the glasses while it works.
    func answer(_ message: String, context: String, status: @escaping @MainActor (String) -> Void) async throws -> Answer
    func endConversation()
}

/// A bigger brain somewhere else (your Hermes), for what the phone can't answer. Keeps its
/// own conversation until `endConversation()`.
@MainActor
public protocol RemoteBrain: AnyObject {
    /// False until you set it up in the app.
    var isConfigured: Bool { get }
    /// Answer `message`. `status` gets short lines for the glasses while it works; `activity`
    /// fires on any sign of life from the remote (a token, a keepalive, tool progress), so the
    /// caller can tell "still working" from "silent".
    func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer
    func endConversation()
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
