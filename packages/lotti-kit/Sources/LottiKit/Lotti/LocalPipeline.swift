import Foundation
import NaturalLanguage

/// The prompts and parsing for the offline (on-device) brain's steps, kept apart from Foundation
/// Models so they can be tested without a model. No fixed facts about Jan go into any prompt:
/// everything about him comes from the clock or from a tool in this turn.
///
/// The offline brain is narrow on purpose: the backend answers everything else whenever it can be
/// reached. Offline it does timers and navigation (most important), reminders and the local
/// calendar; anything else gets a short "I'm offline" sentence (`offlineSentence`).
///
/// Steps: choose tools from a list → fill in each chosen tool's arguments → run reads in
/// parallel (actions are only prepared) → shorten long results → write the answer from the facts.
/// Prepared actions and the offline notice get fixed sentences.
public enum LocalPipeline {
    public static let languages = ["German", "English"]

    /// What the chooser picked.
    public struct Choice: Equatable, Sendable {
        public var intent: String
        /// "German" or "English": the answer's language.
        public var language: String
        /// Tool names. At most three, no repeats.
        public var tools: [String]

        public init(intent: String = "", language: String = "English", tools: [String] = []) {
            self.intent = intent
            self.language = language
            self.tools = tools
        }
    }

    /// One fact gathered from a tool.
    public struct Fact: Equatable, Sendable {
        public var tool: String
        public var text: String

        public init(tool: String, text: String) {
            self.tool = tool
            self.text = text
        }

        /// What the fact is about, in words, so a small model doesn't mix them up
        /// (Jan's position is not where his meeting is).
        var label: String {
            switch tool {
            case "location": "where Jan is right now"
            case "calendar": "Jan's calendar"
            case "reminders": "Jan's reminder list"
            default: tool
            }
        }
    }

    /// One earlier exchange in the conversation.
    public struct Turn: Equatable, Sendable {
        public var jan: String
        public var lotti: String
        /// What the tools said in that turn, so follow-ups can use it.
        public var facts: [Fact]

        public init(jan: String, lotti: String, facts: [Fact] = []) {
            self.jan = jan
            self.lotti = lotti
            self.facts = facts
        }

        var text: String {
            (facts.map { "(\($0.label): \($0.text))" } + ["Jan: \(jan)", "Lotti: \(lotti)"]).joined(separator: "\n")
        }
    }

    // MARK: Rules

