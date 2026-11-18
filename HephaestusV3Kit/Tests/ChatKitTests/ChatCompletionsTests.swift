import ChatData
import MCPKit
import ProjectData
import Testing
@testable import ChatKit

/// docs/ui/chat.md › Skill completion.
@Suite("Skill completion")
struct ChatCompletionsTests {
    private let commands = [
        ClaudeCommand(name: "swift-testing", description: "Writes Swift Testing tests"),
        ClaudeCommand(name: "release-notes", description: "Writes the release notes\nof a version"),
        ClaudeCommand(name: "hephaestus-skills:report-feedback"),
        ClaudeCommand(name: "compact", description: "Free up context", isBuiltIn: true),
    ]

    private func names(_ text: String) -> [String] {
        ChatCompletions.list(for: text, commands: commands).map(\.title)
    }

    @Test("A lone / offers every skill by name; the CLI's own commands never")
    func all() {
        #expect(names("/") == ["hephaestus-skills:report-feedback", "release-notes", "swift-testing"])
    }

    @Test("Names that start with the typed text, or whose part after : does, come first; then those holding it")
    func order() {
        #expect(names("/re") == ["hephaestus-skills:report-feedback", "release-notes"])
        #expect(names("/t") == ["hephaestus-skills:report-feedback", "release-notes", "swift-testing"])
        #expect(names("/s") == ["swift-testing", "hephaestus-skills:report-feedback", "release-notes"])
        #expect(names("/REL") == ["release-notes"], "Any letter case")
    }

    @Test("Skills synced from claude.ai for the desktop app aren't offered")
    func synced() {
        let list = [ClaudeCommand(name: "computer-use", description: "Controls the screen. (claude.ai sync)", isSynced: true),
                    ClaudeCommand(name: "cowork-plugin-management:create-cowork-plugin", isSynced: true),
                    ClaudeCommand(name: "hexago:create-service")]
        #expect(ChatCompletions.list(for: "/c", commands: list).map(\.title) == ["hexago:create-service"])
    }

    @Test("Nothing without a first word that starts with / and holds no space, or without a match")
    func none() {
        #expect(names("").isEmpty && names("re").isEmpty && names("hello /re").isEmpty)
        #expect(names("/re x").isEmpty && names("/re\n").isEmpty && names("/zzz").isEmpty)
        #expect(names("/compact").isEmpty)
    }

    @Test("Picking one makes the text its call and a space; the detail is the description")
    func completion() throws {
        let first = try #require(ChatCompletions.list(for: "/rel", commands: commands).first)
        #expect(first.text == "/release-notes " && first.detail == "Writes the release notes\nof a version")
        #expect(ChatCompletions.list(for: "/rep", commands: commands).first?.detail == nil)
        let many = (1...30).map { ClaudeCommand(name: "skill-\($0)") }
        #expect(ChatCompletions.list(for: "/", commands: many).count == ChatCompletions.limit)
    }
}

/// docs/ui/chat.md › Questions.
@Suite("Questions card")
@MainActor
struct ChatQuestionsCardTests {
    private let set = ChatQuestionSet(id: "Q", questions: [
        ChatQuestion(label: "A", question: "a", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
        ChatQuestion(label: "B", question: "b", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
        ChatQuestion(label: "C", question: "c", options: [.init(label: "x"), .init(label: "y")], recommended: ["x"]),
    ], answers: ["B": "x"])

    @Test("The card opens on the first question without an answer; Next goes to the next one, wrapping")
    func navigation() {
        #expect(set.firstUnanswered == 0)
        #expect(set.nextUnanswered(after: 0, answered: "A") == 2)
        #expect(set.nextUnanswered(after: 2, answered: "C") == 0)
        var nearlyDone = set
        nearlyDone.answers["A"] = "y"
        #expect(nearlyDone.nextUnanswered(after: 2, answered: "C") == nil)
    }

    @Test("Submit shows on the question whose answer completes the set; Next on the others")
    func submit() {
        #expect(!set.completes(at: 0))
        var nearlyDone = set
        nearlyDone.answers["A"] = "y"
        #expect(nearlyDone.completes(at: 2) && !nearlyDone.completes(at: 0))
    }

    @Test("ask_questions: only a chat's own Claude asks; the rules come before the chat")
    func tool() async throws {
        let session = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        let ask = ChatTools.askQuestions(session)
        #expect(ask.permission == .askUser)
        let valid: JSONValue = ["questions": [["label": "A", "question": "q", "options": [["label": "a"], ["label": "b"]], "recommended": ["a"]]]]
        await #expect(throws: ToolError(.forbidden, ChatTools.askRefusal)) { _ = try await ask.run(valid) }
        await #expect(throws: ToolError(.invalid, "questions: give 1 to 26 questions.")) {
            _ = try await MCPCaller.$current.withValue(.chat("C")) { try await ask.run(["questions": []]) }
        }
        await #expect(throws: ToolError(.notFound, "Chat C not found.")) {
            _ = try await MCPCaller.$current.withValue(.chat("C")) { try await ask.run(valid) }
        }
        #expect(ask.describe?(valid).action == "Asked a question")
        #expect(await ChatGate.check(.internalSkill("set-ticket-title"), ask, valid, chats: session) == ToolError(.forbidden, ChatGate.skillRefusal))
    }
}
