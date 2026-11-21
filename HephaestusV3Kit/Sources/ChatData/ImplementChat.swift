import ExternalTools
import FileStorage
import Foundation
import ProjectData

/// A chat that Implement or Implement All starts, or `implement_ticket` and `implement_bundle` (docs/data.md ›
/// Implement chats), as V2's implement chats: its first message calls the internal skill `implement-ticket` or
/// `implement-bundle` with the item's id.
public struct ImplementChat: Sendable, Hashable {
    /// What the chat implements.
    public enum Item: Sendable, Hashable {
        /// A ticket; with its orchestrator for a chat a bundle's chat starts.
        case ticket(String, orchestrator: Orchestrator? = nil)
        case bundle(String)
    }

    /// The bundle chat that starts a ticket chat with `implement_ticket`, and its bundle.
    public struct Orchestrator: Sendable, Hashable {
        public var chatID: String
        public var bundleID: String

        public init(chatID: String, bundleID: String) {
            self.chatID = chatID
            self.bundleID = bundleID
        }
    }

    public var item: Item
    public var projectID: String
    /// The ticket's or bundle's title, for the chat's.
    public var itemTitle: String
    public var settings: ChatSettings

    public init(_ item: Item, projectID: String, itemTitle: String, settings: ChatSettings) {
        self.item = item
        self.projectID = projectID
        self.itemTitle = itemTitle
        self.settings = settings
    }

    /// `Implement ORD-142: <title>`, `Implement All ORD-B3: <title>`, cut to 80 characters as a chat's title.
    public var title: String {
        switch item {
        case .ticket(let id, _): "Implement \(id): \(itemTitle)"
        case .bundle(let id): "Implement All \(id): \(itemTitle)"
        }
    }

    /// The first message: the skill's call, the ids as its arguments.
    public var message: String {
        switch item {
        case .ticket(let id, nil): "\(InternalSkill.implementTicket.command) \(id)"
        case .ticket(let id, let orchestrator?): "\(InternalSkill.implementTicket.command) \(id) \(orchestrator.bundleID)"
        case .bundle(let id): "\(InternalSkill.implementBundle.command) \(id)"
        }
    }

    /// The chat's file: its kind, its item, its orchestrator; a ticket chat asks no questions until the user writes.
    func file(id: String, created: Date) -> ChatFile {
        // One line of at most 80 characters, as a new chat's title.
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        var file = ChatFile(id: id, title: String(line.prefix(80)), kind: .project, created: created, settings: settings)
        switch item {
        case .ticket(let ticketID, let orchestrator):
            file.kind = .ticket
            file.ticketID = ticketID
            file.orchestratorChatID = orchestrator?.chatID
            file.questionsBlocked = true
        case .bundle(let bundleID):
            file.kind = .bundle
            file.bundleID = bundleID
        }
        return file
    }

    /// The message a turn's end sends the orchestrator (docs/data.md › Implement chats › Reports): stopped, ended in
    /// error with its reason, or finished with the final reply.
    static func report(ticketID: String, turn: ArraySlice<ChatItem>, stopped: Bool, failed: Bool) -> String {
        report(subject: "Chat of \(ticketID)", turn: turn, stopped: stopped, failed: failed)
    }

    /// The report of a chat named `subject`, such as `Chat of ORD-142` or `CI chat`.
    static func report(subject: String, turn: ArraySlice<ChatItem>, stopped: Bool, failed: Bool) -> String {
        if stopped { return "\(subject) was stopped." }
        let lastResult = turn.reversed().lazy.compactMap { item -> ResultItem? in
            if case .result(let result) = item { return result }
            return nil
        }.first
        if failed || lastResult?.isError == true {
            let systemError = turn.reversed().lazy.compactMap { item -> String? in
                if case .system(let line) = item, line.level == .error { return line.text }
                return nil
            }.first
            return "\(subject) ended in error: \(systemError ?? lastResult?.summary ?? "")"
        }
        let reply = turn.reversed().lazy.compactMap { item -> String? in
            if case .assistant(let text) = item, text.parentToolUseID == nil { return text.text }
            return nil
        }.first ?? ""
        return "\(subject) finished its turn:\n\n\(reply)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The refusal of the ask tools in a chat whose questions are blocked.
    public static let questionsRefusal = "This chat implements a ticket: it asks the user nothing until the user writes in it."
}

/// The branch and worktree of a ticket chat a bundle's chat starts (docs/data.md › Implement chats › Branch and
/// worktree): `<bundle id>/<ticket id>`, in `<data folder>/Worktrees/<project id>/<ticket id>`.
enum ChatWorktree {
    /// Each git command's time.
    static let timeout: Duration = .seconds(60)

