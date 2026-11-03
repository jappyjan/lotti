import Foundation
import LottiKit
import Observation

/// Every time Lotti Brain read this phone's location, kept on the phone (the backend keeps its
/// own log too: Privacy shows both). Newest first, capped.
@MainActor
@Observable
final class LocationReadLog {
    struct Entry: Identifiable, Equatable, Codable {
        var callId: String
        var start: Date
        var end: Date?
        var id: String { callId }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let limit: Int
    static let key = "locationReadLog"

    init(defaults: UserDefaults = .standard, limit: Int = 200) {
        self.defaults = defaults
        self.limit = limit
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func record(_ access: LocationAccess) {
        switch access.phase {
        case .start:
            entries.insert(Entry(callId: access.callId, start: access.at), at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        case .end:
            if let index = entries.firstIndex(where: { $0.callId == access.callId }) { entries[index].end = access.at }
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: Self.key)
    }
}
