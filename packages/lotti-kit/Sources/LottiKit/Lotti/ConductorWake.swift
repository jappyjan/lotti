import Foundation

/// What the "Hey Lotti" listener is doing.
public enum WakeState: Equatable, Sendable {
    /// Switched off in the settings, or the glasses aren't connected.
    case off
    case listening
    /// The glasses' microphone won't start (the string says why); retrying.
    case unavailable(String)
}

/// One "Hey Lotti" in progress: a candidate from the classifier, the speech recognizer listening
/// to decide whether it is real, and, once confirmed, the command that follows.
@MainActor
final class WakeSession {
    let score: Double
    let input: AsyncStream<[Int16]>.Continuation
    var task: Task<String, Never>?
    var confirmTimer: Task<Void, Never>?
    var endpointer: Endpointer
    var confirmed = false
    /// The latest transcript, wake phrase included.
    var transcript = ""
    /// What was said after the wake phrase so far.
    var command = ""
    var samples: Int

    init(score: Double, input: AsyncStream<[Int16]>.Continuation, endpointer: Endpointer, preRoll: Int) {
        self.score = score
        self.input = input
        self.endpointer = endpointer
        samples = preRoll
    }
}

/// "Hey Lotti": a voice command without a gesture. The glasses' mic stays on (shared through
/// `MicrophoneHub`); an energy gate and a sound classifier watch it, and a candidate has to be
/// confirmed by the speech recognizer before anything shows. Then the command runs like a hold.
extension Conductor {
    /// Switch the listener on or off (the "Listen for 'Hey Lotti'" setting).
    public func setWakeWord(enabled: Bool) {
        wakeEnabled = enabled
        restartWake()
    }

    /// Classifier confidence needed for a candidate (Debug).
    public var wakeThreshold: Double {
        get { wakeDetector?.threshold ?? WakeWordDetector.defaultThreshold }
        set { wakeDetector?.threshold = newValue }
    }

    /// The newest classifier score, for Debug.
    public var wakeScore: Double? { wakeDetector?.lastScore }

    /// (Re)starts listening for the wake word, or stops it if it shouldn't run.
    func restartWake() {
        wakeTask?.cancel()
        wakeTask = nil
        let wasListening = wakeSession?.confirmed == true && mode == .listening
        abortWakeSession(reason: "restarting")
        // A wake listen has nothing feeding it any more: don't leave "Listening…" up.
        if wasListening { goDark() }
        guard wakeEnabled, wakeDetector != nil, link.status.isConnected else {
            wakeState = .off
            if microphone.keepOpen { Task { await microphone.setKeepOpen(false) } }
            return
        }
        wakeTask = Task { await runWake() }
    }

    private func runWake() async {
        var delay = timing.micRetry
        while !Task.isCancelled, wakeEnabled, link.status.isConnected {
            await microphone.setKeepOpen(true)
            var healthy = false
            do {
                let subscription = try await microphone.subscribe()
                if Task.isCancelled {
                    await microphone.unsubscribe(subscription)
                    return
                }
                wakeState = .listening
                wakeLog("mic on")
                healthy = await consumeWake(subscription)
                await microphone.unsubscribe(subscription)
                wakeLog("mic stopped")
                if !healthy, !Task.isCancelled { wakeState = .unavailable("No audio from the glasses' mic") }
            } catch {
                wakeState = .unavailable(error.localizedDescription)
                wakeLog("glasses mic unavailable: \(error.localizedDescription)")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: delay)
            delay = healthy ? timing.micRetry : min(delay * 2, timing.micRetryMax)
        }
        if !Task.isCancelled {
            wakeState = .off
            await microphone.setKeepOpen(false)
        }
    }

