import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Questions: the rules of `ask_questions`, the item V2 wrote, the answers, and a chat that asks.
@Suite("Questions")
struct QuestionsTests {
    private static func input(_ questions: [JSONValue]) -> JSONValue { ["questions": .array(questions)] }

    private static let lockQuestion: JSONValue = [
        "label": "A", "question": "What should ⌘W do on a locked tab?",
        "options": [["label": "Select the next tab"], ["label": "Do nothing and beep", "description": "As the lock promises."]],
        "recommended": ["Do nothing and beep"],
    ]

    @Test("A valid set: the recommended options come first, the others keep their order")
    func valid() throws {
        let tabs: JSONValue = ["label": "B", "question": "Which tabs?", "kind": "multiple",
                               "options": [["label": "Web"], ["label": "Editor"], ["label": "Docs"]], "recommended": ["Docs", "Web"], "maxChoices": 3]
        let questions = try QuestionsItem.questions(from: Self.input([Self.lockQuestion, tabs]))
        #expect(questions[0].options.map(\.label) == ["Do nothing and beep", "Select the next tab"])
        #expect(questions[0].options[0].description == "As the lock promises." && questions[0].kind == .single)
        #expect(questions[1].options.map(\.label) == ["Web", "Docs", "Editor"] && questions[1].recommended == ["Web", "Docs"])
        #expect(questions[1].maxChoices == 3 && questions[1].minChoices == nil)
    }

    @Test("Each rule refuses the whole set with its reason", arguments: [
        ([], "questions: give 1 to 26 questions."),
        ([["label": "B", "question": "x", "options": [["label": "a"], ["label": "b"]], "recommended": ["a"]]], "questions: question 1 has the label \"A\"."),
        ([["label": "A", "question": " ", "options": [["label": "a"], ["label": "b"]], "recommended": ["a"]]], "questions: question A has no text."),
        ([["label": "A", "question": "x", "options": [["label": "a"]], "recommended": ["a"]]], "questions: question A has 2 to 10 options."),
        ([["label": "A", "question": "x", "options": [["label": "a"], ["label": "A"]], "recommended": ["a"]]], "questions: question A has an empty option label, or two the same."),
        ([["label": "A", "question": "x", "options": [["label": "a\nb"], ["label": "c"]], "recommended": ["c"]]], "questions: question A has an option label of several lines or over 200 characters."),
        ([["label": "A", "question": "x", "options": [["label": "a"], ["label": "b"]], "recommended": ["a", "b"]]], "questions: question A recommends exactly one of its option labels."),
        ([["label": "A", "question": "x", "options": [["label": "a"], ["label": "b"]], "recommended": ["a"], "maxChoices": 2]], "questions: question A has minChoices or maxChoices without the kind multiple."),
        ([["label": "A", "question": "x", "kind": "multiple", "options": [["label": "a"], ["label": "b"]], "recommended": ["c"]]], "questions: question A recommends one or more of its option labels, each once."),
        ([["label": "A", "question": "x", "kind": "multiple", "options": [["label": "a"], ["label": "b"]], "recommended": ["a"], "minChoices": 2, "maxChoices": 1]], "questions: question A has a minChoices over its maxChoices."),
        ([["label": "A", "question": "x", "kind": "multiple", "options": [["label": "a"], ["label": "b"]], "recommended": ["a", "b"], "maxChoices": 1]], "questions: question A recommends more options than its maxChoices."),
    ] as [([JSONValue], String)])
    func rules(questions: [JSONValue], message: String) {
        #expect(throws: ToolError(.invalid, message)) { try QuestionsItem.questions(from: Self.input(questions)) }
    }

    @Test("V2's item reads back, a single question's recommendation a string, a multiple one's a list")
    func v2Item() throws {
        let line = #"{"op":"add","item":{"type":"questions","id":"4D3C","created":"2026-10-31T13:00:32Z","questionSetID":"4D3C","questions":[{"label":"A","question":"Lock?","options":[{"label":"Yes","description":null},{"label":"No"}],"recommended":"Yes"},{"label":"B","question":"Which?","kind":"multiple","options":[{"label":"Web"},{"label":"Docs"}],"recommended":["Web"],"maxChoices":2}],"answers":{"A":"Yes"},"completed":false}}"#
        let items = Transcript.replay(Data(line.utf8))
        guard case .questions(let item)? = items.first else { Issue.record("No questions"); return }
        #expect(item.questions.map(\.recommended) == [["Yes"], ["Web"]] && item.questions[1].kind == .multiple && item.questions[1].maxChoices == 2)
        #expect(item.answers == ["A": "Yes"] && !item.completed)
        let written = String(decoding: Transcript.line(.update, .questions(item)), as: UTF8.self)
        #expect(written.contains(#""recommended":"Yes""#) && written.contains(#""recommended":["Web"]"#))
        #expect(Transcript.replay(Data(written.utf8)) == items)
    }

