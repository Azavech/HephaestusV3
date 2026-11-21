import Foundation
import ProjectData

/// A chat that `watch_ci` starts (docs/data.md › CI chats), as V2's CI chats: it follows the GitHub Actions runs of
/// a commit the calling chat pushed, its first message calling the internal skill `watch-ci`, and each of its turns
/// is reported to that chat, its orchestrator.
public struct CIChat: Sendable, Hashable {
    /// The ticket or bundle of the chat that pushed, which the CI chat shares.
    public enum Item: Sendable, Hashable {
        case ticket(String)
        case bundle(String)

        public var id: String {
            switch self {
            case .ticket(let id), .bundle(let id): id
            }
        }
    }

    public var projectID: String
    /// The chat that pushed, which gets the reports.
    public var orchestrator: String
    public var item: Item
    /// The full hash, in lowercase.
    public var commit: String
    public var settings: ChatSettings

    public init(projectID: String, orchestrator: String, item: Item, commit: String, settings: ChatSettings) {
        self.projectID = projectID
        self.orchestrator = orchestrator
        self.item = item
        self.commit = commit.lowercased()
        self.settings = settings
    }

    /// `CI of ORD-142: 8e7ccf3`.
    public var title: String {
        "CI of \(item.id): \(commit.prefix(7))"
    }

    /// The first message: the skill's call, the commit as its argument.
    public var message: String {
        "\(InternalSkill.watchCI.command) \(commit)"
    }

    /// The chat's file: kind `ci`, its orchestrator and the orchestrator's item, the orchestrator's settings.
    func file(id: String, created: Date) -> ChatFile {
        var file = ChatFile(id: id, title: String(title.prefix(80)), kind: .ci, created: created, settings: settings)
        file.orchestratorChatID = orchestrator
        switch item {
        case .ticket(let id): file.ticketID = id
        case .bundle(let id): file.bundleID = id
        }
        return file
    }

    /// Whether `commit` is a full hash: 40 or 64 hexadecimal characters, in any case.
    public static func isFullHash(_ commit: String) -> Bool {
        [40, 64].contains(commit.utf8.count) && commit.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
        }
    }

    /// The message a turn's end sends the orchestrator, V2's texts: stopped, ended in error with its reason, or
    /// finished with the final reply. The same items as an orchestrated ticket chat's report.
    static func report(turn: ArraySlice<ChatItem>, stopped: Bool, failed: Bool) -> String {
        ImplementChat.report(subject: "CI chat", turn: turn, stopped: stopped, failed: failed)
    }

    /// Whether a report is a CI failure: anything but a finished turn whose reply's first line that isn't empty,
    /// trimmed of white space and of Markdown's `*`, `_` and `#`, starts with `CI passed.` or `CI not checked.`.
    public static func isFailure(_ report: String) -> Bool {
        let finished = "CI chat finished its turn:"
        guard report.hasPrefix(finished) else { return true }
        let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_#"))
        let line = report.dropFirst(finished.count).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: trimmed) }.first { !$0.isEmpty } ?? ""
        return !(line.hasPrefix("CI passed.") || line.hasPrefix("CI not checked."))
    }

    /// The refusals of `watch_ci`, V2's.
    public static let externalRefusal = "Only a chat's own Claude can start a CI chat."
    public static let callerRefusal = "Only a ticket or bundle chat that no other chat started can start a CI chat."
    public static let commitRefusal = "commit: give the full hash of the pushed commit, 40 or 64 hexadecimal characters."
}

extension ChatSession {
    // MARK: CI chats (docs/data.md › CI chats)

    /// Starts the CI chat `callerChatID` asks for with `watch_ci` and returns its id: the checks, then the chat's
    /// file, then `link` (the ticket's or bundle's file, which fails when it isn't loaded), then the first message,
    /// carrying the project. A link that fails deletes the chat's file and throws its error.
    public func startCIChat(commit: String, caller callerChatID: String?,
                            link: @MainActor (CIChat.Item, String) async throws(ChatError) -> Void) async throws(ChatError) -> String {
        guard let callerChatID else { throw .forbidden(CIChat.externalRefusal) }
        guard let caller = chats[callerChatID] else { throw .notFound("Chat \(callerChatID) not found.") }
        let item: CIChat.Item
        switch (caller.file.kind, caller.file.ticketID, caller.file.bundleID) {
        case (.ticket, let ticketID?, _) where caller.file.orchestratorChatID == nil: item = .ticket(ticketID)
        case (.bundle, _, let bundleID?) where caller.file.orchestratorChatID == nil: item = .bundle(bundleID)
        default: throw .forbidden(CIChat.callerRefusal)
        }
        guard CIChat.isFullHash(commit) else { throw .invalid(CIChat.commitRefusal) }
        guard let project = projects.snapshot.project(caller.projectID) else { throw .notFound("Project \(caller.projectID) not found.") }
        guard project.resolved.githubPage != nil else { throw .conflict("Project \(caller.projectID) has no GitHub page.") }
        let request = CIChat(projectID: caller.projectID, orchestrator: callerChatID, item: item, commit: commit, settings: caller.file.settings)
        let cli = try await availableCLI()
        let id = ChatIDs.make()
        try write(request.file(id: id, created: now()), projectID: request.projectID)
        transcripts[id] = []
        touch(id)
        do throws(ChatError) {
            try await link(item, id)
        } catch {
            if let url = metadataURL(id) { try? FileManager.default.removeItem(at: url) }
            chats[id] = nil
            transcripts[id] = nil
            throw error
        }
        let projectReference = ChatItemReference(tool: ChatItemReference.projectTool, projectID: project.id, focus: "", title: project.file.name)
        post(request.message, references: [projectReference], images: [], to: id, cli: cli)
        return id
    }
}
