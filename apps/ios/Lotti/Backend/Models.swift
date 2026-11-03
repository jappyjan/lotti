import Foundation
import LottiKit

// Typed views of what the management API returns (apps/brain/README.md). Each reads leniently:
// a missing field becomes a default, so a newer or older backend still shows something.

extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    func text(_ key: String) -> String? { self[key]?.string }
    func flag(_ key: String) -> Bool { self[key]?.boolValue ?? false }
    func date(_ key: String) -> Date? { self[key]?.string.flatMap(BackendDates.parse) }
    /// The list at `key`, or the value itself when it is a list; `result` objects wrap lists sometimes.
    var items: [JSONValue] { array ?? self["items"]?.array ?? [] }
}

/// "Today 14:30", "Mon 9:00" … for the lists. Empty for nil.
func shortDate(_ date: Date?) -> String {
    guard let date else { return "–" }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

struct ProviderInfo: Identifiable, Equatable {
    var id: String
    var label: String
    /// `chat` (API key) or a subscription runtime (`codex`, `claude_code`).
    var kind: String
    var configured: Bool
    var active: Bool
    var fallback: Bool
    var model: String
    var lastError: String?

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        label = json.text("label") ?? id
        kind = json.text("kind") ?? "chat"
        configured = json.flag("configured")
        active = json.flag("active")
        fallback = json.flag("fallback")
        model = json.text("model") ?? ""
        lastError = json.text("lastError")
    }

    var isRuntime: Bool { kind != "chat" }
}

struct JobInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var isBuiltin: Bool
    var prompt: String
    var cron: String
    var scheduleText: String?
    var enabled: Bool
    var nextRunAt: Date?
    var lastRunAt: Date?

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        name = json.text("name") ?? id
        isBuiltin = json.text("kind") == "builtin"
        prompt = json.text("prompt") ?? ""
        cron = json.text("cron") ?? ""
        scheduleText = json.text("scheduleText")
        enabled = json["enabled"]?.boolValue ?? true
        nextRunAt = json.date("nextRunAt")
        lastRunAt = json.date("lastRunAt")
    }

    /// What to show for the schedule: the friendly text if there is one.
    var scheduleLabel: String { scheduleText ?? cron }
}

struct JobRunInfo: Identifiable, Equatable {
    var id: String
    var startedAt: Date?
    var status: String
    var output: String

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        startedAt = json.date("startedAt")
        status = json.text("status") ?? ""
        output = json.text("output") ?? ""
    }
}

struct MemoryInfo: Identifiable, Equatable {
    var id: String
    var text: String
    var kind: String
    var sourceConversation: String?
    var createdAt: Date?
    var lastUsedAt: Date?
    var superseded: Bool

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        text = json.text("text") ?? ""
        kind = json.text("kind") ?? ""
        sourceConversation = json.text("sourceConversation")
        createdAt = json.date("createdAt")
        lastUsedAt = json.date("lastUsedAt")
        superseded = json.text("status") == "superseded"
    }
}

/// A skill or a script (`skills.list`, `scripts.list`).
struct FileEntry: Identifiable, Equatable {
    var name: String
    var description: String
    var size: Int
    var lastUsedAt: Date?
    var useCount: Int
    var id: String { name }

    init?(_ json: JSONValue) {
        guard let name = json.text("name") else { return nil }
        self.name = name
        description = json.text("description") ?? ""
        size = Int(json["size"]?.number ?? 0)
        lastUsedAt = json.date("lastUsedAt")
        useCount = Int(json["useCount"]?.number ?? 0)
    }
}

struct McpServer: Identifiable, Equatable {
    var id: String
    var name: String
    var transport: String
    var url: String
    var command: String
    var args: [String]
    var enabled: Bool
    /// Tool name → needs your tap. Tools not listed need it (the backend's default).
    var confirmation: [String: Bool]
    var status: String?
    var lastError: String?

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        name = json.text("name") ?? id
        transport = json.text("transport") ?? "http"
        url = json.text("url") ?? ""
        command = json.text("command") ?? ""
        args = (json["args"]?.array ?? []).compactMap(\.string)
        enabled = json["enabled"]?.boolValue ?? true
        var flags: [String: Bool] = [:]
        for (tool, value) in json["toolFlags"]?.object ?? [:] { flags[tool] = value["needsConfirmation"]?.boolValue ?? true }
        confirmation = flags
        status = json.text("status")
        lastError = json.text("lastError")
    }

    func needsConfirmation(_ tool: String) -> Bool { confirmation[tool] ?? true }
}

