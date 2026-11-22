import AppKit
import ChatData
import FileStorage
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

/// docs/ui/chat.md › Attachments.
@Suite("Composer files")
@MainActor
struct ChatFilesTests {
    @Test("Files are added once each; a folder, or files over 20 MB, are refused with the reason")
    func adding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatFilesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("build.log")
        try Data("x".utf8).write(to: log)
        let first = ChatFiles.adding([log, log], to: [])
        #expect(first.files == [log] && first.failure == nil)
        let refused = ChatFiles.adding([folder], to: first.files)
        #expect(refused.files == [log] && refused.failure == "Folders cannot be attached.")
    }

    @Test("Only files that are there can be added: a web link or a missing file is refused, with why")
    func addingOnlyFiles() {
        let web = ChatFiles.adding([URL(string: "https://example.com/a.png")!], to: [])
        #expect(web.files.isEmpty && web.failure == "Only files can be attached, not https://example.com/a.png.")
        let missing = ChatFiles.adding([URL(fileURLWithPath: "/nowhere/gone-\(UUID().uuidString).txt")], to: [])
        #expect(missing.files.isEmpty && missing.failure?.hasSuffix("can't be read.") == true)
    }

    @Test("A paste of files gives them; of an image, a PNG named for its time; of text, nothing")
    func pasting() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("HephaestusV3Tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ChatFilesTests-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        #expect(ChatFiles.pasted(from: board) == [file])

        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        board.writeObjects([image])
        let date = ISODate.date(from: "2026-11-17T21:05:09Z")!
        let pasted = try #require(ChatFiles.pasted(from: board, now: date)?.first)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        #expect(pasted.lastPathComponent == "Pasted Image \(formatter.string(from: date)).png")
        #expect(NSImage(contentsOf: pasted) != nil)
        ChatFiles.clean([pasted])
        #expect(!FileManager.default.fileExists(atPath: pasted.deletingLastPathComponent().path))

        board.clearContents()
        board.setString("plain text", forType: .string)
        #expect(ChatFiles.pasted(from: board) == nil)

        // Text beside a picture of it, as Numbers or Word copy cells: the text pastes.
        board.clearContents()
        board.writeObjects(["cells as text" as NSString, image])
        #expect(ChatFiles.pasted(from: board) == nil)
    }
}

/// docs/ui/chat.md › Context indicator.
@Suite("Context indicator")
struct ContextIndicatorTests {
    @Test("Tokens read 850, 17.7K, 120K, 1M, 1.5M; the tooltip adds the compactions")
    func numbers() {
        #expect([850, 17_700, 120_000, 1_000_000, 1_500_000, 948_446].map(ContextIndicator.tokens) == ["850", "17.7K", "120K", "1M", "1.5M", "948.4K"])
        let usage = ContextUsage(usedTokens: 18_554, windowTokens: 1_000_000, bufferTokens: 33_000, received: Date())
        #expect(ContextIndicator.tooltip(usage, compactions: 0) == "18.6K of 1M tokens used · 948.4K left before compaction")
        #expect(ContextIndicator.tooltip(usage, compactions: 2).hasSuffix("\nCompacted 2 times"))
        #expect(ContextIndicator.tooltip(usage, compactions: 1).hasSuffix("\nCompacted once"))
    }
}
