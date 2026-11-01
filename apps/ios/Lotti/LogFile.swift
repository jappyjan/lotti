import Foundation

/// Copies everything Lotti prints into `Documents/lotti.log`, with the time, and still passes it
/// on to the console. So a run can be checked afterwards without a cable or debugger:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///       --domain-identifier de.janjaap.lotti --source Documents/lotti.log --destination lotti.log
enum LogFile {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "lotti.log")
    /// Start over above this size.
    static let limit = 4_000_000

    static func start() {
        // Not under unit tests: the test runner owns stdout.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // A closed console mustn't kill the app; writes then just fail.
        signal(SIGPIPE, SIG_IGN)
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: url.path())[.size] as? Int) ?? 0
        if size > limit || !manager.fileExists(atPath: url.path()) {
            manager.createFile(atPath: url.path(), contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        _ = try? file.seekToEnd()

        // stdout → pipe → (console, file). Line-buffered so lines arrive whole.
        setvbuf(stdout, nil, _IOLBF, 0)
        let console = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        let pipe = Pipe()
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss.SSS"
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? console.write(contentsOf: data)
            let time = stamp.string(from: Date())
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            try? file.write(contentsOf: Data(lines.map { "\(time) \($0)\n" }.joined().utf8))
        }
        print("[App] ---- launch \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "") ----")
    }
}