    /// Reads the shared mic until it ends. True if audio kept coming for longer than the watchdog
    /// limit (a mic that sends a burst and stalls counts as unhealthy, so the retries back off).
    private func consumeWake(_ subscription: MicrophoneHub.Subscription) async -> Bool {
        var firstChunk: ContinuousClock.Instant?
        var lastChunk: ContinuousClock.Instant?
        var reset = false
        var reported = 0.0
        var levelMax = 0.0
        var activeChunks = 0
        var chunks = 0
        let started = ContinuousClock.now
        let hub = microphone
        let limit = timing.micWatchdog
        let dog = Task { @MainActor () -> Bool in
            while !Task.isCancelled {
                try? await Task.sleep(for: limit / 3)
                if Task.isCancelled { return false }
                if ContinuousClock.now - max(hub.lastChunk ?? started, started) > limit {
                    await hub.restart()
                    return true
                }
            }
            return false
        }
        for await chunk in subscription.stream {
            if firstChunk == nil { firstChunk = .now }
            lastChunk = .now
            let active = wakeGate.process(chunk)
            levelMax = max(levelMax, wakeGate.level)
            chunks += 1
            if active { activeChunks += 1 }
            if chunks == 200 {  // about every 10 s
                let stats = wakeDetector?.takeStats() ?? (windows: 0, maxScore: 0)
                wakeLog(String(format: "audio level max %.3f, gate at %.3f, loud %d/200 chunks, %d windows scored, best %.2f",
                               levelMax, wakeGate.threshold, activeChunks, stats.windows, stats.maxScore))
                levelMax = 0
                activeChunks = 0
                chunks = 0
            }
            if let session = wakeSession {
                feedWake(session, chunk, active: active)
                continue
            }
            // Hold-to-talk has the audio now (or the Debug recorder does); start the detector from
            // scratch when it's over.
            if mode == .listening || wakePaused {
                reset = true
                continue
            }
            guard let detector = wakeDetector else { continue }
            if reset {
                detector.reset()
                reset = false
            }
            if let candidate = await detector.process(chunk, active: active), !Task.isCancelled,
               mode != .listening, !wakePaused, wakeSession == nil {
                // The firmware's navigation screen is up: there is no Lotti screen to listen on.
                if link.displaySuspended {
                    wakeLog(String(format: "candidate %.2f ignored: navigation screen is up", candidate.score))
                    wakeLast = String(format: "%.2f ignored: navigation screen is up", candidate.score)
                } else {
                    beginWakeSession(candidate)
                }
            }
            if detector.classifiedSeconds - reported >= 30 {
                reported = detector.classifiedSeconds
                reportWakeMinutes()
            }
        }
        dog.cancel()
        if await dog.value { wakeLog("no audio for \(limit); mic restarted") }
        // The mic stopped under a running wake listen: answer what was heard (or go dark).
        if !Task.isCancelled, let session = wakeSession {
            if session.confirmed, mode == .listening {
                endWakeCommand(session)
            } else {
                abortWakeSession(reason: "mic stopped")
            }
        }
        guard let firstChunk, let lastChunk else { return false }
        return lastChunk - firstChunk > limit
    }

    // MARK: - Candidate and confirmation

    private func beginWakeSession(_ candidate: WakeCandidate) {
        let speech = self.speech
        wakeLog(String(format: "candidate %.2f", candidate.score))
        let (stream, input) = AsyncStream<[Int16]>.makeStream()
        input.yield(candidate.preRoll)
        let session = WakeSession(
            score: candidate.score, input: input,
            endpointer: Endpointer(silence: timing.wakeSilence, noCommand: timing.wakeNoCommand, cap: timing.wakeCap),
            preRoll: candidate.preRoll.count)
        wakeSession = session
        session.task = Task { @MainActor [weak self] in
            var heard = ""
            do {
                for try await transcript in speech.transcribe(stream) {
                    heard = transcript.text
                    self?.wakeHeard(session, heard)
                }
            } catch {
                self?.wakeLog("speech failed: \(error.localizedDescription)")
            }
            return heard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let window = timing.wakeConfirm
        session.confirmTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.wakeSession === session, !session.confirmed else { return }
            self.rejectWake(session)
        }
    }

    private func wakeHeard(_ session: WakeSession, _ text: String) {
        guard wakeSession === session else { return }
        session.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = WakeWordMatcher.match(text) else { return }
        session.command = match.command
        if !session.confirmed { confirmWake(session) }
        guard mode == .listening else { return }
        lastPartial = match.command
        if !match.command.isEmpty { show(Screen(.listening, match.command), timeout: false) }
    }

