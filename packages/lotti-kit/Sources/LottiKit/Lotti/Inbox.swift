import Foundation
import Observation

/// What an inbox item is about. Unknown kinds from the backend count as `.info`.
public enum InboxKind: String, CaseIterable, Sendable {
    case mail, calendar, job, reminder, info

    public init(backend raw: String) { self = InboxKind(rawValue: raw.lowercased()) ?? .info }
}

public enum InboxStatus: String, Sendable {
    case pending, seen, dismissed, expired

    public init(backend raw: String?) { self = raw.flatMap { InboxStatus(rawValue: $0.lowercased()) } ?? .pending }
}

/// One item in the backend's inbox (protocol.md "Inbox item"). The backend is the source of truth;
/// the app only shows, opens and dismisses.
public struct InboxItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: InboxKind
    public var title: String
    public var summary: String
    /// The original, word for word.
    public var body: String
    public var sourceRef: String?
    public var createdAt: Date?
    public var expiresAt: Date?
    public var status: InboxStatus
    /// When the thing happens, if the backend says (a meeting's start). Not in protocol.md yet:
    /// read from `startsAt` / `dueAt`, or `expiresAt` for a calendar item.
    public var due: Date?
    /// Things you can do with the item, shown next to Dismiss. Not in protocol.md yet: an
    /// optional `actions` array shaped like an answer's.
    public var actions: [ProposedAction]

    public init(id: String, kind: InboxKind, title: String, summary: String = "", body: String = "", sourceRef: String? = nil,
                createdAt: Date? = nil, expiresAt: Date? = nil, status: InboxStatus = .pending, due: Date? = nil,
                actions: [ProposedAction] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.body = body
        self.sourceRef = sourceRef
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.due = due
        self.actions = Array(actions.prefix(2))
    }

    /// True while the item should show: not dismissed, not expired by status or by date.
    public func isActive(at now: Date) -> Bool {
        guard status == .pending || status == .seen else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }
}

/// The inbox as the app knows it, synced from `BackendClient` (`inbox` and `push` messages).
/// Observable, so the phone's views update; the `Conductor` redraws the glasses' indicator on
/// every change.
@MainActor
@Observable
public final class InboxStore {
    public private(set) var items: [InboxItem] = []

    public init(items: [InboxItem] = []) { self.items = items }

    /// Applies an `inbox` message: the whole list if `full`, else upserts and removals.
    public func apply(full: Bool, items incoming: [InboxItem], removedIds: [String]) {
        if full { items = [] }
        for item in incoming { upsert(item) }
        items.removeAll { removedIds.contains($0.id) }
    }

    public func upsert(_ item: InboxItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
    }

    public func setStatus(_ id: String, _ status: InboxStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    public func item(_ id: String) -> InboxItem? { items.first { $0.id == id } }

    /// Items to list: pending and seen, newest first.
    public func active(at now: Date) -> [InboxItem] {
        items.filter { $0.isActive(at: now) }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// Items nobody has looked at yet: what the glasses' indicator counts.
    public func pending(at now: Date) -> [InboxItem] {
        active(at: now).filter { $0.status == .pending }
    }

    /// Pending items per kind, in the indicator's order (`InboxKind.allCases`), kinds without items left out.
    public func pendingCounts(at now: Date) -> [IndicatorCount] {
        let pending = pending(at: now)
        return InboxKind.allCases.compactMap { kind in
            let count = pending.filter { $0.kind == kind }.count
            return count > 0 ? IndicatorCount(kind: kind, count: count) : nil
        }
    }
}

/// The short pending summary on the today view: "2 Mails, Termin in 10 min".
public struct InboxSummary: Sendable {
    public var german: Bool

    public init(german: Bool) { self.german = german }

    /// Defaults to German when the phone's first language is.
    public static var system: InboxSummary {
        InboxSummary(german: Locale.preferredLanguages.first?.hasPrefix("de") == true)
    }

    public func line(_ items: [InboxItem], now: Date) -> String {
        var parts: [String] = []
        for kind in [InboxKind.mail, .job, .reminder, .info] {
            let count = items.filter { $0.kind == kind }.count
            if count > 0 { parts.append("\(count) \(noun(kind, count))") }
        }
        let events = items.filter { $0.kind == .calendar }
        if !events.isEmpty {
            let soonest = events.compactMap(\.due).filter { $0 > now.addingTimeInterval(-300) }.min()
            if events.count == 1 {
                parts.append(german ? "Termin" + (soonest.map { " \(when($0, now: now))" } ?? "") : "Appointment" + (soonest.map { " \(when($0, now: now))" } ?? ""))
            } else {
                parts.append("\(events.count) \(noun(.calendar, events.count))" + (soonest.map { ", \(german ? "nächster" : "next") \(when($0, now: now))" } ?? ""))
            }
        }
        return parts.joined(separator: ", ")
    }

    /// "in 10 min" / "um 14:30" (German), "in 10 min" / "at 14:30".
    func when(_ date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes <= 0 { return german ? "jetzt" : "now" }
        if minutes < 60 { return german ? "in \(minutes) min" : "in \(minutes) min" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return (german ? "um " : "at ") + formatter.string(from: date)
    }

    func noun(_ kind: InboxKind, _ count: Int) -> String {
        let one = count == 1
        switch kind {
        case .mail: return german ? (one ? "Mail" : "Mails") : (one ? "mail" : "mails")
        case .calendar: return german ? (one ? "Termin" : "Termine") : (one ? "appointment" : "appointments")
        case .job: return german ? (one ? "Job" : "Jobs") : (one ? "job" : "jobs")
        case .reminder: return german ? (one ? "Erinnerung" : "Erinnerungen") : (one ? "reminder" : "reminders")
        case .info: return german ? (one ? "Info" : "Infos") : (one ? "info" : "infos")
        }
    }

    /// "Mail" / "Termin" …: the dim label above an original.
    public func label(_ kind: InboxKind) -> String {
        noun(kind, 1).prefix(1).uppercased() + noun(kind, 1).dropFirst()
    }
}