    static func folder(dataFolder: URL, projectID: String, ticketID: String) -> URL {
        dataFolder.appendingPathComponent("Worktrees", isDirectory: true).appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(ticketID, isDirectory: true)
    }

    static func branch(bundleID: String, ticketID: String) -> String {
        "\(bundleID)/\(ticketID)"
    }

    /// Where a chat works in the worktree: the project's subfolder of its repository (the nearest folder up holding
    /// `.git`), or the worktree itself.
    static func workingFolder(worktree: URL, projectRoot: String) -> URL {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        var top = root
        while !FileManager.default.fileExists(atPath: top.appendingPathComponent(".git").path) {
            let parent = top.deletingLastPathComponent()
            guard parent.path != top.path else { return worktree }
            top = parent
        }
        let relative = root.pathComponents.dropFirst(top.pathComponents.count)
        return relative.reduce(worktree) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// V2's steps, each a git command in the project's folder: an earlier worktree and branch of the ticket are
    /// removed, then `git worktree add -b <branch> <worktree> HEAD`.
    static func prepare(git: String?, environment: [String: String], runner: any ProcessRunning, projectRoot: String, worktree: URL,
                        branch: String, ticketID: String) async throws(ChatError) {
        func failure(_ reason: String) -> ChatError {
            .unavailable("Cannot create the branch and worktree of \(ticketID): \(reason)")
        }
        guard let git else { throw failure("git is not available") }
        let environment = ShellEnvironment.forChildren(environment)
        func run(_ arguments: [String], failsOnStatus: Bool = true) async throws(ChatError) -> ProcessResult {
            let request = ProcessRequest(executable: git, arguments: arguments, environment: environment, currentDirectory: projectRoot)
            let result: ProcessResult
            do {
                result = try await runner.run(request, timeout: timeout)
            } catch {
                throw failure("git cannot start: \(error)")
            }
            if result.timedOut { throw failure("git did not finish within 60 seconds") }
            if failsOnStatus, !result.termination.isSuccess {
                let error = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw failure(error.isEmpty ? result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) : error)
            }
            return result
        }
        let parent = worktree.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw failure("\(parent.path) cannot be created: \((error as NSError).localizedDescription)")
        }
        // The worktree's path as git lists it: the parent exists, so its links resolve.
        let resolved = parent.resolvingSymlinksInPath().appendingPathComponent(worktree.lastPathComponent).path
        let listed = try await run(["worktree", "list", "--porcelain"]).standardOutputText
            .split(whereSeparator: \.isNewline)
            .compactMap { line in line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil }
        if listed.contains(where: { $0 == resolved || $0 == worktree.path }) {
            _ = try await run(["worktree", "remove", "--force", "--force", worktree.path])
        }
        if FileManager.default.fileExists(atPath: worktree.path) {
            do {
                try FileManager.default.removeItem(at: worktree)
            } catch {
                throw failure("\(worktree.path) cannot be deleted: \((error as NSError).localizedDescription)")
            }
            _ = try await run(["worktree", "prune"])
        }
        if try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], failsOnStatus: false).termination.isSuccess {
            _ = try await run(["branch", "-D", branch])
        }
        _ = try await run(["worktree", "add", "-b", branch, worktree.path, "HEAD"])
    }
}

extension ChatSession {
    // MARK: Implement chats (docs/data.md › Implement chats)

