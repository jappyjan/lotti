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

    private(set) var busy: String?
    private(set) var counts: [String: Int] = [:]
    private(set) var error: String?

    private let hub: MicrophoneHub
    private var task: Task<Void, Never>?

    init(hub: MicrophoneHub) {
        self.hub = hub
        refresh()
    }

    func refresh() {
        for label in ["hey_lotti", "background"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.root.appending(path: label).path())) ?? []
            counts[label] = files.filter { $0.hasSuffix(".wav") }.count
        }
    }

    /// One 2 s clip. Say "Hey Lotti" right after tapping.
    func recordPhrase() {
        guard task == nil else { return }
        busy = "Say \"Hey Lotti\"…"
        task = Task {
            await capture(label: "hey_lotti", seconds: 2, piece: 2)
            finish()
        }
    }

    /// Background audio (talk, TV, noise), cut into 1 s pieces until stopped.
    func startBackground() {
        guard task == nil else { return }
        busy = "Recording background…"
        task = Task {
            await capture(label: "background", seconds: nil, piece: 1)
            finish()
        }
    }

    func stop() { task?.cancel() }

    private func finish() {
        task = nil
        busy = nil
        refresh()
    }

    private func capture(label: String, seconds: Double?, piece: Double) async {
        error = nil
        let subscription: MicrophoneHub.Subscription
        do { subscription = try await hub.subscribe() } catch {
            self.error = error.localizedDescription
            return
        }
        let size = Int(piece * 16_000)
        let limit = seconds.map { Int($0 * 16_000) }
        var buffer: [Int16] = []
        var total = 0
        for await chunk in subscription.stream {
            if Task.isCancelled { break }
            buffer += chunk
            total += chunk.count
            while buffer.count >= size {
                save(Array(buffer.prefix(size)), label: label)
                buffer.removeFirst(size)
                refresh()
            }
            if let limit, total >= limit { break }
        }
        await hub.unsubscribe(subscription)
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}
