import Foundation

/// Lotti's answer in a chat: one or two short sentences, plus follow-ups for the rail.
public struct Answer: Equatable, Sendable {
    public var sentence: String
    /// Things you might ask next, each 1 to 3 words. At most three.
    public var followUps: [String]

    public init(sentence: String, followUps: [String] = []) {
        self.sentence = sentence
        self.followUps = Array(followUps.prefix(3))
    }
}

/// The chat model behind Lotti. A conversation keeps its context until `endConversation()`.
@MainActor
public protocol Brain: AnyObject {
    /// Load the model ahead of the first question, so the first answer is faster.
    func prewarm()
    /// Answer `message`. `context` is a short description of now (time, calendar, weather).
    func answer(_ message: String, context: String) async throws -> Answer
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
