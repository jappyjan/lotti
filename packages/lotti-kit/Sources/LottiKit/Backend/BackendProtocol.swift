import Foundation

// Messages of the Lotti Brain protocol (docs/protocol.md). Both sides are built against that file:
// change it first, then this code.

/// Where a question comes from.
public enum BackendChannel: String, Sendable {
    case glasses, phone
}

/// What the app tells the backend about itself and the glasses (`presence`).
public enum PresenceEvent: String, Sendable {
    case glassesWorn = "glasses_worn"
    case glassesRemoved = "glasses_removed"
    case glassesConnected = "glasses_connected"
    case glassesDisconnected = "glasses_disconnected"
    case gesture
    case headUp = "head_up"
    case phoneUnlock = "phone_unlock"
    case appOpen = "app_open"
    case phoneCharging = "phone_charging"
    case phoneUnplugged = "phone_unplugged"
    case phoneStill = "phone_still"
    case phoneMoving = "phone_moving"
}

/// `inbox_event`: what happened to an item on this device.
public enum InboxEvent: String, Sendable {
    case shown, opened, dismissed
}

public struct BackendWelcome: Equatable, Sendable {
    public var serverVersion: String
    public var conversationId: String
    /// The small settings the backend sends along (`catchup`, `activeProvider`).
    public var settings: [String: JSONValue]
}

public struct BackendAnswer: Equatable, Sendable {
    public var id: String
    public var conversationId: String?
    public var text: String
    public var followUps: [String]
    /// Phone actions are validated against the `Toolbox` (an unknown tool or bad arguments drops
    /// the action); server actions come as they are.
    public var actions: [ProposedAction]
    public var undo: UndoAction?

    public var answer: Answer { Answer(sentence: text, followUps: followUps, actions: actions, undo: undo) }
}

/// The reply to `perform` or `undo`.
public struct BackendPerformed: Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var text: String
    public var undo: UndoAction?
}

/// `location_access`: the backend reads the phone's location for a tool call. The app shows the
/// location icon on the glasses between `start` and `end` and keeps the log.
public struct LocationAccess: Equatable, Sendable {
    public enum Phase: String, Sendable { case start, end }
    public var phase: Phase
    public var callId: String
    public var at: Date
}

/// `catchup`: one brief of what happened meanwhile.
public struct Catchup: Equatable, Sendable {
    public var id: String
    public var text: String
    public var at: Date
}

/// `message`: a turn made on the other surface (a glasses question shows up in the phone chat).
public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public var conversationId: String
    public var role: Role
    public var text: String
    public var channel: BackendChannel
    public var at: Date
}

/// `tool_call`: the backend wants a phone tool (`location`, `reminders`).
public struct BackendToolCall: Equatable, Sendable {
    public var callId: String
    public var askId: String?
    public var name: String
    public var args: [String: JSONValue]
}

/// Everything the server sends, decoded.
public enum BackendMessage: Equatable, Sendable {
    case welcome(BackendWelcome)
    case status(id: String, text: String)
    case answer(BackendAnswer)
    case error(id: String?, message: String)
    case toolCall(BackendToolCall)
    case locationAccess(LocationAccess)
    case performed(BackendPerformed)
    case inbox(full: Bool, items: [InboxItem], removedIds: [String])
    case push(InboxItem)
    case catchup(Catchup)
    case conversation(id: String, event: String)
    case message(ChatMessage)
    /// A type this version doesn't know: ignored, kept for the log.
    case unknown(String)

    /// Decodes one JSON text frame; nil if it isn't a JSON object with a `type`.
    public static func decode(_ text: String) -> BackendMessage? {
        guard let json = try? JSONValue(json: text), let type = json["type"]?.string else { return nil }
        func string(_ key: String) -> String? { json[key]?.string }
        func date(_ key: String) -> Date { string(key).flatMap(BackendDates.parse) ?? Date() }
        switch type {
        case "welcome":
            return .welcome(BackendWelcome(serverVersion: string("serverVersion") ?? "", conversationId: string("conversationId") ?? "",
                                           settings: json["settings"]?.object ?? [:]))
        case "status":
            guard let id = string("id"), let text = string("text") else { return nil }
            return .status(id: id, text: text)
        case "answer":
            guard let id = string("id"), let text = string("text") else { return nil }
            return .answer(BackendAnswer(
                id: id, conversationId: string("conversationId"), text: text,
                followUps: (json["followUps"]?.array ?? []).compactMap(\.string),
                actions: (json["actions"]?.array ?? []).compactMap(BackendActions.decode),
                undo: json["undo"].flatMap(BackendActions.decodeUndo)))
        case "error":
            return .error(id: string("id"), message: string("message") ?? "Unknown error")
        case "tool_call":
            guard let callId = string("callId"), let name = string("name") else { return nil }
            return .toolCall(BackendToolCall(callId: callId, askId: string("askId"), name: name, args: json["args"]?.object ?? [:]))
        case "location_access":
            guard let phase = string("phase").flatMap(LocationAccess.Phase.init(rawValue:)), let callId = string("callId") else { return nil }
            return .locationAccess(LocationAccess(phase: phase, callId: callId, at: date("at")))
        case "performed":
            guard let id = string("id") else { return nil }
            return .performed(BackendPerformed(id: id, ok: json["ok"] == .bool(true), text: string("text") ?? "",
                                               undo: json["undo"].flatMap(BackendActions.decodeUndo)))
        case "inbox":
            return .inbox(full: json["full"] == .bool(true), items: (json["items"]?.array ?? []).compactMap(BackendActions.decodeItem),
                          removedIds: (json["removedIds"]?.array ?? []).compactMap(\.string))
        case "push":
            guard let item = json["item"].flatMap(BackendActions.decodeItem) else { return nil }
            return .push(item)
        case "catchup":
            guard let text = string("text") else { return nil }
            return .catchup(Catchup(id: string("id") ?? UUID().uuidString, text: text, at: date("at")))
        case "conversation":
            return .conversation(id: string("conversationId") ?? "", event: string("event") ?? "")
        case "message":
            guard let role = string("role").flatMap(ChatMessage.Role.init(rawValue:)), let text = string("text") else { return nil }
            return .message(ChatMessage(conversationId: string("conversationId") ?? "", role: role, text: text,
                                        channel: string("channel").flatMap(BackendChannel.init(rawValue:)) ?? .phone, at: date("at")))
        default:
            return .unknown(type)
        }
    }
}

