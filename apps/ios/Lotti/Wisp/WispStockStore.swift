import CryptoKit
import Foundation
import LottiKit

/// Stock bundles from Even's CDN, checked like `wisp-ota fetch` (pinned size + SHA-256, header
/// version, main-app end, every integrity guard) and cached in the app's container
/// (`Application Support/wisp-cache/stock/g2-<version>.bin`, excluded from backups). Even's
/// firmware is never committed or shared from here (safety.md rule 9).
@MainActor
final class WispStockStore {
    struct Stock: Equatable {
        var release: WispOtaEngine.StockRelease
        var bytes: [UInt8]
        var sha256: String
        var file: URL
        var fromCache: Bool
        var check: WispOtaEngine.StockCheck
    }

    enum StoreError: LocalizedError {
        case unknownVersion(String)
        case notPinned(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unknownVersion(let v): "\(v) is not a pinned stock release; nothing to fetch."
            case .notPinned(let v): "\(v): the release record is not the pinned catalog entry; refusing it."
            case .http(let code): "Download failed: HTTP \(code)."
            }
        }
    }

    let directory: URL
    private let engine: WispOtaEngine
    private let fetch: (URL) async throws -> Data
    private let releases: [WispOtaEngine.StockRelease]
    /// The app requires the catalog's own pins; tests with synthetic bundles turn this off.
    private let requirePinned: Bool

    init(engine: WispOtaEngine, directory: URL? = nil, releases: [WispOtaEngine.StockRelease]? = nil,
         requirePinned: Bool = true, fetch: ((URL) async throws -> Data)? = nil) throws {
        self.engine = engine
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "wisp-cache/stock")
        self.releases = try releases ?? engine.catalog()
        self.requirePinned = requirePinned
        self.fetch = fetch ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw StoreError.http(http.statusCode) }
            return data
        }
    }

    func release(for version: String) -> WispOtaEngine.StockRelease? {
        releases.first { $0.version == version }
    }

    var versions: [String] { releases.map(\.version) }

    /// The cached bundle if it still matches its pin, else a fresh download. Nothing is cached
    /// unless every check passes.
    func stock(version: String) async throws -> Stock {
        guard let release = release(for: version) else { throw StoreError.unknownVersion(version) }
        let file = directory.appending(path: "g2-\(version).bin")
        if let data = try? Data(contentsOf: file) {
            let bytes = [UInt8](data)
            let digest = Self.sha256(bytes)
            if digest == release.sha256, let check = try? accept(release, bytes, digest) {
                return Stock(release: release, bytes: bytes, sha256: digest, file: file, fromCache: true, check: check)
            }
            try? FileManager.default.removeItem(at: file)
        }
        guard let url = release.url.flatMap(URL.init(string:)) else { throw StoreError.unknownVersion(version) }
        let bytes = [UInt8](try await fetch(url))
        let digest = Self.sha256(bytes)
        let check = try accept(release, bytes, digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(bytes).write(to: file, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = file
        try? excluded.setResourceValues(values)
        return Stock(release: release, bytes: bytes, sha256: digest, file: file, fromCache: false, check: check)
    }

    private func accept(_ release: WispOtaEngine.StockRelease, _ bytes: [UInt8], _ digest: String) throws
        -> WispOtaEngine.StockCheck {
        let check = try engine.checkStock(release, bytes: bytes, sha256: digest)
        if requirePinned, !check.pinnedOfficial { throw StoreError.notPinned(release.version) }
        return check
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
