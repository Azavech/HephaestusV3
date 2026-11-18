import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
@testable import ChatData

/// Starts nothing: every run fails.
private struct NoProcesses: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        ProcessResult(termination: .exited(1))
    }
}

/// The feedback chat (docs/ui/chat.md › Feedback): its first message, its stored files, the plugin that gives it
/// `report-feedback`, and its ticket. In temporary folders, with a fake CLI.
@MainActor
@Suite("Feedback chats")
struct FeedbackChatTests {
    /// A 1 × 1 pixel PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
    private let context = ["App: Hephaestus V3 1.0.30 (51)", "macOS 27.2", "Window: Tickets", "Project: Orders (ORD)", "Item: ORD-142"]

    @Test("The first message calls the skill, then gives the comment, the context, the screenshot's path and each file's")
    func message() {
        #expect(FeedbackReport.message(comment: "  The ladybug hides\nunder the divider\n", context: ["App: Hephaestus V3 1.0.30 (51)", "Window: Tickets"],
                                       screenshot: "/p/shot.png", attachments: ["/p/a.log", "/p/b.txt"]) == """
            /hephaestus-skills:report-feedback
            The ladybug hides
            under the divider

            Feedback context:
            - App: Hephaestus V3 1.0.30 (51)
            - Window: Tickets
            - Screenshot: /p/shot.png
            - Attachment: /p/a.log
            - Attachment: /p/b.txt
            """)
        #expect(!FeedbackReport.message(comment: "x", context: [], screenshot: nil, attachments: []).contains("Screenshot:"))
    }

    @Test("Send makes a feedback chat named after the comment, stores the files in its folder, and writes the images before the text that calls the skill")
    func create() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let inbox = world.root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let shot = inbox.appendingPathComponent("capture.png")
        try png.write(to: shot)
        let log = inbox.appendingPathComponent("app.log")
        try Data("log".utf8).write(to: log)

        let id = try await world.session.createFeedback(FeedbackReport(
            projectID: "ORD", comment: "The ladybug hides\nunder the divider", context: context, screenshot: shot, files: [log],
            settings: ChatSettings(model: "opus", effort: .medium)))
        let chat = try #require(world.session.chats[id]?.file)
        #expect(chat.kind == .feedback && chat.ticketID == nil && chat.title == "The ladybug hides")
        #expect(chat.settings.model == "opus" && chat.settings.effort == .medium)
        #expect(world.session.isUnlinkedFeedback(id))

        let folder = world.repo.appendingPathComponent(".hephaestus/chats/\(id)")
        let stored = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(stored.count == 2)
        let storedShot = try #require(stored.first { $0.hasSuffix("-screenshot.png") })
        let storedLog = try #require(stored.first { $0.hasSuffix("-app.log") })

        // The message keeps its files, the screenshot first, so that the chat shows them.
        await world.session.open(id)
        guard case .user(let message)? = world.session.transcripts[id]?.first else { Issue.record("No message"); return }
        #expect(message.attachments.map(\.name) == ["screenshot.png", "app.log"])
        #expect(message.attachments.map(\.path) == ["chats/\(id)/\(storedShot)", "chats/\(id)/\(storedLog)"])
        #expect(message.attachments[0].contentType == "image/png")
        #expect(message.attachments[0].size == png.count && message.attachments[1].size == 3)
        #expect(message.attachments[0].id == String(storedShot.prefix(36)))
        #expect(message.attachments[0].url(inProject: world.repo.path)?.lastPathComponent == storedShot)

        let process = try #require(world.launcher.chats.last)
        let arguments = process.request.arguments
        let plugins = try #require(arguments.firstIndex(of: "--plugin-dir").map { arguments[$0 + 1] })
        #expect(plugins.hasSuffix("/Data/Runtime/plugins"))
        #expect(FileManager.default.fileExists(atPath: plugins + "/hephaestus-skills/skills/report-feedback/SKILL.md"))

        try await world.until { process.written.contains { $0["type"]?.stringValue == "user" } }
        let user = try #require(process.written.first { $0["type"]?.stringValue == "user" })
        let blocks = try #require(user["message"]?["content"]?.arrayValue)
        #expect(blocks.map { $0["type"]?.stringValue } == ["image", "text"], "The image comes first, so that the call stays a call")
        #expect(blocks[0]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(blocks[1]["text"]?.stringValue == FeedbackReport.message(
            comment: "The ladybug hides\nunder the divider", context: context, screenshot: folder.appendingPathComponent(storedShot).path,
            attachments: [folder.appendingPathComponent(storedLog).path]))

        world.session.linkFeedback(id, toTicket: "ORD-1")
        #expect(world.session.chats[id]?.file.ticketID == "ORD-1")
        #expect(!world.session.isUnlinkedFeedback(id))
    }

    @Test("Nothing is made for a blank comment, files over 20 MB together, or without the Claude CLI")
    func refusals() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let big = world.root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FeedbackReport.sizeLimit / 2 + 1))
        try handle.close()
        let other = world.root.appendingPathComponent("other.bin")
        try FileManager.default.copyItem(at: big, to: other)
        func report(_ comment: String, files: [URL] = []) -> FeedbackReport {
            FeedbackReport(projectID: "ORD", comment: comment, context: [], screenshot: nil, files: files, settings: ChatSettings())
        }
        await #expect(throws: ChatError.invalid("comment: write what happened.")) { try await world.session.createFeedback(report(" \n")) }
        await #expect(throws: ChatError.invalid("The attachments of one request exceed 20 MB.")) {
            try await world.session.createFeedback(report("Feedback", files: [big, other]))
        }
        let unchecked = ChatSession(projects: world.projects, tokens: MCPTokens(), launcher: FakeLauncher(), runner: NoProcesses(), device: "Studio",
                                    processEnvironment: [:])
        await #expect(throws: ChatError.self) { try await unchecked.createFeedback(report("Feedback")) }
        #expect(world.session.chats.values.allSatisfy { $0.file.kind != .feedback })
        let chats = world.repo.appendingPathComponent(".hephaestus/chats")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: chats.path)) ?? []
        #expect(!folders.contains { !$0.contains(".") }, "No chat folder is left")
    }

    @Test("The chats' plugin holds the skills chats call, as saved, without the app's model and effort")
    func plugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackChatTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = DataFolder(url: root)
        try data.createIfNeeded()
        var values = InternalSkill.reportFeedback.defaults
        values.content = "Make a ticket of it."
        values.model = "opus"
        values.otherLines = ["description: Feedback"]
        try data.writeSkill(values, of: .reportFeedback)
        let stale = data.pluginsFolder.appendingPathComponent("hephaestus-skills/skills/old-skill")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        #expect(try data.writeChatPlugin() == data.pluginsFolder)
        let plugin = data.pluginsFolder.appendingPathComponent("hephaestus-skills")
        #expect(try String(contentsOf: plugin.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8)
            == #"{"name":"hephaestus-skills","version":"1.0.0"}"# + "\n")
        #expect(try String(contentsOf: plugin.appendingPathComponent("skills/report-feedback/SKILL.md"), encoding: .utf8)
            == "---\nname: report-feedback\ndescription: Feedback\n---\nMake a ticket of it.")
        #expect(try FileManager.default.contentsOfDirectory(atPath: plugin.appendingPathComponent("skills").path).sorted() == ["report-feedback", "resume-chat"],
                "set-ticket-title, which the app runs itself, and folders of other names aren't in it")
        #expect(InternalSkill.reportFeedback.command == "/hephaestus-skills:report-feedback")
        #expect(ChatLaunch(cliPath: "/c", chatID: "C", resume: false, model: "default", effort: .high, mcpConfig: URL(fileURLWithPath: "/m.json"),
                           tools: [], workingDirectory: "/", environment: [:], pluginDir: data.pluginsFolder).arguments.suffix(2)
            == ["--plugin-dir", data.pluginsFolder.path])
    }
}
