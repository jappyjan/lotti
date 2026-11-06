import Foundation
import Observation

/// Every step of the Wisp update screen, with times and SHA-256s, in
/// `Application Support/wisp/wisp-update.log` (kept across launches, exportable from the
/// screen), so the hardware log in docs/wisp/safety.md can be filled in from it.
@MainActor
@Observable
final class WispLog {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var time: Date
        var text: String
    }

    private(set) var entries: [Entry] = []
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "wisp/wisp-update.log")
        if let text = try? String(contentsOf: self.url, encoding: .utf8) {
            entries = text.split(separator: "\n").suffix(500).map { Entry(time: .distantPast, text: String($0)) }
        }
    }

    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func add(_ text: String, at time: Date = .now) {
        let line = "\(Self.stamp.string(from: time)) \(text)"
        entries.append(Entry(time: time, text: line))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        print("[Wisp] \(text)")
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path()) { manager.createFile(atPath: url.path(), contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}