/// What the app sends. Each builds the JSON text of one frame.
public enum BackendRequest: Sendable {
    case hello(appVersion: String, deviceName: String, apnsToken: String?)
    case ask(id: String, text: String, channel: BackendChannel, now: Date, locale: String)
    case cancel(id: String)
    case toolResult(callId: String, ok: Bool, text: String)
    case perform(id: String, actionId: String)
    case undo(id: String, undoId: String)
    case inboxEvent(itemId: String, event: InboxEvent)
    case inboxSync
    case presence(PresenceEvent, at: Date, detail: String?)

    public var json: String {
        var o: [String: JSONValue]
        switch self {
        case .hello(let version, let name, let apns):
            o = ["type": "hello", "appVersion": .string(version), "deviceName": .string(name)]
            if let apns { o["apnsToken"] = .string(apns) }
        case .ask(let id, let text, let channel, let now, let locale):
            o = ["type": "ask", "id": .string(id), "text": .string(text), "channel": .string(channel.rawValue),
                 "now": .string(BackendDates.format(now)), "locale": .string(locale)]
        case .cancel(let id):
            o = ["type": "cancel", "id": .string(id)]
        case .toolResult(let callId, let ok, let text):
            o = ["type": "tool_result", "callId": .string(callId), "ok": .bool(ok), "text": .string(text)]
        case .perform(let id, let actionId):
            o = ["type": "perform", "id": .string(id), "actionId": .string(actionId)]
        case .undo(let id, let undoId):
            o = ["type": "undo", "id": .string(id), "undoId": .string(undoId)]
        case .inboxEvent(let itemId, let event):
            o = ["type": "inbox_event", "itemId": .string(itemId), "event": .string(event.rawValue)]
        case .inboxSync:
            o = ["type": "inbox_sync"]
        case .presence(let event, let at, let detail):
            o = ["type": "presence", "event": .string(event.rawValue), "at": .string(BackendDates.format(at))]
            if let detail { o["detail"] = .string(detail) }
        }
        return JSONValue.object(o).json
    }
}

/// Decoding of actions, undo and inbox items (shared by answers and inbox messages).
enum BackendActions {
    static func decode(_ json: JSONValue) -> ProposedAction? {
        guard let id = json["id"]?.string, let title = json["title"]?.string else { return nil }
        let args = ToolArguments(json["args"]?.object ?? [:])
        if json["target"]?.string == "server" {
            return .server(id: id, title: title, tool: json["tool"]?.string ?? "", arguments: args)
        }
        guard let tool = json["tool"]?.string else { return nil }
        return ProposedAction(tool: tool, arguments: args, title: title, target: .phone, actionId: id)
    }

    static func decodeUndo(_ json: JSONValue) -> UndoAction? {
        guard let id = json["id"]?.string else { return nil }
        return UndoAction(id: id, label: json["label"]?.string ?? "Undo")
    }

    static func decodeItem(_ json: JSONValue) -> InboxItem? {
        guard let id = json["id"]?.string else { return nil }
        let kind = InboxKind(backend: json["kind"]?.string ?? "info")
        let expires = json["expiresAt"]?.string.flatMap(BackendDates.parse)
        let due = (json["startsAt"]?.string ?? json["dueAt"]?.string).flatMap(BackendDates.parse) ?? (kind == .calendar ? expires : nil)
        return InboxItem(
            id: id, kind: kind, title: json["title"]?.string ?? "", summary: json["summary"]?.string ?? "",
            body: json["body"]?.string ?? "", sourceRef: json["sourceRef"]?.string,
            createdAt: json["createdAt"]?.string.flatMap(BackendDates.parse), expiresAt: expires,
            status: InboxStatus(backend: json["status"]?.string), due: due,
            actions: (json["actions"]?.array ?? []).compactMap(decode))
    }
}

/// ISO 8601 with offset (`2026-11-03T08:15:00+01:00`), with or without fractional seconds.
public enum BackendDates {
    public static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// `2026-11-03T08:15:00+01:00` in the phone's time zone.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}

public enum BackendError: Error, LocalizedError, Equatable {
    /// No socket: the router should use the offline brain.
    case unreachable
    /// The backend answered `error` to this request.
    case server(String)
    case timeout
    /// HTTP: the status code and the backend's message.
    case http(Int, String)
    case notConfigured
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable: "I can't reach Lotti Brain right now."
        case .server(let message): message
        case .timeout: "Lotti Brain is taking too long."
        case .http(401, _), .http(403, _): "Lotti Brain didn't accept this phone. Pair it again."
        case .http(let code, let message): "Lotti Brain error \(code)" + (message.isEmpty ? "" : ": \(message)")
        case .notConfigured: "Lotti Brain isn't set up yet. Pair it in the Lotti app."
        case .badResponse: "Lotti Brain sent something I can't read."
        }
    }
}
