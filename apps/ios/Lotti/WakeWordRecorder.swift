@preconcurrency import AVFoundation
import LottiKit
import Observation

/// Records training clips from the glasses' mic for the wake word model (Debug screen). Clips are
/// 16 kHz mono WAV files in `Documents/wakeword/{hey_lotti,background}/`; copy them off with
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///       --domain-identifier de.janjaap.lotti --source Documents/wakeword \
///       --destination packages/wake-word/data/user
///
/// and run `pnpm nx run wake-word:train`.
@MainActor
@Observable
final class WakeWordRecorder {
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "wakeword")

    enum Activity: Equatable {
        case phrase
        /// Clip `index` of `count`; `pause` between clips.
        case series(index: Int, count: Int, pause: Bool)
        case background
    }

    private(set) var activity: Activity?
    private(set) var counts: [String: Int] = [:]
    private(set) var error: String?

    private let conductor: Conductor
    private var task: Task<Void, Never>?

    init(conductor: Conductor) {
        self.conductor = conductor
        refresh()
    }

    var busyText: String? {
        switch activity {
        case nil: nil
        case .phrase: "Say \"Hey Lotti\"…"
        case .series(let index, let count, let pause): pause ? "…" : "Say \"Hey Lotti\" now (\(index)/\(count))"
        case .background: "Recording background…"
        }
    }

    func refresh() {
        for label in ["hey_lotti", "background"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.appending(path: label).path())) ?? []
            counts[label] = files.filter { $0.hasSuffix(".wav") }.count
        }
    }

    /// One 2 s clip. Say "Hey Lotti" right after tapping.
    func recordPhrase() {
        run(.phrase) { await $0.capture(label: "hey_lotti", seconds: 2, piece: 2) }
    }

    /// `count` clips in a row, a pause between: say "Hey Lotti" at each prompt, vary tone, speed and distance.
    func recordSeries(count: Int = 30) {
        run(.series(index: 1, count: count, pause: false)) { recorder in
            for index in 1...count where !Task.isCancelled {
                recorder.activity = .series(index: index, count: count, pause: false)
                guard await recorder.capture(label: "hey_lotti", seconds: 2, piece: 2) else { return }
                recorder.activity = .series(index: index, count: count, pause: true)
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    /// Background audio (talk, TV, noise), cut into 1 s pieces until stopped (at most 15 minutes).
    func startBackground() {
        run(.background) { await $0.capture(label: "background", seconds: 15 * 60, piece: 1) }
    }

    func stop() { task?.cancel() }

    /// Runs one recording job. The wake word is paused meanwhile: the clips are full of "Hey Lotti".
    private func run(_ first: Activity, _ job: @escaping @MainActor (WakeWordRecorder) async -> Void) {
        guard task == nil else { return }
        activity = first
        error = nil
        conductor.wakePaused = true
        task = Task {
            await job(self)
            conductor.wakePaused = false
            task = nil
            activity = nil
            refresh()
        }
    }

    /// Records from the glasses' mic. False if the mic wouldn't start.
    private func capture(label: String, seconds: Double, piece: Double) async -> Bool {
        let hub = conductor.microphone
        let subscription: MicrophoneHub.Subscription
        do { subscription = try await hub.subscribe() } catch {
            self.error = error.localizedDescription
            return false
        }
        let size = Int(piece * 16_000)
        let limit = Int(seconds * 16_000)
        var buffer: [Int16] = []
        var total = 0
        for await chunk in subscription.stream {
            if Task.isCancelled { break }
            buffer += chunk
            total += chunk.count
            while buffer.count >= size {
                save(Array(buffer.prefix(size)), label: label)
                buffer.removeFirst(size)
            }
            if total >= limit { break }
        }
        await hub.unsubscribe(subscription)
        refresh()
        return true
    }

    private func save(_ samples: [Int16], label: String) {
        do {
            let directory = Self.root.appending(path: label)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
            let url = directory.appending(path: "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(4)).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            samples.withUnsafeBufferPointer { pcm.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: pcm)
            counts[label, default: 0] += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}
