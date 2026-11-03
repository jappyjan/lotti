import Dispatch
import Foundation
import LottiKit

/// `wake-word generate`: synthetic training clips from macOS `say`, run through the LC3 codec.
enum Generate {
    struct Voice { var name: String; var locale: String }

    struct Job {
        var id: String
        var voice: Voice
        var rate: Int
        var text: String
        var label: String
        /// Cut to the first ~1.3 s (the wake phrase of a phrase + command).
        var cropToPhrase: Bool
        var variants: Int
    }

    /// Novelty voices that don't sound like people.
    static let novelty: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Wobble", "Fred", "Good News", "Jester", "Junior",
        "Organ", "Superstar", "Ralph", "Trinoids", "Whisper", "Zarvox", "Kathy",
    ]

    static func voices() throws -> [Voice] {
        let list = try shell("/usr/bin/say", ["-v", "?"])
        return list.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^(.*?)\s+((?:de|en)_[A-Z]{2})\s+#/) else { return nil }
            let name = String(match.1)
            return novelty.contains(name) ? nil : Voice(name: name, locale: String(match.2))
        }
    }

    static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    }

    static func jobs(voices: [Voice]) -> [Job] {
        var jobs: [Job] = []
        func add(_ kind: String, _ text: String, label: String, rates: [Int], crop: Bool, variants: Int) {
            for voice in voices {
                for rate in rates {
                    jobs.append(Job(id: "\(kind)-\(slug(voice.name))-r\(rate)-\(slug(text))", voice: voice, rate: rate, text: text,
                                    label: label, cropToPhrase: crop, variants: variants))
                }
            }
        }
        for text in Phrases.wake { add("pos", text, label: "hey_lotti", rates: [140, 175, 215], crop: false, variants: 4) }
        for text in Phrases.withCommand { add("pos", text, label: "hey_lotti", rates: [160, 200], crop: true, variants: 4) }
        for text in Phrases.nearMisses { add("near", text, label: "background", rates: [150, 190], crop: false, variants: 3) }
        for text in Phrases.speech { add("bg", text, label: "background", rates: [170], crop: false, variants: 4) }
        return jobs
    }

    static func run() throws {
        let started = Date()
        let manager = FileManager.default
        for label in Paths.classes {
            try manager.createDirectory(at: Paths.synthetic.appending(path: label), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: Paths.raw, withIntermediateDirectories: true)

        let voices = try voices()
        guard !voices.isEmpty else { throw ToolError("no German or English voices found (say -v ?)") }
        print("voices: \(voices.count) (\(voices.map(\.name).joined(separator: ", ")))")
        let jobs = jobs(voices: voices)
        print("speaking \(jobs.count) phrases…")
        try speak(jobs)

        // Start clean: the synthetic set is derived data.
        for label in Paths.classes {
            for file in Paths.wavs(Paths.synthetic.appending(path: label)) { try? manager.removeItem(at: file) }
        }
        var written = 0
        var babbleSources: [[Int16]] = []
        for job in jobs {
            let raw = try Audio.read(Paths.raw.appending(path: "\(job.id).wav"))
            var rng = Random(seed: job.id)
            let pieces = job.label == "hey_lotti" ? [prepare(raw, crop: job.cropToPhrase)] : chop(trim(raw), maxSeconds: 2)
            if job.id.hasPrefix("bg-"), babbleSources.count < 300 { babbleSources.append(trim(raw)) }
            for (index, piece) in pieces.enumerated() {
                for variant in 0..<job.variants {
                    let samples = augment(pad(piece, tight: job.label == "hey_lotti", &rng), &rng)
                    let name = "\(job.id)\(pieces.count > 1 ? "-\(index)" : "")~\(variant).wav"
                    try Audio.write(samples, to: Paths.synthetic.appending(path: "\(job.label)/\(name)"))
                    written += 1
                }
            }
        }
        written += try noise(babble: babbleSources)
        let seconds = Int(Date().timeIntervalSince(started))
        print("wrote \(written) clips to \(Paths.synthetic.path) in \(seconds) s")
    }

    /// Your recordings (`data/user/<class>/*.wav`, found at any depth) cut down to the phrase, with a
    /// few level and noise variants each, into `data/user-prepared/`. They are already LC3 audio.
    static func prepareUserClips() throws {
        let manager = FileManager.default
        try? manager.removeItem(at: Paths.userPrepared)
        for label in Paths.classes {
            let out = Paths.userPrepared.appending(path: label)
            try manager.createDirectory(at: out, withIntermediateDirectories: true)
            guard let walker = manager.enumerator(at: Paths.user, includingPropertiesForKeys: nil) else { continue }
            let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "wav" && $0.pathComponents.contains(label) }
            for url in files.sorted(by: { $0.path < $1.path }) {
                var rng = Random(seed: url.lastPathComponent)
                var piece = try Audio.read(url)
                let name = url.deletingPathExtension().lastPathComponent
                if label == "hey_lotti" {
                    // The phrase is the loud part; keep a little room around it, at least one window.
                    let peak = Int(piece.map { abs(Int($0)) }.max() ?? 0)
                    let limit = max(peak / 12, 60)
                    guard let first = piece.firstIndex(where: { abs(Int($0)) > limit }),
                          let last = piece.lastIndex(where: { abs(Int($0)) > limit }) else { continue }
                    piece = Array(piece[max(first - 1600, 0)...min(last + 1600, piece.count - 1)])
                    if piece.count < Audio.rate { piece += [Int16](repeating: 0, count: Audio.rate - piece.count) }
                }
                for variant in 0..<(label == "hey_lotti" ? 6 : 2) {
                    var signal = piece.map { Double($0) / 32768 }
                    if variant > 0 {
                        let gain = Double.random(in: 0.4...1.6, using: &rng)
                        let power = (signal.map { $0 * $0 }.reduce(0, +) / Double(max(signal.count, 1))).squareRoot()
                        let hiss = coloredNoise(count: signal.count, &rng)
                        let level = power / pow(10, Double.random(in: 10...30, using: &rng) / 20)
                        for index in signal.indices { signal[index] = (signal[index] + hiss[index] * level) * gain }
                    }
                    let pcm = signal.map { Int16(max(min($0, 0.999), -0.999) * 32767) }
                    try Audio.write(pcm, to: out.appending(path: "user-\(name)~\(variant).wav"))
                }
            }
        }
    }

    // MARK: say

    static func speak(_ jobs: [Job]) throws {
        let todo = jobs.filter { !FileManager.default.fileExists(atPath: Paths.raw.appending(path: "\($0.id).wav").path) }
        print("\(jobs.count - todo.count) cached, \(todo.count) to speak")
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: todo.count) { index in
            let job = todo[index]
            let out = Paths.raw.appending(path: "\(job.id).wav")
            do {
                // say sometimes fails to open its output under load (error -54): try again.
                for attempt in 1...3 {
                    do {
                        _ = try shell("/usr/bin/say", ["-v", job.voice.name, "-r", String(job.rate), "-o", out.path,
                                                       "--data-format=LEI16@16000", job.text])
                        break
                    } catch {
                        if attempt == 3 { throw error }
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
            } catch {
                failures.add("\(job.id): \(error)")
                try? FileManager.default.removeItem(at: out)
            }
        }
        if !failures.items.isEmpty { throw ToolError("say failed for \(failures.items.count) phrases, first: \(failures.items[0])") }
    }

    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ item: String) { lock.withLock { list.append(item) } }
        var items: [String] { lock.withLock { list } }
    }

    static func shell(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ToolError("\(tool) exited \(process.terminationStatus): \(output.prefix(200))") }
        return output
    }

    // MARK: Shaping

    /// Cuts silence off both ends, keeping a short margin.
    static func trim(_ samples: [Int16]) -> [Int16] {
        let peak = Int(samples.map { abs(Int($0)) }.max() ?? 0)
        guard peak > 0 else { return samples }
        let limit = max(peak / 40, 30)
        guard let first = samples.firstIndex(where: { abs(Int($0)) > limit }),
              let last = samples.lastIndex(where: { abs(Int($0)) > limit }) else { return samples }
        return Array(samples[max(first - 800, 0)...min(last + 800, samples.count - 1)])
    }

    static func prepare(_ raw: [Int16], crop: Bool) -> [Int16] {
        let trimmed = trim(raw)
        return crop ? Array(trimmed.prefix(Int(1.3 * Double(Audio.rate)))) : trimmed
    }

    static func chop(_ samples: [Int16], maxSeconds: Double) -> [[Int16]] {
        let size = Int(maxSeconds * Double(Audio.rate))
        let pieces = stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
        return pieces.filter { $0.count >= Audio.rate * 8 / 10 }
    }

    /// Room before and after, and at least 1.2 s in all (1.0 s for wake phrases), so a classifier window always fits.
    /// `tight` (wake phrase clips): barely longer than one classifier window, so every window of
    /// the clip holds the phrase and silence isn't learned as "Hey Lotti".
    static func pad(_ samples: [Int16], tight: Bool, _ rng: inout Random) -> [Int16] {
        let lead = Int(Double.random(in: tight ? 0.03...0.15 : 0.1...0.4, using: &rng) * Double(Audio.rate))
        var trail = Int(Double.random(in: tight ? 0.03...0.15 : 0.1...0.35, using: &rng) * Double(Audio.rate))
        trail = max(trail, Int((tight ? 1.0 : 1.2) * Double(Audio.rate)) - lead - samples.count)
        return [Int16](repeating: 0, count: lead) + samples + [Int16](repeating: 0, count: max(trail, 0))
    }

    /// Random level, room noise and the G2's LC3 codec.
    static func augment(_ samples: [Int16], _ rng: inout Random) -> [Int16] {
        var signal = samples.map { Double($0) / 32768 }
        let peak = signal.map(abs).max() ?? 0
        if peak > 0 {
            let target = Double.random(in: 0.06...0.9, using: &rng)
            signal = signal.map { $0 * target / peak }
        }
        if Double.random(in: 0...1, using: &rng) < 0.75 {
            let power = (signal.map { $0 * $0 }.reduce(0, +) / Double(max(signal.count, 1))).squareRoot()
            let snr = Double.random(in: 6...32, using: &rng)
            let level = power / pow(10, snr / 20)
            let hiss = coloredNoise(count: signal.count, &rng)
            for index in signal.indices { signal[index] += hiss[index] * level }
        }
        let pcm = signal.map { Int16(max(min($0, 0.999), -0.999) * 32767) }
        return LC3Encoder.roundTrip(pcm)
    }

    /// Unit-RMS noise somewhere between white and brown.
    static func coloredNoise(count: Int, _ rng: inout Random) -> [Double] {
        let tilt = Double.random(in: 0...0.98, using: &rng)
        var low = 0.0
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            low = low * tilt + gaussian(&rng) * (1 - tilt)
            out[index] = gaussian(&rng) * (1 - tilt) + low
        }
        let rms = (out.map { $0 * $0 }.reduce(0, +) / Double(max(count, 1))).squareRoot()
        return rms > 0 ? out.map { $0 / rms } : out
    }

    static func gaussian(_ rng: inout Random) -> Double {
        let u1 = Double.random(in: 1e-9...1, using: &rng)
        let u2 = Double.random(in: 0...1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    // MARK: Background that isn't speech

    static func noise(babble: [[Int16]]) throws -> Int {
        let length = Int(1.5 * Double(Audio.rate))
        var count = 0
        func save(_ signal: [Double], _ name: String) throws {
            let pcm = signal.map { Int16(max(min($0, 0.999), -0.999) * 32767) }
            try Audio.write(LC3Encoder.roundTrip(pcm), to: Paths.synthetic.appending(path: "background/\(name).wav"))
            count += 1
        }
        for index in 0..<40 {
            var rng = Random(seed: "silence-\(index)")
            let level = Double.random(in: 0...0.0008, using: &rng)
            try save(coloredNoise(count: length, &rng).map { $0 * level }, "noise-silence-\(index)~0")
        }
        for index in 0..<80 {
            var rng = Random(seed: "noise-\(index)")
            let level = pow(10, Double.random(in: -3...(-1.1), using: &rng))
            try save(coloredNoise(count: length, &rng).map { $0 * level }, "noise-room-\(index)~0")
        }
        for index in 0..<20 {
            var rng = Random(seed: "hum-\(index)")
            let base = Double([50, 60, 100, 120].randomElement(using: &rng)!)
            let level = Double.random(in: 0.005...0.08, using: &rng)
            let hiss = coloredNoise(count: length, &rng)
            try save((0..<length).map { level * sin(2 * .pi * base * Double($0) / 16_000) + hiss[$0] * level * 0.1 }, "noise-hum-\(index)~0")
        }
        for index in 0..<30 {
            var rng = Random(seed: "click-\(index)")
            var signal = coloredNoise(count: length, &rng).map { $0 * 0.003 }
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let at = Int.random(in: 0..<(length - 2000), using: &rng)
                let level = Double.random(in: 0.05...0.7, using: &rng)
                let tone = Double.random(in: 300...3000, using: &rng)
                for offset in 0..<1600 {
                    signal[at + offset] += level * exp(-Double(offset) / 160) * sin(2 * .pi * tone * Double(offset) / 16_000)
                }
            }
            try save(signal, "noise-tap-\(index)~0")
        }
        // Several people talking: speech clips laid over each other.
        if babble.count > 6 {
            for index in 0..<60 {
                var rng = Random(seed: "babble-\(index)")
                var mix = [Double](repeating: 0, count: length)
                for _ in 0..<Int.random(in: 2...4, using: &rng) {
                    let source = babble.randomElement(using: &rng)!
                    let gain = Double.random(in: 0.05...0.5, using: &rng) / 32768
                    let offset = Int.random(in: 0..<max(source.count - length, 1), using: &rng)
                    for i in 0..<length where offset + i < source.count { mix[i] += Double(source[offset + i]) * gain }
                }
                try save(mix, "noise-babble-\(index)~0")
            }
        }
        return count
    }
}