    @Test("The answers message: label order, a multiple question's choices on their own lines, Skipped")
    func answersMessage() {
        let item = QuestionsItem(id: "Q", created: Date(), questionSetID: "Q", questions: [
            ChatQuestion(label: "A", question: "a", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
            ChatQuestion(label: "B", question: "b", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
            ChatQuestion(label: "C", question: "c", kind: .multiple, options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
            ChatQuestion(label: "D", question: "d", kind: .multiple, options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
        ], answers: ["C": "- x\n- mine", "A": "Do nothing", "B": "Skipped", "D": "Skipped"])
        #expect(item.answersMessage() == "Answers:\nA: Do nothing\nB: Skipped\nC:\n- x\n- mine\nD: Skipped")
    }

    @Test("An answer is trimmed and checked; a multiple question's is one line per choice within its bounds")
    func checkedAnswers() throws {
        let item = QuestionsItem(id: "Q", created: Date(), questionSetID: "Q", questions: [
            ChatQuestion(label: "A", question: "a", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
            ChatQuestion(label: "B", question: "b", kind: .multiple, options: [.init(label: "x"), .init(label: "y")], recommended: ["x"], maxChoices: 2),
        ])
        #expect(try item.checkedAnswer("  my own  ", for: "A") == "my own")
        #expect(try item.checkedAnswer("- x\n- y", for: "B") == "- x\n- y")
        #expect(try item.checkedAnswer("Skipped", for: "B") == "Skipped")
        #expect(throws: ChatError.invalid("answer: write 1 to 10,000 characters.")) { try item.checkedAnswer(" ", for: "A") }
        #expect(throws: ChatError.invalid("answer: write one line \"- <choice>\" per choice, or Skipped.")) { try item.checkedAnswer("x", for: "B") }
        #expect(throws: ChatError.invalid("answer: the number of choices is outside the question's bounds.")) { try item.checkedAnswer("- x\n- y\n- z", for: "B") }
        #expect(throws: ChatError.invalid("label: the set has no question C.")) { try item.checkedAnswer("x", for: "C") }
    }
}

@Suite("Questions in a chat")
@MainActor
struct ChatQuestionsTests {
    @Test("Questions wait once the turn ends; the last answer sends Claude the answers")
    func flow() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Plan the tabs", references: [], to: nil, projectID: "ORD")
        let questions = try QuestionsItem.questions(from: ["questions": [
            ["label": "A", "question": "Lock?", "options": [["label": "Yes"], ["label": "No"]], "recommended": ["Yes"]],
            ["label": "B", "question": "Which?", "kind": "multiple", "options": [["label": "Web"], ["label": "Docs"]], "recommended": ["Web"]],
        ]])
        let item = try await world.session.postQuestions(id, questions: questions)
        #expect(world.session.waitingQuestions(in: id) == item)
        await #expect(throws: ChatError.conflict("Questions already wait for the user's answers in this chat.")) {
            _ = try await world.session.postQuestions(id, questions: questions)
        }
        let first = try #require(world.launcher.chats.first)
        first.finish(.exited(0))
        try await world.until { world.session.state(of: id) == .waitingAnswers }

        try await world.session.answerQuestion(id, setID: item.questionSetID, label: "B", answer: "- Web\n- Terminal")
        #expect(world.session.waitingQuestions(in: id)?.answers == ["B": "- Web\n- Terminal"])
        #expect(world.launcher.chats.count == 1, "Nothing goes to Claude before the last answer")
        try await world.session.answerQuestion(id, setID: item.questionSetID, label: "A", answer: "No")
        #expect(world.session.waitingQuestions(in: id) == nil)
        guard case .questions(let done)? = world.items(id).first(where: { $0.id == item.id }) else { Issue.record("No questions"); return }
        #expect(done.completed && done.answers == ["A": "No", "B": "- Web\n- Terminal"])
        guard case .user(let message)? = world.items(id).last else { Issue.record("No answers message"); return }
        #expect(message.text == "Answers:\nA: No\nB:\n- Web\n- Terminal")
        let second = try #require(world.launcher.chats.last)
        #expect(second !== first, "The answers start the chat's CLI again")
        await #expect(throws: ChatError.conflict("These questions are already answered.")) {
            try await world.session.answerQuestion(id, setID: item.questionSetID, label: "A", answer: "Yes")
        }
        second.finish(.exited(0))
    }
}
