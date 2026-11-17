import ChatData
import Foundation
import Testing
import ToolsFoundation
@testable import ChatKit

/// The Send Feedback sheet's model (docs/ui/chat.md › Feedback): what Send sends, when it can, and the files.
@MainActor
@Suite("Send Feedback")
struct FeedbackModelTests {
    private let context = ["App: Hephaestus V3 1.0.30 (51)", "macOS 27.2", "Window: Tickets", "Project: Orders (ORD)", "Item: ORD-142"]
    private let screenshot = URL(fileURLWithPath: "/tmp/feedback/screenshot.png")

    /// A model whose Send records the report and answers `answer`.
    private func model(screenshot: URL? = URL(fileURLWithPath: "/tmp/feedback/screenshot.png"), cli: FeedbackCLI = .available,
                       answer: Result<String, ChatError> = .success("CHAT-1"), sent: @escaping @MainActor (FeedbackReport) -> Void = { _ in }) -> FeedbackModel {
        FeedbackModel(project: Project.sample("ORD")!, screenshot: screenshot, context: context, settings: ChatSettings(model: "sonnet", effort: .medium),
                      cli: { cli }, send: { report throws(ChatError) in
                          sent(report)
                          return try answer.get()
                      })
    }

    @Test("Send sends the comment, the context, the screenshot, the files and the menus' model and effort to the feedback project")
    func send() async {
        var reports: [FeedbackReport] = []
        let model = model { reports.append($0) }
        model.comment = "The ladybug hides"
        model.settings = ChatSettings(model: "opus", effort: .high)
        #expect(model.contextLine == "App: Hephaestus V3 1.0.30 (51) · macOS 27.2 · Window: Tickets · Project: Orders (ORD) · Item: ORD-142")
        #expect(await model.send() == "CHAT-1")
        #expect(reports == [FeedbackReport(projectID: "ORD", comment: "The ladybug hides", context: context, screenshot: screenshot, files: [],
                                           settings: ChatSettings(model: "opus", effort: .high))])
        #expect(model.failure == nil)
    }

    @Test("A screenshot left out isn't sent")
    func withoutScreenshot() async {
        var reports: [FeedbackReport] = []
        let model = model { reports.append($0) }
        model.comment = "Feedback"
        model.includesScreenshot = false
        _ = await model.send()
        #expect(reports.first?.screenshot == nil)
    }

    @Test("Send waits for a comment and for the Claude CLI, and says why it waits for the CLI")
    func conditions() async {
        var sent = 0
        let blank = model { _ in sent += 1 }
        blank.comment = " \n "
        #expect(!blank.canSend)
        #expect(await blank.send() == nil)
        let checking = model(cli: .checking) { _ in sent += 1 }
        checking.comment = "Feedback"
        #expect(!checking.canSend && checking.cliMessage == "Checking the Claude CLI…")
        let missing = model(cli: .unavailable("Claude CLI not found.")) { _ in sent += 1 }
        missing.comment = "Feedback"
        #expect(!missing.canSend && missing.cliMessage == "Claude CLI is not available: Claude CLI not found.")
        #expect(sent == 0)
    }

    @Test("A Send that fails keeps the sheet, with the reason, and can be tried again")
    func failure() async {
        let model = model(answer: .failure(.invalid("The attachments of one request exceed 20 MB.")))
        model.comment = "Feedback"
        #expect(await model.send() == nil)
        #expect(model.failure == ChatError.invalid("The attachments of one request exceed 20 MB.").description)
        #expect(model.canSend)
    }

    @Test("Files are added once each, in order; a folder or a file over 20 MB adds nothing from that drop")
    func files() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("app.log")
        try Data("log".utf8).write(to: small)
        let other = folder.appendingPathComponent("trace.json")
        try Data("{}".utf8).write(to: other)
        let large = folder.appendingPathComponent("dump.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FeedbackReport.sizeLimit + 1))
        try handle.close()

        let model = model()
        model.add([small, other, small])
        #expect(model.files == [small, other])
        model.add([large, small])
        #expect(model.failure == "dump.bin is larger than 20 MB.")
        #expect(model.files == [small, other])
        model.add([folder])
        #expect(model.failure == "Folders cannot be attached.")
        model.remove(small)
        #expect(model.files == [other])
    }
}