    /// Phrases that clearly ask for a tool, German and English. Checked before the model chooses:
    /// deterministic and instant. The model only chooses when no rule matches.
    static let rules: [(tool: String, pattern: String)] = [
        ("create_reminder", #"\b(erinner(e|n)? mich|remind me|vergiss nicht|don'?t let me forget)\b"#),
        ("reminders", #"\b(erinnerungen|reminders|to-?dos?|aufgaben(liste)?)\b"#),
        ("set_timer", #"\b(timer|countdown|stoppuhr)\b"#),
        ("start_navigation", #"\b(navigier\w*|navigat\w*|bring(e|t)? mich|bring(e|t)? uns|führ(e|t)? (mich|uns)|lotse (mich|uns)|fahre mich|fährst du mich|nimm mich mit|zeig mir den weg|walk me (to|home|back)|bike me (to|home)|ride me (to|home)|take me (to|home|back)|get me (to|home)|guide me (to|home)|lead me (to|home)|directions to|wo ist (der|die|das) nächste|where( is|'s|s)? the nearest|where( is|'s|s)? the closest|wie komme? ich|wie kommen wir|how do (i|we) get)\b"#),
        ("location", #"\b(wo bin ich|wo sind wir|where am i|where are we|mein(en)? standort|my location)\b"#),
        ("calendar", #"\b(termine?n?|kalender|calendar|meetings?|appointments?|schedule|agenda|steht .*\ban\b|what'?s on|was hab(e)? ich)\b"#),
        ("weather", #"\b(wetter|weather|regen|regnet|rain(ing)?|schirm|umbrella|temperatur(e)?|kalt|cold|warm|grad|sonnig|sunny|schnee|snow|wind(ig|y)?)\b"#),
    ]

    /// Tools only the rules pick, never the model.
    public static let rulesOnly: Set<String> = ["location"]

    /// What the offline brain can do. Everything else (weather, web, location, small talk) is for
    /// the backend and gets `offlineSentence` here.
    public static let offlineTools: Set<String> = ["set_timer", "start_navigation", "create_reminder", "reminders", "calendar"]

    /// What the offline brain does with a message.
    public enum OfflinePlan: Equatable, Sendable {
        /// Use these tools (all in `offlineTools`).
        case tools([String])
        /// A rule recognised something only the backend can do.
        case unsupported
    }

    /// The rules' verdict for the offline brain, or nil when no rule matches (then the model may
    /// choose among `offlineTools`, and an empty choice is unsupported too).
    public static func offlinePlan(_ message: String, names: Set<String>) -> OfflinePlan? {
        guard let picked = ruleTools(message, names: names) else { return nil }
        let offline = picked.filter { offlineTools.contains($0) }
        return offline.isEmpty ? .unsupported : .tools(offline)
    }

    /// Tools the rules pick for `message`, in rule order, or nil if no rule matches. A new
    /// reminder wins over reading the reminder list.
    public static func ruleTools(_ message: String, tools: [PhoneToolSpec]) -> [String]? {
        ruleTools(message, names: Set(tools.map(\.name)))
    }

    public static func ruleTools(_ message: String, names: Set<String>) -> [String]? {
        let text = message.lowercased()
        var picked = rules.filter { rule in
            names.contains(rule.tool) && (try? Regex(rule.pattern)).map { text.contains($0) } == true
        }.map(\.tool)
        if picked.contains("create_reminder") { picked.removeAll { $0 == "reminders" } }
        return picked.isEmpty ? nil : Array(picked.prefix(3))
    }

    // MARK: Choose

    /// What the chooser sees instead of tool names: a small model picks better when the option
    /// says what it does ("add_new_reminder", not "create_reminder" next to "reminders").
    static let labels: [String: String] = [
        "location": "where_jan_is",
        "start_navigation": "navigate_me_there",
        "calendar": "jan_calendar",
        "weather": "weather",
        "reminders": "read_existing_reminders",
        "set_timer": "start_timer",
        "create_reminder": "remind_me_later",
    ]

    static func label(_ name: String) -> String { labels[name] ?? name }

    /// The chooser's options: a label per offline tool.
    public static func options(tools: [PhoneToolSpec]) -> [String] { tools.filter { offlineTools.contains($0.name) }.map { label($0.name) } }

    /// Instructions for the chooser. One explicit rule per tool: a ~3B model follows rules, not hints.
    public static func chooseInstructions(tools: [PhoneToolSpec]) -> String {
        var rules = [
            "You pick which phone tools Lotti needs to answer Jan. You don't answer him yourself.",
            "Jan wears smart glasses and speaks to Lotti; his words come from speech-to-text, so guess what he meant.",
            "Pick as few as possible: usually one or none.",
            "Rules:",
        ]
        let ruleFor: [String: String] = [
            "location": "Where Jan himself is right now (his own position or address)",
            "start_navigation": "Jan wants turn-by-turn navigation on the glasses: walk me there, take me there, bring mich hin, navigiere mich",
            "calendar": "His calendar, appointments, meetings or plans for any day, and where they are",
            "weather": "Weather, temperature, rain, umbrella, what to wear",
            "reminders": "Jan asks what is on his reminder or to-do list",
            "set_timer": "Start a timer or countdown",
            "create_reminder": "Jan wants to be reminded of something later (remind me, erinner mich, don't let me forget)",
        ]
        rules += tools.filter { offlineTools.contains($0.name) }.compactMap { spec in ruleFor[spec.name].map { "- \($0) → \(label(spec.name))." } }
        rules.append("- Anything else (weather, news, the web, prices, small talk, questions about Lotti) → nothing (empty list).")
        return rules.joined(separator: "\n")
    }

    /// The prompt for the chooser and for filling in arguments.
    public static func questionPrompt(_ message: String, now: String?, history: [Turn]) -> String {
        var lines = now.map { [$0] } ?? []
        if !history.isEmpty {
            lines.append("Earlier in this conversation:")
            lines += history.map(\.text)
        }
        lines.append("Jan: \(message)")
        return lines.joined(separator: "\n")
    }

    /// The language of Jan's message, German or English. Done in code: the model guesses badly.
    public static func language(of message: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english]
        recognizer.processString(message)
        return recognizer.dominantLanguage == .german ? "German" : "English"
    }

    /// Reads the chooser's output: `{"intent":…,"tools":["jan_calendar"]}`.
    public static func parseChoice(_ json: JSONValue, tools: [PhoneToolSpec]) -> Choice {
        let names = Dictionary(uniqueKeysWithValues: tools.filter { offlineTools.contains($0.name) }.map { (label($0.name), $0.name) })
        var picked: [String] = []
        for option in json["tools"]?.array?.compactMap(\.string) ?? [] {
            guard let name = names[option] ?? names.values.first(where: { $0 == option }), !picked.contains(name) else { continue }
            picked.append(name)
        }
        return Choice(
            intent: json["intent"]?.string ?? "",
            language: json["language"]?.string.flatMap { languages.contains($0) ? $0 : nil } ?? "English",  // overridden by `language(of:)`
            tools: Array(picked.prefix(3)))
    }

    // MARK: Arguments

    public static func argumentsInstructions(_ spec: PhoneToolSpec) -> String {
        """
        Fill in the arguments for the phone tool \(spec.name): \(spec.description)
        Take them from Jan's words. Name days as today, tomorrow or a weekday (monday, …); never work out dates.
        Leave an optional argument out if Jan didn't say it.
        """
    }

    // MARK: Checks

    /// True if an answer only says it doesn't know. Offline that means the question is beyond the
    /// phone (the offline notice replaces it); the model's own "can answer" flag isn't reliable enough.
    public static func soundsUnsure(_ sentence: String) -> Bool {
        sentence.lowercased().contains(try! Regex(#"(weiß (ich )?(es |das )?nicht|keine ahnung|kann (ich )?(dir )?(das |es )?nicht (sagen|wissen|beantworten)|habe keine (infos|informationen)|don'?t know|do not know|not sure|can'?t (tell|say|know)|cannot (tell|say|know)|no idea|no information)"#))
    }

    // MARK: Fixed sentences

    /// For prepared actions: fixed, so the model can't claim they're done.
    public static func preparedSentence(_ prepared: [ProposedAction], language: String) -> String {
        let titles = prepared.map(\.title).joined(separator: ", ")
        return language == "German" ? "Bereit: \(titles). Tipp zum Starten." : "Ready: \(titles). Tap to start."
    }

    /// What the offline brain says to everything it can't do. Short, in the question's language.
    public static func offlineSentence(language: String) -> String {
        language == "German"
            ? "Ich bin gerade offline, dabei kann ich nicht helfen. Timer und Navigation gehen."
            : "I'm offline right now, so I can't help with that. Timers and navigation still work."
    }

    /// When a timer or a destination is missing from what Jan said.
    public static func missingSentence(_ what: String, language: String) -> String {
        switch (what, language == "German") {
        case ("timer", true): "Wie viele Minuten soll der Timer laufen?"
        case ("timer", false): "How many minutes should the timer run?"
        case ("navigation", true): "Wohin soll es gehen?"
        case ("navigation", false): "Where to?"
        case (_, true): "Woran soll ich dich erinnern?"
        default: "What should I remind you of?"
        }
    }

    // MARK: Shorten

    /// Results longer than this get shortened before the answer step.
    public static let compactAbove = 280

    public static func compactPrompt(_ message: String, fact: Fact) -> String {
        """
        Jan asked: \(message)
        Data from \(fact.tool):
        \(fact.text)

        Copy only the parts of the data needed to answer Jan, as short as possible. Keep times, names, \
        places and numbers exactly as they are. Don't answer Jan.
        """
    }

    // MARK: Answer

    public static func answerInstructions(language: String) -> String {
        let you = language == "German" ? "\"du\"" : "\"you\""
        return """
            You are Lotti, a small assistant on the smart glasses Jan wears. Brief, warm, a bit curious.
            Rules:
            - Answer in \(language), in one or two short sentences, at most 30 words. The display is tiny.
            - Times in 24-hour form (14:05, not 2:05).
            - Speak to Jan as \(you). In Jan's message, "ich" or "I" means Jan, not you.
            - Use only the facts given and the conversation. If a fact you need is missing, say you don't know. \
            Never invent appointments, places, times or numbers.
            - Translate facts into \(language) (e.g. "cloudy" → "bewölkt").
            - No lists, no markdown, no emoji.
            - Follow-ups: up to 3 short questions Jan might ask next, each 1 to 3 words, in \(language).
            """
    }

    /// For when the full instructions trip the model's language check.
    public static func shortAnswerInstructions(language: String) -> String {
        "You are Lotti. Answer Jan in \(language), one or two short sentences, using only the facts given."
    }

    public static func answerPrompt(_ message: String, now: String, history: [Turn], facts: [Fact]) -> String {
        var lines = [now]
        if !history.isEmpty {
            lines.append("Earlier in this conversation:")
            lines += history.map(\.text)
        }
        if !facts.isEmpty {
            lines.append("Facts:")
            lines += facts.map { "- \($0.label): \($0.text)" }
        }
        lines.append("Jan: \(message)")
        return lines.joined(separator: "\n")
    }
}