struct AccountInfo: Identifiable, Equatable {
    var id: String
    var kind: String
    var label: String
    var config: [String: JSONValue]
    var status: String
    var lastError: String?
    var lastSync: Date?

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        kind = json.text("kind") ?? ""
        label = json.text("label") ?? id
        config = json["config"]?.object ?? [:]
        status = json.text("status") ?? ""
        lastError = json.text("lastError")
        // `lastSyncAt` is epoch milliseconds (or an ISO date in newer versions).
        lastSync = json.date("lastSyncAt") ?? json.date("lastSync")
            ?? json["lastSyncAt"]?.number.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
    }

    /// `config.calendar` / `config.mail`: whether the account serves that service; nil = the kind's default.
    func service(_ key: String) -> Bool? { config[key]?.boolValue }
    var isEnabled: Bool { config["enabled"]?.boolValue ?? true }

    var isConnected: Bool { ["ok", "connected"].contains(status) }

    func list(_ key: String) -> [String] { (config[key]?.array ?? []).compactMap(\.string) }
}

/// A calendar or mailbox of an account (`accounts.calendars`, `accounts.mailboxes`).
struct Selectable: Identifiable, Equatable {
    var id: String
    var name: String
    var selected: Bool

    init?(_ json: JSONValue) {
        guard let id = json.text("id") ?? json.text("name") else { return nil }
        self.id = id
        name = json.text("name") ?? json.text("title") ?? id
        selected = json["selected"]?.boolValue ?? false
    }
}

struct ConversationInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var summary: String
    var isOpen: Bool
    var lastActiveAt: Date?

    init?(_ json: JSONValue) {
        guard let id = json.text("id") else { return nil }
        self.id = id
        title = json.text("title") ?? ""
        summary = json.text("summary") ?? ""
        isOpen = json.text("status") == "open"
        lastActiveAt = json.date("lastActiveAt")
    }
}

struct TurnInfo: Identifiable, Equatable {
    var id: Int
    var role: ChatMessage.Role
    var text: String
    var channel: BackendChannel
    var at: Date?

    init?(_ json: JSONValue) {
        guard let role = json.text("role").flatMap(ChatMessage.Role.init(rawValue:)), let text = json.text("text") else { return nil }
        id = Int(json["id"]?.number ?? 0)
        self.role = role
        self.text = text
        channel = json.text("channel").flatMap(BackendChannel.init(rawValue:)) ?? .phone
        at = json.date("at")
    }
}

struct CatchupSettings: Equatable {
    var enabled = true
    var awayHours = 2.0
    var nightStart = "22:00"
    var nightEnd = "09:00"
    var sleepMinHours = 4.0
    var useWeather = true

    init() {}

    init(_ json: JSONValue) {
        enabled = json["enabled"]?.boolValue ?? true
        awayHours = json["away_hours"]?.number ?? 2
        nightStart = json.text("night_start") ?? "22:00"
        nightEnd = json.text("night_end") ?? "09:00"
        sleepMinHours = json["sleep_min_hours"]?.number ?? 4
        useWeather = json["use_weather"]?.boolValue ?? true
    }

    var json: JSONValue {
        ["enabled": .bool(enabled), "away_hours": .number(awayHours), "night_start": .string(nightStart),
         "night_end": .string(nightEnd), "sleep_min_hours": .number(sleepMinHours), "use_weather": .bool(useWeather)]
    }
}

struct LocationLogEntry: Identifiable, Equatable {
    var callId: String
    var at: Date?
    var source: String
    var ok: Bool
    var id: String { callId + (at?.description ?? "") }

    init?(_ json: JSONValue) {
        guard let callId = json.text("callId") else { return nil }
        self.callId = callId
        at = json.date("at")
        source = json.text("source") ?? ""
        ok = json["ok"]?.boolValue ?? true
    }
}

struct ShellLogEntry: Identifiable, Equatable {
    var id = UUID()
    var at: Date?
    var command: String
    var exitCode: Int?
    var durationMs: Int
    var timedOut: Bool
    var output: String

    init?(_ json: JSONValue) {
        guard let command = json.text("command") else { return nil }
        at = json.date("at")
        self.command = command
        exitCode = json["exitCode"]?.number.map { Int($0) }
        durationMs = Int(json["durationMs"]?.number ?? 0)
        timedOut = json.flag("timedOut")
        output = json.text("output") ?? ""
    }
}
