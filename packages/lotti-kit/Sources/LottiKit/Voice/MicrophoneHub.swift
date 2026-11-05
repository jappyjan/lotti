import Foundation

/// One open glasses microphone, shared. Hold-to-talk, the "Hey Lotti" listener and the Debug
/// recorder each `subscribe()` and get the same audio; the glasses' mic is switched on when the
/// first one subscribes and off when the last leaves, unless `keepOpen` holds it open (wake word
/// on). Switching it off and on between uses would add latency and could miss the first word.
@MainActor
public final class MicrophoneHub {
    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<[Int16]>
    }

    private let link: any GlassesLink
    private var subscribers: [UUID: AsyncStream<[Int16]>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var opening: Task<Void, Error>?
    private var closing: Task<Void, Never>?

    /// Keep the glasses' mic on even with nobody subscribed. Set by whoever needs it always on.
    public private(set) var keepOpen = false
    /// When the last chunk arrived, for the watchdog.
    public private(set) var lastChunk: ContinuousClock.Instant?
    /// Times the glasses' mic was switched on (for logs and tests).
    public private(set) var opened = 0

    public init(link: any GlassesLink) {
        self.link = link
    }

    public var isOpen: Bool { pump != nil }

    /// Audio from now on. Opens the glasses' mic if needed; throws if it won't start.
    public func subscribe() async throws -> Subscription {
        // 5 s of chunks, like the link's own stream: a stalled subscriber can't pile up audio.
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(100))
        let id = UUID()
        subscribers[id] = continuation
        do {
            try await ensureOpen()
        } catch {
            subscribers[id] = nil
            continuation.finish()
            throw error
        }
        // The stream may have ended while we waited; then this subscriber was finished with it.
        return Subscription(id: id, stream: stream)
    }

    /// Ends the subscription's stream; switches the mic off if it was the last and `keepOpen` is off.
    public func unsubscribe(_ subscription: Subscription) async {
        subscribers.removeValue(forKey: subscription.id)?.finish()
        await closeIfIdle()
    }

    public func setKeepOpen(_ keep: Bool) async {
        keepOpen = keep
        await closeIfIdle()
    }

    /// Switches the mic off and on again (the firmware only streams on an off → on edge). Current
    /// subscribers see their streams end.
    public func restart() async {
        await close()
    }

    private func ensureOpen() async throws {
        await closing?.value
        if pump != nil { return }
        if let opening { return try await opening.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = try await link.startMicrophone()
            opened += 1
            lastChunk = .now
            pump = Task { @MainActor [weak self] in
                for await chunk in stream {
                    guard let self else { return }
                    lastChunk = .now
                    for continuation in subscribers.values { continuation.yield(chunk) }
                }
                // Cancelled means we closed it ourselves (and a newer stream may be running).
                if !Task.isCancelled { self?.streamEnded() }
            }
        }
        opening = task
        defer { opening = nil }
        try await task.value
    }

    /// The link ended the stream on its own (the glasses dropped, the firmware stopped the mic).
    private func streamEnded() {
        pump = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    private func closeIfIdle() async {
        if subscribers.isEmpty, !keepOpen, pump != nil { await close() }
    }

    private func close() async {
        if let closing { return await closing.value }
        // Who is subscribed now ends now: someone subscribing meanwhile waits for `closing`, then reopens.
        pump?.cancel()
        pump = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        let task = Task { @MainActor in await self.link.stopMicrophone() }
        closing = task
        await task.value
        closing = nil
    }
}
