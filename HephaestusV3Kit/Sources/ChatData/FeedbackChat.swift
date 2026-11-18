import FileStorage
import Foundation
import ProjectData

/// Feedback about the app, as the Send Feedback sheet sends it (docs/ui/chat.md › Feedback): a feedback chat in
/// the feedback project, whose first message calls the internal skill `report-feedback`, as V2's feedback chat
/// called its `feedback` skill.
public struct FeedbackReport: Sendable, Hashable {
    public var projectID: String
    /// What the user typed; never blank.
    public var comment: String
    /// The lines that say where the feedback comes from, in order: `App: Hephaestus V3 1.0.30 (51)`,
    /// `macOS 27.2`, `Window: Tickets`, `Project: Orders (ORD)`, `Item: ORD-142`.
    public var context: [String]
    /// The window's PNG, unless the user left it out or the window couldn't be captured.
    public var screenshot: URL?
    /// The files the user added, in the order they were added.
    public var files: [URL]
    /// The chat's model and effort, from the sheet's menus.
    public var settings: ChatSettings

    public init(projectID: String, comment: String, context: [String], screenshot: URL?, files: [URL], settings: ChatSettings) {
        self.projectID = projectID
        self.comment = comment
        self.context = context
        self.screenshot = screenshot
        self.files = files
        self.settings = settings
    }

    /// The largest file, and the most of the screenshot and the files together: 20 MB, as a ticket takes.
    public static let sizeLimit = 20 * 1024 * 1024

    /// The chat's first message (docs/data.md › Feedback message): the skill's call on its own line, the
    /// comment, then `Feedback context:` with one `- ` line per context line, the stored screenshot's path and
    /// each stored file's path. It doesn't end with a line break.
    public static func message(comment: String, context: [String], screenshot: String?, attachments: [String]) -> String {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [InternalSkill.reportFeedback.command, comment.isEmpty ? "(no comment)" : comment, "", "Feedback context:"]
        lines += context.map { "- \($0)" }
        if let screenshot {
            lines.append("- Screenshot: \(screenshot)")
        }
        lines += attachments.map { "- Attachment: \($0)" }
        return lines.joined(separator: "\n")
    }
}

extension ChatSession {
    /// Creates the feedback chat and sends its first message; returns the chat's id. Nothing is created when the
    /// comment is blank, the Claude CLI isn't available, the project isn't loaded, a file is over 20 MB or all
    /// of them together are, or the files can't be stored.
    ///
    /// The chat is of kind `feedback`, named after the comment's first line, on the sheet's model and effort.
    /// The screenshot, then the files, are copied into `.hephaestus/chats/<chat id>/<uuid>-<name>` (the
    /// screenshot as `screenshot.png`) and become the message's attachments, which the chat shows; the message
    /// gives their paths, and the images among them go before its text as image blocks, so that Claude sees them.
    public func createFeedback(_ report: FeedbackReport) async throws(ChatError) -> String {
        let comment = report.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { throw .invalid("comment: write what happened.") }
        let cli = try await availableCLI()
        guard let project = projects.snapshot.project(report.projectID) else { throw .notFound("Project \(report.projectID) not found.") }
        let files = [report.screenshot].compactMap { $0 } + report.files
        var total = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= FeedbackReport.sizeLimit else { throw .invalid("\(file.lastPathComponent) is larger than 20 MB.") }
            total += size
        }
        guard total <= FeedbackReport.sizeLimit else { throw .invalid("The attachments of one request exceed 20 MB.") }

        let id = ChatIDs.make()
        let folder = ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true)).chatsFolder
            .appendingPathComponent(id, isDirectory: true)
        var stored: [URL] = []
        var recorded: [MessageAttachment] = []
        do {
            if !files.isEmpty {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for (index, file) in files.enumerated() {
                let name = index == 0 && report.screenshot != nil ? "screenshot.png" : file.lastPathComponent
                let fileID = UUID().uuidString
                let target = folder.appendingPathComponent("\(fileID)-\(name)")
                try FileManager.default.copyItem(at: file, to: target)
                stored.append(target)
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                recorded.append(.stored(id: fileID, name: name, chatID: id, size: size))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw .unavailable("The feedback's files couldn't be stored: \((error as NSError).localizedDescription)")
        }
        do {
            _ = try makeChat(id, projectID: report.projectID, title: comment, kind: .feedback, settings: report.settings)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let screenshot = report.screenshot == nil ? nil : stored.first
        let attachments = report.screenshot == nil ? stored : Array(stored.dropFirst())
        let message = FeedbackReport.message(comment: comment, context: report.context, screenshot: screenshot?.path,
                                             attachments: attachments.map(\.path))
        let images = stored.filter { ClaudeImage.isImage(contentType: nil, url: $0) }.compactMap { ClaudeImage(contentsOf: $0) }
        post(message, references: [], images: images, attachments: recorded, to: id, cli: cli)
        return id
    }

    /// Whether `chatID` is a feedback chat without its ticket yet: the first ticket its Claude creates is linked
    /// to it (docs/ui/chat.md › Feedback).
    public func isUnlinkedFeedback(_ chatID: String) -> Bool {
        guard let file = chats[chatID]?.file else { return false }
        return file.kind == .feedback && file.ticketID == nil
    }

    /// Records the ticket a feedback chat created as the chat's `ticket`.
    public func linkFeedback(_ chatID: String, toTicket ticketID: String) {
        guard isUnlinkedFeedback(chatID) else { return }
        change(chatID) { $0.ticketID = ticketID }
    }
}
