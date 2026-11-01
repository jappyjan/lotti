#if canImport(FoundationModels)
import FoundationModels

/// Fake phone tools with canned answers. Names and arguments are what M5's real tools will use.
@available(iOS 27.0, macOS 27.0, *)
public enum PhoneTools {
    public static var all: [any Tool] { [SetTimer(), StartNavigation(), NextMeeting(), CreateReminder()] }

    struct SetTimer: Tool {
        let name = "set_timer"
        let description = "Start a countdown timer on the phone."
        @Generable struct Arguments {
            @Guide(description: "Length in minutes") var minutes: Int
            @Guide(description: "What the timer is for") var label: String
        }
        func call(arguments: Arguments) async throws -> String {
            "Timer '\(arguments.label)' set for \(arguments.minutes) minutes."
        }
    }

    struct StartNavigation: Tool {
        let name = "start_navigation"
        let description = "Start turn-by-turn navigation on the glasses."
        @Generable enum Mode: String { case walk, bike, drive }
        @Generable struct Arguments {
            @Guide(description: "Place name or address; \"home\" for Jan's home") var destination: String
            var mode: Mode
        }
        func call(arguments: Arguments) async throws -> String {
            "Navigation to \(arguments.destination) started (\(arguments.mode.rawValue)), 18 minutes."
        }
    }

    struct NextMeeting: Tool {
        let name = "next_meeting"
        let description = "Look up Jan's next calendar event."
        @Generable struct Arguments {}
        func call(arguments: Arguments) async throws -> String {
            "Next event: Standup with Ben, today 15:30, Room 2."
        }
    }

    struct CreateReminder: Tool {
        let name = "create_reminder"
        let description = "Create a reminder."
        @Generable struct Arguments {
            var text: String
            @Guide(description: "When, e.g. \"tomorrow 09:00\"") var when: String
        }
        func call(arguments: Arguments) async throws -> String {
            "Reminder '\(arguments.text)' set for \(arguments.when)."
        }
    }
}
#endif
