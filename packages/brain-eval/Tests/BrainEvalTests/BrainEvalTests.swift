import Testing
@testable import BrainEval

@Suite struct EvalSetTests {
    @Test func bundledSetDecodes() throws {
        let set = try EvalSet.bundled()
        #expect(set.cases.count >= 30)
        #expect(Set(set.cases.map(\.id)).count == set.cases.count, "case ids are unique")
        for task in EvalTask.allCases {
            #expect(set.cases.contains { $0.task == task }, "has \(task) cases")
        }
    }

    @Test func everyCaseHasInputAndExpectation() throws {
        for c in try EvalSet.bundled().cases {
            #expect(c.event != nil || c.utterance != nil, "\(c.id) has input")
            switch c.task {
            case .triage: #expect(c.expect.priority != nil, "\(c.id)")
            case .summary, .rail, .reply: #expect(c.language != nil, "\(c.id)")
            case .screen: #expect(c.expect.templates != nil, "\(c.id)")
            case .tool: #expect(c.expect.tool != nil || c.expect.noTool == true, "\(c.id)")
            }
            if c.task == .reply { #expect(c.intent != nil, "\(c.id)") }
        }
    }

    @Test func replyCasesHaveStyleExamples() throws {
        let set = try EvalSet.bundled()
        for c in set.cases where c.task == .reply {
            let examples = set.user.style[c.event?.from ?? ""] ?? []
            #expect(!examples.isEmpty, "\(c.id): \(set.user.style.keys.sorted())")
        }
    }
}

@Suite struct ScoringTests {
    func allPass(for evalCase: EvalCase, output: CaseOutput) -> Bool {
        Scoring.checks(for: evalCase, output: output).allSatisfy { $0.passed }
    }

    func evalCase(_ task: EvalTask, language: String? = nil, _ expect: CaseExpectation) -> EvalCase {
        EvalCase(id: "t", task: task, now: "Mon 10:00", language: language, event: nil, utterance: "x",
                 intent: nil, memory: nil, context: nil, expect: expect)
    }

    func expectation() -> CaseExpectation {
        CaseExpectation(priority: nil, alsoOK: nil, mentions: nil, mentionsAny: nil, avoid: nil,
                    maxWords: nil, templates: nil, tool: nil, noTool: nil)
    }

    @Test func triageAcceptsAlsoOK() {
        var e = expectation()
        e.priority = .normal
        e.alsoOK = [.urgent]
        let c = evalCase(.triage, e)
        #expect(allPass(for: c, output: CaseOutput(priority: .urgent)))
        #expect(!allPass(for: c, output: CaseOutput(priority: .quiet)))
    }

    @Test func mentionsUseAlternativesAndIgnoreCase() {
        var e = expectation()
        e.mentions = ["lisa", "trink|Getränk"]
        e.maxWords = 12
        let c = evalCase(.summary, language: "de", e)
        let good = CaseOutput(text: "Mara sagt, ihr feiert jetzt bei Lisa; bring Getränke mit.")
        #expect(allPass(for: c, output: good))
        let missing = CaseOutput(text: "Mara sagt, ihr feiert jetzt bei ihr zu Hause.")
        #expect(Scoring.checks(for: c, output: missing).first { $0.name == "mentions" }?.passed == false)
    }

    @Test func detectsLanguage() {
        #expect(Scoring.detectLanguage("Mara fragt, ob du um acht noch kommst.") == "de")
        #expect(Scoring.detectLanguage("Ben moved the review to Thursday morning.") == "en")
    }

    @Test func railShape() {
        var e = expectation()
        e.mentionsAny = ["unterwegs|komme", "spät"]
        let c = evalCase(.rail, language: "de", e)
        let good = CaseOutput(choices: ["Bin unterwegs", "Komme später", "Schaffs nicht"])
        #expect(allPass(for: c, output: good))
        let long = CaseOutput(choices: ["Ich bin schon auf dem Weg zu dir", "später"])
        #expect(Scoring.checks(for: c, output: long).first { $0.name == "railShape" }?.passed == false)
    }

    @Test func toolCallArguments() {
        var e = expectation()
        e.tool = .init(name: "start_navigation", args: ["destination": "Mauerpark", "mode": "bike"])
        let c = evalCase(.tool, e)
        let right = CaseOutput(toolCalls: [.init(name: "start_navigation", arguments: #"{"destination":"Mauerpark, Berlin","mode":"bike"}"#)])
        #expect(allPass(for: c, output: right))
        let wrongMode = CaseOutput(toolCalls: [.init(name: "start_navigation", arguments: #"{"destination":"Mauerpark","mode":"walk"}"#)])
        #expect(!allPass(for: c, output: wrongMode))
        let none = CaseOutput(toolCalls: [])
        #expect(!allPass(for: c, output: none))
    }

    @Test func noToolExpectation() {
        var e = expectation()
        e.noTool = true
        let c = evalCase(.tool, e)
        #expect(allPass(for: c, output: CaseOutput(text: "Bestens!", toolCalls: [])))
        #expect(!allPass(for: c, output: CaseOutput(toolCalls: [.init(name: "set_timer", arguments: "{}")])))
    }
}
