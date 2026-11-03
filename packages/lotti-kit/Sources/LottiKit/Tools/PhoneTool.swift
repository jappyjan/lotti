import Foundation

/// One argument of a phone tool.
public struct ToolParameter: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case string
        case integer
        case number
        case boolean
        /// One of these strings.
        case oneOf([String])
    }

    public var name: String
    public var description: String
    public var kind: Kind
    public var isOptional: Bool

    public init(_ name: String, _ kind: Kind, _ description: String, optional: Bool = false) {
        self.name = name
        self.kind = kind
        self.description = description
        self.isOptional = optional
    }
}

/// What a phone tool is, for the offline brain and for the backend (which calls `location` and `reminders` over the socket).
public struct PhoneToolSpec: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        /// Reads something (calendar, weather). Runs right away when a brain asks for it.
        case read
        /// Changes something (timer, reminder). Only ever runs after you tap it on the glasses.
        case action
    }

    public var name: String
    public var description: String
    public var parameters: [ToolParameter]
    public var effect: Effect
    /// Shown on the glasses while the tool runs, e.g. "Checking your calendar…".
    public var progress: String
    /// How long a run may take; nil means `Toolbox.callTimeout`. Slow actions (navigation
    /// planning needs a location fix plus MapKit) give themselves more room.
    public var timeout: Duration?

    public init(
        name: String, description: String, parameters: [ToolParameter] = [], effect: Effect,
        progress: String, timeout: Duration? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.effect = effect
        self.progress = progress
        self.timeout = timeout
    }

    /// Checks `arguments` against the parameters and returns them cleaned up: numbers given as
    /// strings become numbers, choices are matched case-insensitively, unknown keys are dropped.
    public func validate(_ arguments: [String: JSONValue]) throws -> ToolArguments {
        var clean: [String: JSONValue] = [:]
        for parameter in parameters {
            guard let value = arguments[parameter.name], value != .null else {
                if parameter.isOptional { continue }
                throw ToolError("\(name): missing \(parameter.name)")
            }
            clean[parameter.name] = try parameter.coerce(value, tool: name)
        }
        return ToolArguments(clean)
    }
}

extension ToolParameter {
    func coerce(_ value: JSONValue, tool: String) throws -> JSONValue {
        let wrong = ToolError("\(tool): \(name) should be \(kindDescription)")
        switch kind {
        case .string:
            switch value {
            case .string(let text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                return .string(text.trimmingCharacters(in: .whitespaces))
            case .number(let number): return .string(number == number.rounded() ? String(Int(number)) : String(number))
            default: throw wrong
            }
        case .integer:
            guard let number = value.number, number == number.rounded() else { throw wrong }
            return .number(number)
        case .number:
            guard let number = value.number else { throw wrong }
            return .number(number)
        case .boolean:
            if case .bool = value { return value }
            switch value.string?.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw wrong
            }
        case .oneOf(let choices):
            guard let text = value.string,
                  let match = choices.first(where: { $0.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespaces)) == .orderedSame })
            else { throw wrong }
            return .string(match)
        }
    }

    /// "integer", "one of today, tomorrow", …
    var kindDescription: String {
        switch kind {
        case .string: "a string"
        case .integer: "an integer"
        case .number: "a number"
        case .boolean: "true or false"
        case .oneOf(let choices): "one of " + choices.joined(separator: ", ")
        }
    }
}

/// Validated arguments for a tool run.
public struct ToolArguments: Equatable, Sendable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public func string(_ name: String) -> String? { values[name]?.string }
    public func int(_ name: String) -> Int? { values[name]?.number.map { Int($0) } }
    public func double(_ name: String) -> Double? { values[name]?.number }
    public func bool(_ name: String) -> Bool? {
        if case .bool(let value) = values[name] { return value }
        return nil
    }
}

public struct ToolError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Something Lotti can do or look up on the phone. The app implements the real ones (EventKit,
/// AlarmKit, …); the spec is what the brains see.
public protocol PhoneTool: Sendable {
    var spec: PhoneToolSpec { get }
    /// Runs the tool. Returns a short plain-text result: facts for a read, a confirmation
    /// sentence for an action ("Timer set for 10 minutes.").
    func run(_ arguments: ToolArguments) async throws -> String
    /// For actions: the rail title for this call, at most ~16 characters ("Timer 10 min").
    func title(for arguments: ToolArguments) -> String
}

extension PhoneTool {
    public func title(for arguments: ToolArguments) -> String { spec.name }
}

/// A brain asking for a tool.
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var tool: String
    public var arguments: [String: JSONValue]

    public init(id: String, tool: String, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
    }
}

public struct ToolResult: Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var content: String

    public init(id: String, ok: Bool, content: String) {
        self.id = id
        self.ok = ok
        self.content = content
    }
}

/// An action a brain suggested, validated and ready to run when you tap it.
public struct ProposedAction: Equatable, Sendable {
    /// Where the action runs.
    public enum Target: String, Equatable, Sendable {
        /// On the phone, through the `Toolbox` (`set_timer`, `create_reminder`, `start_navigation`).
        case phone
        /// On the backend: the tap sends `perform {actionId}` and the server runs it.
        case server
    }

    public var tool: String
    public var arguments: ToolArguments
    /// The rail title.
    public var title: String
    public var target: Target
    /// The backend's id for a `.server` action (from the answer's `actions`).
    public var actionId: String?

    public init(tool: String, arguments: ToolArguments, title: String, target: Target = .phone, actionId: String? = nil) {
        self.tool = tool
        self.arguments = arguments
        self.title = title
        self.target = target
        self.actionId = actionId
    }

    /// An action the backend runs when you tap it.
    public static func server(id: String, title: String, tool: String = "", arguments: ToolArguments = ToolArguments()) -> ProposedAction {
        ProposedAction(tool: tool, arguments: arguments, title: title, target: .server, actionId: id)
    }
}
