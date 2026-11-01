import Foundation

/// Lotti's instructions and prompts per task. Kept short: Apple's on-device context is small,
/// and every token is latency.
public enum Prompts {
    public static let persona = """
        You are Lotti, a small assistant on Jan's smart glasses. Jan lives in Berlin. \
        The display is tiny: say things in one short sentence. Brief, warm, a bit curious.
        """

    public static func instructions(for task: EvalTask) -> String {
        switch task {
        case .triage:
            return persona + "\n" + """
                Decide how loud a notification should be.
                quiet: never shown by itself (ads, newsletters, news, chit-chat, muted chats).
                normal: shown for a few seconds (most personal messages, useful updates).
                urgent: stays until Jan acts. Rare: emergencies, someone close needs him now, money or security problems, things that can't wait.
                Jan's rules in Memory always apply.
                """
        case .summary:
            return persona + "\n" + """
                Tell Jan what a message says in ONE sentence of at most 20 words. \
                Start with the sender's name, then what they say. Keep times, places, names and what they ask for.
                """
        case .rail:
            return persona + "\n" + """
                Suggest up to 3 choices Jan could pick next, each 1 to 3 words. \
                For a message from a person: likely replies. For an app or a company: useful actions, not replies. \
                Best guess first.
                """
        case .reply:
            return """
                Write the message Jan sends, in Jan's own style for this person (see his earlier messages). \
                You are writing as Jan, not as an assistant. Output only the message text.
                """
        case .screen, .tool:
            return persona + "\n" + """
                Answer with one glasses screen. Pick the template by these rules:
                - Jan asks to send or tell someone something: proposal. The text is "I'll tell <name>: <exact message>".
                - Jan asks for the exact words of a message: original. The text is the message word for word.
                - Several events or items to choose from: list, one item per line.
                - A few facts at a glance (weather, a time, a distance): card, "label: value" lines.
                - Something was just done: done, one short line.
                - Anything else: lottiSays, one or two short sentences.
                Choices are what Jan can do next, at most 4, each 1 to 3 words. Proposals use Send, Change, Cancel.
                """ + (task == .tool ? """

                    You control Jan's phone with tools. For a timer, navigation, his calendar or a reminder, \
                    call the matching tool first, then answer with a short screen saying what you did. Jan's home is Kastanienallee 12.
                    """ : "")
        }
    }

    public static func prompt(for evalCase: EvalCase, user: EvalSet.User) -> String {
        var lines = ["Now: \(evalCase.now)"]
        if let event = evalCase.event {
            lines.append("Notification from \(event.app), \(event.from): \(event.text)")
        }
        if let memory = evalCase.memory, !memory.isEmpty {
            lines.append("Memory: " + memory.joined(separator: " "))
        }
        if let context = evalCase.context, !context.isEmpty {
            lines.append("Context:\n" + context.map { "- \($0)" }.joined(separator: "\n"))
        }
        if evalCase.task == .reply, let person = evalCase.event?.from {
            let examples = user.style[person] ?? []
            if !examples.isEmpty {
                lines.append("Jan's earlier messages to \(person):\n" + examples.map { "- \($0)" }.joined(separator: "\n"))
            }
            if let intent = evalCase.intent { lines.append("Jan wants to say: \(intent)") }
        }
        if let utterance = evalCase.utterance { lines.append("Jan says: \(utterance)") }
        if let language = evalCase.language {
            lines.append("Answer in \(language == "de" ? "German" : "English").")
        }
        return lines.joined(separator: "\n")
    }
}