    /// The recognizer heard "Hey Lotti": from here on it is like a hold.
    private func confirmWake(_ session: WakeSession) {
        session.confirmed = true
        session.confirmTimer?.cancel()
        wakeLog(String(format: "confirmed %.2f, listen started: %@", session.score, session.transcript))
        wakeLast = String(format: "%.2f confirmed: ", session.score) + session.transcript
        timer?.cancel()
        thinking?.cancel()
        backStack = []
        mode = .listening
        show(Screen(.listening, "Listening…"), timeout: false)
        lastPartial = ""
        microphoneSource = "glasses"
        listening = session.task
    }

    private func rejectWake(_ session: WakeSession) {
        let heard = session.transcript.isEmpty ? "(nothing heard)" : session.transcript
        wakeLog(String(format: "rejected %.2f: %@", session.score, heard))
        wakeLast = String(format: "%.2f rejected, no \"Hey Lotti\" in %@: ", session.score, "\(timing.wakeConfirm)") + heard
        abortWakeSession(reason: nil)
    }

    /// Drops the candidate or the running wake listen. Nothing is shown; `reason` goes to the log.
    func abortWakeSession(reason: String?) {
        guard let session = wakeSession else { return }
        wakeSession = nil
        session.confirmTimer?.cancel()
        session.input.finish()
        session.task?.cancel()
        if let reason {
            wakeLog(session.confirmed ? "listen ended: \(reason)" : "candidate dropped: \(reason)")
            if !session.confirmed { wakeLast = String(format: "%.2f dropped: ", session.score) + reason }
        }
        wakeDetector?.reset()
        endedWake(session)
    }

    private func endedWake(_ session: WakeSession) {
        wakeStage2Seconds += Double(session.samples) / Double(WakeWordDetector.sampleRate)
        reportWakeMinutes()
    }

    private func reportWakeMinutes() {
        wakeMinutes = ((wakeDetector?.classifiedSeconds ?? 0) / 60, wakeStage2Seconds / 60)
        wakeLog(String(format: "ran %.1f min classifier, %.1f min speech", wakeMinutes.stage1, wakeMinutes.stage2))
    }

    // MARK: - The command

    private func feedWake(_ session: WakeSession, _ chunk: [Int16], active: Bool) {
        session.input.yield(chunk)
        session.samples += chunk.count
        guard session.confirmed, mode == .listening else { return }
        session.endpointer.feed(samples: chunk.count, active: active)
        switch session.endpointer.outcome(hasCommand: !session.command.isEmpty) {
        case nil: break
        case .endOfSpeech, .cap: endWakeCommand(session)
        case .noCommand:
            wakeLog("no command after the wake phrase")
            abortWakeSession(reason: "no command")
            // Probably a false wake: go dark, but keep the conversation.
            goDark()
        }
    }

    /// The command is over (quiet for a while, or the cap): answer like `stopListening` does.
    func endWakeCommand(_ session: WakeSession) {
        guard wakeSession === session else { return }
        wakeSession = nil
        session.confirmTimer?.cancel()
        session.input.finish()
        wakeDetector?.reset()
        endedWake(session)
        wakeLog("listen ended after \(String(format: "%.1f", Double(session.samples) / Double(WakeWordDetector.sampleRate))) s of audio")
        mode = .working
        show(Screen(.working, "Let me think…"), timeout: false)
        guard let task = session.task else { return }
        thinking = Task {
            // The transcript stream ends once the recognizer has the final result.
            let final = await withTimeout(timing.finalTranscript) { await task.value }
            self.listening = nil
            guard !Task.isCancelled, mode == .working else { return }
            let heard = final.flatMap { WakeWordMatcher.match($0)?.command }.flatMap { $0.isEmpty ? nil : $0 } ?? session.command
            lastHeard = heard
            if heard.isEmpty {
                // Probably a false wake: no "Sorry", just go dark (the conversation stays).
                goDark()
            } else {
                await answer(heard)
            }
        }
    }

    func wakeLog(_ message: String) {
        print("[Wake] \(message)")
    }
}