    /// Starts an implement chat and returns its id: the CLI checked, an orchestrated ticket chat's branch and
    /// worktree made, the chat's file written, then `link` (the ticket's or bundle's file), then the first message.
    /// A link that fails deletes the chat's file and throws its error.
    public func startImplementChat(_ request: ImplementChat,
                                   link: @MainActor (String) async throws(ChatError) -> Void) async throws(ChatError) -> String {
        let cli = try await availableCLI()
        guard let project = projects.snapshot.project(request.projectID) else { throw .notFound("Project \(request.projectID) not found.") }
        if case .ticket(let ticketID, let orchestrator?) = request.item {
            guard let dataFolder = projects.dataFolder else { throw .unavailable("The app has no data folder.") }
            // git is one of the tools, looked up once the projects load.
            await projects.waitForTools()
            await waitForWorktree()
            defer { worktreeDone() }
            try await ChatWorktree.prepare(git: projects.tools.git, environment: projects.tools.environment, runner: runner,
                                           projectRoot: project.root,
                                           worktree: ChatWorktree.folder(dataFolder: dataFolder.url, projectID: request.projectID, ticketID: ticketID),
                                           branch: ChatWorktree.branch(bundleID: orchestrator.bundleID, ticketID: ticketID), ticketID: ticketID)
        }
        let id = ChatIDs.make()
        _ = try? ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true)).ensureGitignore()
        try write(request.file(id: id, created: now()), projectID: request.projectID)
        transcripts[id] = []
        touch(id)
        do throws(ChatError) {
            try await link(id)
        } catch {
            if let url = metadataURL(id) { try? FileManager.default.removeItem(at: url) }
            chats[id] = nil
            transcripts[id] = nil
            throw error
        }
        post(request.message, references: [], images: [], to: id, cli: cli)
        return id
    }

    /// The orchestrator `implement_ticket` gives a ticket chat when `callerChatID` calls it: that chat, when it is a
    /// bundle chat whose bundle lists the ticket (`bundleTickets` gives a bundle's tickets).
    public func orchestrator(for ticketID: String, caller callerChatID: String?,
                             bundleTickets: @MainActor (String) -> [String]?) -> ImplementChat.Orchestrator? {
        guard let callerChatID, let caller = chats[callerChatID]?.file, caller.kind == .bundle, let bundleID = caller.bundleID,
              bundleTickets(bundleID)?.contains(ticketID) == true else { return nil }
        return ImplementChat.Orchestrator(chatID: callerChatID, bundleID: bundleID)
    }

    /// Whether `itemID` is the chat's own item (docs/mcp.md › Permissions): a ticket chat's ticket; a bundle chat's
    /// bundle, or a ticket that bundle lists (`bundleTickets`).
    public func ownsItem(_ itemID: String, chat chatID: String, bundleTickets: @MainActor (String) -> [String]?) -> Bool {
        guard let file = chats[chatID]?.file else { return false }
        switch file.kind {
        case .ticket:
            return file.ticketID == itemID
        case .bundle:
            guard let bundleID = file.bundleID else { return false }
            return itemID == bundleID || bundleTickets(bundleID)?.contains(itemID) == true
        case .project, .feedback, .ci, .setup:
            return false
        }
    }

    /// Why the ask tools are refused in the chat: its questions are blocked until the user writes. `questions` is
    /// `ask_questions`, which an implement chat may call once after a CI failure (docs/data.md › CI chats).
    public func questionsRefusal(in chatID: String, questions: Bool = false) -> String? {
        guard chats[chatID]?.file.questionsBlocked == true else { return nil }
        return questions && ciQuestionChats.contains(chatID) ? nil : ImplementChat.questionsRefusal
    }

    /// A ticket's chats: those whose `ticket` is it, in the order of `ordered(_:)`.
    public func chats(ofTicket ticketID: String) -> [LoadedChat] {
        ordered(chats.values.filter { $0.file.ticketID == ticketID })
    }

    /// A bundle's chats: those whose `bundle` is it, in the order of `ordered(_:)`, which brings the ticket chats
    /// its chat started.
    public func chats(ofBundle bundleID: String) -> [LoadedChat] {
        ordered(chats.values.filter { $0.file.bundleID == bundleID })
    }

    /// An item's chats as the Tickets window lists them: those whose orchestrator isn't among them, the latest
    /// updated first, each followed by the loaded chats it orchestrates, oldest first.
    private func ordered(_ own: [LoadedChat]) -> [LoadedChat] {
        let ids = Set(own.map(\.id))
        let top = own.filter { chat in chat.file.orchestratorChatID.map { !ids.contains($0) } ?? true }
            .sorted { $0.file.updated > $1.file.updated }
        return top.flatMap { chat in
            [chat] + chats.values.filter { $0.file.orchestratorChatID == chat.id }.sorted { ($0.file.created, $0.id) < ($1.file.created, $1.id) }
        }
    }

    /// Whether one of the chats `chatID` orchestrates is at work.
    func isOrchestrating(_ chatID: String) -> Bool {
        chats.values.contains { $0.file.orchestratorChatID == chatID && state(of: $0.id).isRunning }
    }

    /// The folder an orchestrated ticket chat works in: its worktree's, while its orchestrator exists, it is its
    /// ticket's newest orchestrated chat and the folder exists; nil otherwise.
    func worktreeFolder(of chat: LoadedChat, projectRoot: String) -> String? {
        guard chat.file.kind == .ticket, let orchestrator = chat.file.orchestratorChatID, chats[orchestrator] != nil,
              let ticketID = chat.file.ticketID, let dataFolder = projects.dataFolder else { return nil }
        let newest = chats.values.filter {
            $0.projectID == chat.projectID && $0.file.kind == .ticket && $0.file.ticketID == ticketID && $0.file.orchestratorChatID != nil
        }.max { ($0.file.created, $0.id) < ($1.file.created, $1.id) }
        guard newest?.id == chat.id else { return nil }
        let worktree = ChatWorktree.folder(dataFolder: dataFolder.url, projectID: chat.projectID, ticketID: ticketID)
        let folder = ChatWorktree.workingFolder(worktree: worktree, projectRoot: projectRoot)
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue ? folder.path : nil
    }

    /// A turn of a chat with an orchestrator ended: the orchestrator gets the report (docs/data.md › Implement
    /// chats › Reports, CI chats). Nothing while the app quits, without the orchestrator or the CLI, or when the turn
    /// waits for answers. A CI failure lets an implement chat post one question set; another CI report takes it back.
    func reportToOrchestrator(_ chatID: String, from old: ChatState?, to new: ChatState) {
        guard !quitting, let old, [.starting, .running, .waitingPermission].contains(old), new == .idle || new == .error,
              let chat = chats[chatID], let orchestratorID = chat.file.orchestratorChatID, let orchestrator = chats[orchestratorID],
              status.isAvailable, let cli = status.path else { return }
        let message: String
        if chat.file.kind == .ci {
            message = CIChat.report(turn: lastTurn(chatID), stopped: lastTurnStopped(chatID), failed: new == .error)
            if CIChat.isFailure(message), orchestrator.file.questionsBlocked {
                ciQuestionChats.insert(orchestratorID)
            } else {
                ciQuestionChats.remove(orchestratorID)
            }
        } else {
            message = ImplementChat.report(ticketID: chat.file.ticketID ?? chat.file.title, turn: lastTurn(chatID),
                                           stopped: lastTurnStopped(chatID), failed: new == .error)
        }
        post(message, references: [], images: [], to: orchestratorID, cli: cli)
    }

    /// Waits until no other worktree is being made.
    private func waitForWorktree() async {
        if preparingWorktree {
            await withCheckedContinuation { worktreeWaiters.append($0) }
        }
        preparingWorktree = true
    }

    /// The next call waiting makes its worktree.
    private func worktreeDone() {
        if worktreeWaiters.isEmpty {
            preparingWorktree = false
        } else {
            worktreeWaiters.removeFirst().resume()
        }
    }
}
