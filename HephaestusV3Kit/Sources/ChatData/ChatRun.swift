import Darwin
import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData

/// A chat's live CLI process and what the session tracks of it (docs/architecture.md › ChatData › Turns).
@MainActor
final class ChatRun {
    let chatID: String
    let connection: any ClaudeConnection
    let token: String
    let mcpConfig: URL
    let resumed: Bool
    var mapper: StreamMapper
    /// The messages written and not finished, oldest first, each with the CLI's last state.
    var outstanding: [(uuid: String, state: String?)] = []
    /// Each message written, its text and images, for a launch again when the session is missing.
    var messages: [String: OutgoingMessage] = [:]
    var cliTurnOpen = false
    /// A turn runs: from a message written, or a CLI turn the CLI began, until nothing is outstanding.
    var inTurn = false
    /// The first `system/init` came.
    var initialized = false
    /// The app ended the process (Stop, idle, the start timeout, quitting): its exit is no error.
    var endedByApp = false
    var stopping = false
    var retried = false
    /// The CLI's permission requests waiting, by request id, with their input.
    var cliPermissions: [String: JSONValue] = [:]
    /// Their `permission_suggestions`, which Always Allow passes back.
    var cliSuggestions: [String: JSONValue] = [:]
    /// The `set_permission_mode` requests awaiting their answer, by request id, with the mode asked.
    var modeRequests: [String: ChatPermissionMode] = [:]
    /// The window the process started with: a new one needs a new process.
    var contextWindow: ChatContextWindow = .auto
    /// The MCP port the process was launched with: after a change, it ends once no turn runs.
    var port = 0
    var nextControl = 1
    var initializeID = ""
    /// The app's settings requests, by request id: `model` or `effort`.
    var settingsRequests: [String: String] = [:]
    var startTimer: Task<Void, Never>?
    var idleTimer: Task<Void, Never>?
    var stopTimer: Task<Void, Never>?
    /// Close asked during the turn: the chat closes once it ends well.
    var closesAfterTurn = false
    /// Stop Workflow's requests waiting for their answer, by request id: the workflow's id.
    var stopRequests: [String: String] = [:]
    /// The background tasks running, every one a `background_tasks_changed` listed, and whether the CLI owes a
    /// turn for a task that ended between turns (docs/data.md › Background work).
    var backgroundTasks: Set<String> = []
    var listedTasks: Set<String> = []
    var notificationPending = false
    /// The workflows Stop Workflow stopped: the CLI owes no turn for their end, as V2 knew.
    var stoppedTasks: Set<String> = []

    /// Background work runs: a task, or the turn that will report one.
    var hasBackgroundWork: Bool { !backgroundTasks.isEmpty || notificationPending }
    /// The `get_context_usage` request awaiting its answer.
    var contextRequestID: String?
    /// A line asked for the context usage while a request was awaited.
    var contextAskedAgain = false
    /// The last message of Claude's that asked for the context usage: one ask per message.
    var lastAssistantMessage: String?

    init(chatID: String, connection: any ClaudeConnection, token: String, mcpConfig: URL, resumed: Bool, effort: Effort,
         now: @escaping @Sendable () -> Date) {
        self.chatID = chatID
        self.connection = connection
        self.token = token
        self.mcpConfig = mcpConfig
        self.resumed = resumed
        mapper = StreamMapper(effort: effort, now: now)
    }

    /// The id of the next control request: `hephaestus-<n>`.
    func controlID() -> String {
        defer { nextControl += 1 }
        return "hephaestus-\(nextControl)"
    }

    /// Ends the process: stdin closed, then SIGTERM and SIGKILL, each after the grace, while it lives.
    func end(closingInput: Bool, grace: Duration) {
        endedByApp = true
        let connection = connection
        if closingInput {
            connection.closeInput()
        } else {
            connection.signal(SIGTERM)
        }
        Task {
            try? await Task.sleep(for: grace)
            guard !connection.hasExited else { return }
            if closingInput {
                connection.signal(SIGTERM)
                try? await Task.sleep(for: grace)
                guard !connection.hasExited else { return }
            }
            connection.signal(SIGKILL)
        }
    }
}

extension ChatSession {
    // MARK: Sending

    /// Sends a message to the chat, or to a new chat of `projectID` when `chatID` is nil, and returns the chat's
    /// id. `references` are the items the message carries; `origin` is the tool whose panel starts a new chat;
    /// `title` a new chat's, instead of the message's first line; `images` go before the text, as Claude sees
    /// them. `files` are copied into the chat's folder and become the message's attachments (docs/data.md ›
    /// Message files): the images among them go to Claude as images, and each file's path follows the text as
    /// an `Attached: file <path>` line. A message has text, files, or both.
    ///
    /// The user's message lifts an implement chat's block on questions (docs/data.md › Implement chats).
    @discardableResult
    public func send(_ text: String, references: [ChatItemReference], to chatID: String?, projectID: String,
                     origin: String? = nil, title: String? = nil, images: [ClaudeImage] = [], files: [URL] = []) async throws(ChatError) -> String {
        try await send(text, references: references, to: chatID, projectID: projectID, origin: origin, title: title, images: images,
                       files: files, fromUser: true)
    }

    /// `send`, saying whether the user wrote the message: Resume's call of `resume-chat` didn't.
    func send(_ text: String, references: [ChatItemReference], to chatID: String?, projectID: String, origin: String?, title: String?,
              images: [ClaudeImage], files: [URL], fromUser: Bool) async throws(ChatError) -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !files.isEmpty else { throw .invalid("text: write a message.") }
        try MessageAttachment.check(files)
        let cli = try await availableCLI()
        let id: String
        if let chatID {
            guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
            id = chatID
            await open(id)
        } else {
            id = try makeChat(projectID: projectID, title: title ?? (message.isEmpty ? files[0].lastPathComponent : message), settings: defaults,
                              origin: origin)
        }
        var attachments: [MessageAttachment] = []
        var carried: [ChatItemReference] = []
        var sentImages = images
        if !files.isEmpty, let folder = folder(of: id) {
            let sources = files.map { (url: $0, name: $0.lastPathComponent) }
            let destination = folder.chatsFolder.appendingPathComponent(id, isDirectory: true)
            // Off the main actor: copying files of up to 20 MB and converting images take time.
            let copied = await Task.detached(priority: .userInitiated) { () -> Result<[(url: URL, attachment: MessageAttachment)], ChatError> in
                do throws(ChatError) {
                    return .success(try MessageAttachment.store(sources, chatID: id, in: destination))
                } catch {
                    return .failure(error)
                }
            }.value
            let stored = try copied.get()
            attachments = stored.map(\.attachment)
            carried = stored.map { ChatItemReference(tool: ChatItemReference.fileTool, projectID: projectID, focus: $0.url.path, title: $0.attachment.name) }
            sentImages += await ClaudeImage.load(stored.filter { ClaudeImage.isImage(contentType: $0.attachment.contentType, url: $0.url) }
                .map(\.url))
        }
        post(message, references: references, images: sentImages, attachments: attachments, carried: carried, to: id, cli: cli,
             liftsQuestionBlock: fromUser)
        return id
    }

    /// Writes a new chat's file, of `kind`, with the first line of `title`, and lists it.
    func makeChat(_ id: String = ChatIDs.make(), projectID: String, title: String, kind: ChatFile.Kind = .project, settings: ChatSettings,
                  origin: String? = nil) throws(ChatError) -> String {
        guard let project = projects.snapshot.project(projectID) else { throw .notFound("Project \(projectID) not found.") }
        let file = ChatFile(id: id, title: Self.title(of: title), kind: kind, created: now(), settings: settings, origin: origin)
        _ = try? ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true)).ensureGitignore()
        try write(file, projectID: projectID)
        transcripts[id] = []
        touch(id)
        return id
    }

    /// Records the user's message in the chat, with the files it carries, then writes it to the chat's process,
    /// starting one when none runs. `carried` are items Claude reads of but the message doesn't keep as its own:
    /// its stored files.
    func post(_ message: String, references: [ChatItemReference], images: [ClaudeImage], attachments: [MessageAttachment] = [],
              carried: [ChatItemReference] = [], to id: String, cli: String, liftsQuestionBlock: Bool = false) {
        let item = UserItem(created: now(), text: message, sender: device, references: references, attachments: attachments)
        record(.user(item), in: id)
        change(id) {
            $0.updated = item.created
            $0.closed = false
            if liftsQuestionBlock { $0.questionsBlocked = false }
        }
        failed.remove(id)
        let line = OutgoingMessage(text: ClaudeInput.text(message, carrying: references + carried), images: images)
        if let run = runs[id], !run.connection.hasExited, !run.endedByApp {
            deliver(item.id, line, to: run)
        } else {
            launch(id, cli: cli, messages: [(item.id, line)])
        }
        refreshState(id)
    }

    /// A new chat's title: the message's first line that isn't empty, at most 80 characters.
    static func title(of message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? message
        return String(line.prefix(80))
    }

    private func deliver(_ uuid: String, _ message: OutgoingMessage, to run: ChatRun) {
        run.messages[uuid] = message
        run.outstanding.append((uuid, nil))
        run.connection.write(ClaudeInput.message(message.text, images: message.images, uuid: uuid))
        run.idleTimer?.cancel()
        if !run.inTurn {
            run.inTurn = true
        }
    }

    // MARK: Launching

    func launch(_ chatID: String, cli: String, messages: [(uuid: String, message: OutgoingMessage)]) {
        guard let chat = chats[chatID], let project = projects.snapshot.project(chat.projectID), let dataFolder = projects.dataFolder else {
            record(.system(SystemItem(created: now(), text: "Claude failed to start: the chat's project isn't loaded.", level: .error)), in: chatID)
            failed.insert(chatID)
            return
        }
        let token = tokens.issue(forChat: chatID)
        let config = dataFolder.url.appendingPathComponent("Runtime/mcp/\(chatID).json")
        // The internal skills chats call, as the user last saved them; without them, and a warning, when they can't
        // be written.
        let plugin: URL?
        do {
            plugin = try dataFolder.writeChatPlugin()
        } catch {
            plugin = nil
            record(.system(SystemItem(created: now(), text: "Skills could not be prepared: \(error)", level: .warning)), in: chatID)
        }
        var launch = ChatLaunch(cliPath: cli, chatID: chatID, resume: chat.file.sessionStarted, model: chat.file.settings.model,
                                effort: chat.file.settings.effort, mcpConfig: config, tools: toolNames,
                                disallowedTools: ClaudeFileTools.disallowed(edits: fileEdits()), workingDirectory: root(ofChat: chatID) ?? project.root,
                                environment: projects.tools.environment, pluginDir: plugin)
        launch.permissionMode = ChatPermissionMode(stored: chat.file.settings.permissionMode)
        launch.ultracode = chat.file.settings.ultracode
        launch.contextWindow = ChatContextWindow(stored: chat.file.settings.contextWindow)
        let connection: any ClaudeConnection
        do {
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = try AtomicFile.write(ChatLaunch.mcpConfiguration(port: port, token: token), to: config, newFileMode: AtomicFile.privateMode)
            connection = try launcher.launch(launch.request, log: dataFolder.url.appendingPathComponent("Logs/claude-\(chatID).log"),
                                             logLine: launch.logLine)
        } catch {
            tokens.revoke(token)
            try? FileManager.default.removeItem(at: config)
            record(.system(SystemItem(created: now(), text: "Claude failed to start: \(error)", level: .error)), in: chatID)
            failed.insert(chatID)
            refreshState(chatID)
            return
        }
        let run = ChatRun(chatID: chatID, connection: connection, token: token, mcpConfig: config, resumed: launch.resume,
                          effort: chat.file.settings.effort, now: now)
        run.contextWindow = launch.contextWindow
        run.port = port
        if let mcpUnavailable {
            record(.system(SystemItem(created: now(), text: "Hephaestus MCP server unavailable: \(mcpUnavailable)", level: .warning)), in: chatID)
        }
        runs[chatID] = run
        touch(chatID)
        run.initializeID = run.controlID()
        connection.write(ClaudeInput.control(run.initializeID, ["subtype": "initialize"]))
        for message in messages {
            deliver(message.uuid, message.message, to: run)
        }
        run.startTimer = Task { [weak self, weak run] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, let run, !run.initialized, self.runs[chatID] === run else { return }
            self.record(.system(SystemItem(created: self.now(), text: "Claude did not start within 60 seconds.", level: .error)), in: chatID)
            self.failed.insert(chatID)
            run.end(closingInput: false, grace: Self.signalGrace)
            self.refreshState(chatID)
        }
        // Each line is read as JSON off the main actor, in order: a tool result can be megabytes, a screenshot's.
        let (parsed, input) = AsyncStream.makeStream(of: JSONValue?.self, bufferingPolicy: .unbounded)
        let reader = Task.detached(priority: .userInitiated) {
            for await line in connection.lines {
                input.yield(StreamMapper.parse(line))
            }
            input.finish()
        }
        input.onTermination = { _ in reader.cancel() }
        Task { [weak self] in
            for await value in parsed {
                self?.handle(parsed: value, of: run)
            }
            let termination = await connection.waitForExit()
            self?.exited(run, termination)
        }
        refreshState(chatID)
    }

    // MARK: Output

    func handle(_ line: Data, of run: ChatRun) {
        handle(parsed: StreamMapper.parse(line), of: run)
    }

    func handle(parsed value: JSONValue?, of run: ChatRun) {
        let chatID = run.chatID
        guard runs[chatID] === run else { return }
        for output in run.mapper.map(parsed: value) {
            switch output {
            case .item(let item):
                if streaming[chatID]?.itemID == item.id { streaming[chatID] = nil }
                record(item, in: chatID, op: self.item(item.id, in: chatID) == nil ? .add : .update)
                noteAgents(of: item, in: chatID)
                if case .assistant(let text) = item, text.parentToolUseID == nil, text.messageID != run.lastAssistantMessage {
                    run.lastAssistantMessage = text.messageID
                    askContextUsage(run)
                }
            case .toolResultImages(let toolUseID, let images):
                Task { await storeResultImages(images, of: toolUseID, in: chatID) }
            case .delta(let itemID, let text):
                if streaming[chatID]?.itemID == itemID {
                    streaming[chatID]?.text += text
                } else {
                    streaming[chatID] = StreamingText(itemID: itemID, text: text)
                }
            case .taskLine(let line):
                applyTaskLine(line, in: chatID)
            case .backgroundTasks(let ids):
                run.backgroundTasks = Set(ids)
                run.listedTasks.formUnion(ids)
                noteBackgroundWork(run)
            case .taskNotification(let id):
                if !run.cliTurnOpen, run.listedTasks.contains(id), !run.stoppedTasks.contains(id) {
                    run.notificationPending = true
                    noteBackgroundWork(run)
                }
            case .cliTurnOpened(let first, let problem, let model, let mode):
                // The turn first, then the owed turn's end: the background work's end must not end a process whose
                // turn just opened (a changed context window waits for the turn).
                run.cliTurnOpen = true
                run.inTurn = true
                run.idleTimer?.cancel()
                run.notificationPending = false
                noteBackgroundWork(run)
                if first {
                    run.initialized = true
                    run.startTimer?.cancel()
                    if chats[chatID]?.file.sessionStarted == false { change(chatID) { $0.sessionStarted = true } }
                    if let settings = chats[chatID]?.file.settings {
                        record(.system(SystemItem(created: now(), text: Self.sessionStartText(model: model, mode: mode, settings: settings, models: models),
                                                  level: .info)), in: chatID)
                    }
                    if let problem {
                        record(.system(SystemItem(created: now(), text: "The Hephaestus tools aren't available in this session: the app's MCP server is \(problem).",
                                                  level: .warning)), in: chatID)
                    }
                }
            case .commandState(let uuid, let state):
                guard let index = run.outstanding.firstIndex(where: { $0.uuid == uuid }) else { break }
                if state == "queued" || state == "started" {
                    run.outstanding[index].state = state
                } else {
                    run.outstanding.remove(at: index)
                    endTurnIfDone(run)
                }
            case .permissionRequest(let request, let suggestions):
                // A file tool's call is answered at once where Settings ▸ Chat and the chat's mode decide it; anything
                // else gets its card.
                switch root(ofChat: chatID).flatMap({ ClaudeFileTools.decision(tool: request.toolName, input: request.input, root: $0,
                                                                                edits: fileEdits(forChat: chatID)) }) {
                case .allow?:
                    run.connection.write(ClaudeInput.allow(request.requestID, input: request.input))
                case .deny(let message)?:
                    run.connection.write(ClaudeInput.deny(request.requestID, message: message))
                case .ask?, nil:
                    run.cliPermissions[request.requestID] = request.input
                    run.cliSuggestions[request.requestID] = suggestions
                    record(.permissionRequest(request), in: chatID)
                }
            case .unsupportedControlRequest(let id, let subtype):
                run.connection.write(ClaudeInput.unsupported(id, subtype: subtype))
            case .controlResponse(let id, let success, let response, let error):
                if stopAnswered(id, success: success, error: error, run: run) {
                    break
                } else if id == run.contextRequestID {
                    received(contextUsage: response, success: success, for: run)
                } else if let mode = run.modeRequests.removeValue(forKey: id) {
                    if success {
                        approvePending(in: chatID, for: mode)
                    } else {
                        record(.system(SystemItem(created: now(), text: "Claude did not accept the new permission mode now: \(error ?? "no reason"). It applies the next time Claude starts.",
                                                  level: .warning)), in: chatID)
                    }
                } else if id == run.initializeID, success {
                    if let list = ClaudeModel.list(response?["models"]), models != list { models = list }
                    if let list = ClaudeCommand.list(response?["commands"]).map(markingSynced), let projectID = chats[chatID]?.projectID,
                       projectCommands[projectID] != list {
                        projectCommands[projectID] = list
                    }
                } else if let setting = run.settingsRequests.removeValue(forKey: id), !success {
                    record(.system(SystemItem(created: now(), text: "Claude did not accept the new \(setting) now: \(error ?? "no reason"). It applies the next time Claude starts.",
                                              level: .warning)), in: chatID)
                }
            case .cancelRequest(let id):
                guard run.cliPermissions.removeValue(forKey: id) != nil else { break }
                decide(chatID, requestID: id, decision: .deny, by: nil)
            case .result(let result):
                record(.result(result), in: chatID)
                stopForegroundAgents(in: chatID)
                if result.isError { run.closesAfterTurn = false }
                askContextUsage(run)
                run.cliTurnOpen = false
                if run.outstanding.contains(where: { $0.state == "started" }) {
                    run.outstanding.removeAll { $0.state == "started" }
                } else if let index = run.outstanding.firstIndex(where: { $0.state == nil }) {
                    run.outstanding.remove(at: index)
                }
                run.stopTimer?.cancel()
                run.stopping = false
                streaming[chatID] = nil
                endTurnIfDone(run)
            case .compactionStarted:
                compacting.insert(chatID)
            case .compactionEnded:
                compacting.remove(chatID)
                askContextUsage(run)
            case .planUsage(let usage):
                receive(planUsage: usage)
            case .permissionMode(let mode):
                followCLIPermissionMode(mode, in: chatID)
            case .ignored(let type):
                // As V2's log: every line the app doesn't use, but the stream's own events, which come by the hundred.
                if !type.hasPrefix("stream_event") { run.connection.log("ignored \(type)") }
            case .invalid:
                run.connection.log("invalid line: not a JSON object")
            }
        }
        refreshState(chatID)
    }

    /// Ends the turn once nothing written is outstanding and no CLI turn is open; the idle timer starts.
    private func endTurnIfDone(_ run: ChatRun) {
        guard run.inTurn, run.outstanding.isEmpty, !run.cliTurnOpen else { return }
        run.inTurn = false
        change(run.chatID) { $0.updated = now() }
        if run.closesAfterTurn {
            run.closesAfterTurn = false
            closeNow(run.chatID)
            return
        }
        startIdleTimer(run)
    }

    /// The process's background work started or ended: the session says so, and the idle timer starts once
    /// nothing runs, neither a turn nor background work.
    func noteBackgroundWork(_ run: ChatRun) {
        let busy = run.hasBackgroundWork
        if busy != backgroundWork.contains(run.chatID) {
            if busy { backgroundWork.insert(run.chatID) } else { backgroundWork.remove(run.chatID) }
        }
        if busy {
            run.idleTimer?.cancel()
        } else if !run.inTurn {
            startIdleTimer(run)
        }
    }

    /// Ends the process after `idleTimeout` without a turn or background work; at once when its context window
    /// or the MCP port changed.
    func startIdleTimer(_ run: ChatRun) {
        guard !run.inTurn, !run.hasBackgroundWork else { return }
        // A new context window or port needs a new process: the next message resumes with it.
        if ChatContextWindow(stored: chats[run.chatID]?.file.settings.contextWindow ?? "") != run.contextWindow || run.port != port {
            run.end(closingInput: true, grace: Self.signalGrace)
            return
        }
        run.idleTimer?.cancel()
        run.idleTimer = Task { [weak self, weak run] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, let run, self.runs[run.chatID] === run, !run.inTurn, !run.hasBackgroundWork else { return }
            run.end(closingInput: true, grace: Self.signalGrace)
        }
    }

    func exited(_ run: ChatRun, _ termination: ProcessTermination) {
        let chatID = run.chatID
        tokens.revoke(run.token)
        try? FileManager.default.removeItem(at: run.mcpConfig)
        run.startTimer?.cancel()
        run.idleTimer?.cancel()
        run.stopTimer?.cancel()
        guard runs[chatID] === run else { return }
        runs[chatID] = nil
        // Its background tasks and the turn it owed end with it, and its workflows and agents.
        backgroundWork.remove(chatID)
        stopAllAgents(in: chatID)
        for item in run.mapper.finish() {
            record(item, in: chatID)
        }
        streaming[chatID] = nil
        compacting.remove(chatID)
        for id in Array(run.cliPermissions.keys) {
            decide(chatID, requestID: id, decision: .deny, by: nil)
        }
        run.cliPermissions = [:]
        cancelApprovals(of: chatID, by: nil)
        let missingSession = run.resumed && !run.initialized && !run.retried
            && run.connection.errorLines.contains { $0.contains("No conversation found with session ID") }
        if missingSession, let cli = status.path {
            change(chatID) { $0.sessionStarted = false }
            record(.system(SystemItem(created: now(), text: "Claude's session for this chat was not found. A new session started: Claude doesn't remember this chat's earlier messages.",
                                      level: .warning)), in: chatID)
            let messages = run.outstanding.map { ($0.uuid, run.messages[$0.uuid] ?? OutgoingMessage(text: "")) }
            launch(chatID, cli: cli, messages: messages)
            runs[chatID]?.retried = true
            refreshState(chatID)
            return
        }
        if run.inTurn, !run.endedByApp, termination != .exited(0) {
            let text: String
            switch termination {
            case .exited(let code):
                let last = run.connection.errorLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                text = last.map { "Claude exited with code \(code): \($0.trimmingCharacters(in: .whitespaces))" } ?? "Claude exited with code \(code)."
            case .signaled(let signal):
                text = "Claude was terminated by signal \(signal)."
            }
            record(.system(SystemItem(created: now(), text: text, level: .error)), in: chatID)
            failed.insert(chatID)
        }
        if run.inTurn { change(chatID) { $0.updated = now() } }
        refreshState(chatID)
    }

    // MARK: Stop

    /// Stops Claude's turn: the cards waiting are refused, the CLI is interrupted, then signalled if it doesn't
    /// stop (SIGINT, SIGTERM, SIGKILL, 5 s apart).
    public func stop(_ chatID: String) {
        guard let run = runs[chatID], run.inTurn || !run.cliPermissions.isEmpty else { return }
        run.closesAfterTurn = false
        for id in Array(run.cliPermissions.keys) {
            run.connection.write(ClaudeInput.deny(id, message: "The user stopped Claude."))
            run.cliPermissions[id] = nil
            decide(chatID, requestID: id, decision: .deny, by: device)
        }
        cancelApprovals(of: chatID, by: device)
        record(.system(SystemItem(created: now(), text: "Stopped by the user.")), in: chatID)
        run.mapper.stopping = true
        run.stopping = true
        run.connection.write(ClaudeInput.control(run.controlID(), ["subtype": "interrupt"]))
        let connection = run.connection
        run.stopTimer?.cancel()
        run.stopTimer = Task { [weak run] in
            for signal in [SIGINT, SIGTERM, SIGKILL] {
                try? await Task.sleep(for: Self.signalGrace)
                guard !Task.isCancelled, let run, run.stopping, !connection.hasExited else { return }
                run.endedByApp = true
                connection.signal(signal)
            }
        }
        refreshState(chatID)
    }

    /// Ends every process when the app quits: a turn in progress gets a line saying so; SIGTERM, then SIGKILL
    /// after 3 s.
    public func stopAll() {
        quitting = true
        let live = Array(runs.values)
        for run in live where run.inTurn {
            record(.system(SystemItem(created: now(), text: "Stopped because Hephaestus quit.", level: .warning)), in: run.chatID)
            for id in Array(run.cliPermissions.keys) { decide(run.chatID, requestID: id, decision: .deny, by: nil) }
            cancelApprovals(of: run.chatID, by: nil)
        }
        for run in live {
            run.endedByApp = true
            run.connection.signal(SIGTERM)
            tokens.revoke(run.token)
            try? FileManager.default.removeItem(at: run.mcpConfig)
        }
        let deadline = Date().addingTimeInterval(3)
        while live.contains(where: { !$0.connection.hasExited }), Date() < deadline {
            usleep(50_000)
        }
        for run in live where !run.connection.hasExited { run.connection.signal(SIGKILL) }
    }

    // MARK: Approvals

    /// The folder of the chat's project: where its CLI runs, and where its file tools may work without asking. A
    /// ticket chat a bundle's chat started works in its worktree while it has it (docs/data.md › Implement chats).
    public func root(ofChat chatID: String) -> String? {
        guard let chat = chats[chatID], let root = projects.snapshot.project(chat.projectID)?.root else { return nil }
        return worktreeFolder(of: chat, projectRoot: root) ?? root
    }

    /// The user's answer to a card: the CLI's request, or the app's own.
    public func answer(_ chatID: String, requestID: String, allow: Bool) {
        answer(chatID, requestID: requestID, decision: allow ? .allow : .deny)
    }

    /// Answers a card, as V2's: Allow, Always Allow (for the CLI's request, its suggestions become its rules; for
    /// the app's own, it allows), or Don't Allow with an optional `message`, which Claude reads as the call's
    /// error (`Permission denied by the user.` without one).
    public func answer(_ chatID: String, requestID: String, decision: PermissionRequestItem.Decision, message: String? = nil) {
        let allow = decision != .deny
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = trimmed.isEmpty ? "Permission denied by the user." : trimmed
        if let run = runs[chatID], let input = run.cliPermissions.removeValue(forKey: requestID) {
            let suggestions = run.cliSuggestions.removeValue(forKey: requestID)
            run.connection.write(allow ? ClaudeInput.allow(requestID, input: input, permissions: decision == .allowAlways ? suggestions : nil)
                                       : ClaudeInput.deny(requestID, message: note))
            if decision == .allowAlways {
                // A suggestion that sets a mode changes the CLI's: the chat follows it, as V2's did.
                for entry in suggestions?.arrayValue ?? [] where entry["type"]?.stringValue == "setMode" {
                    if let mode = entry["mode"]?.stringValue { followCLIPermissionMode(mode, in: chatID) }
                }
            }
        } else if let continuation = approvals[chatID]?.removeValue(forKey: requestID) {
            continuation.resume(returning: allow ? .allowed : .refused)
        } else {
            return
        }
        decide(chatID, requestID: requestID, decision: decision, by: device)
        refreshState(chatID)
    }

    /// The pending cards a new mode allows, approved as if the mode had come first, as V2 did: every one under
    /// Allow All; a file edit inside the project's folder under Accept Edits.
    func approvePending(in chatID: String, for mode: ChatPermissionMode) {
        guard let run = runs[chatID], ChatPermissionMode(stored: chats[chatID]?.file.settings.permissionMode ?? "") == mode else { return }
        for (requestID, input) in run.cliPermissions {
            guard case .permissionRequest(let request)? = item("perm-\(requestID)", in: chatID) else { continue }
            let allowed: Bool = switch mode {
            case .bypassPermissions: true
            case .acceptEdits:
                ClaudeFileTools.editing.contains(request.toolName) && Self.isInside(request.toolName, input: input, root: root(ofChat: chatID))
            default: false
            }
            if allowed { answer(chatID, requestID: requestID, decision: .allow) }
        }
        if mode == .bypassPermissions {
            for requestID in Array((approvals[chatID] ?? [:]).keys) { answer(chatID, requestID: requestID, decision: .allow) }
        }
    }

    /// Whether a file tool's path lies in the project's folder `root`.
    static func isInside(_ tool: String, input: JSONValue, root: String?) -> Bool {
        guard let root, let path = ClaudeFileTools.path(tool: tool, input: input, root: root) else { return false }
        return ClaudeFileTools.location(path, in: root) == .inside
    }

    /// The edits Claude may make in the chat: Settings ▸ Chat's, Always under Accept Edits unless it is Never.
    func fileEdits(forChat chatID: String) -> ChatFileEdits {
        let setting = fileEdits()
        let mode = ChatPermissionMode(stored: chats[chatID]?.file.settings.permissionMode ?? "")
        return setting != .never && (mode == .acceptEdits || mode == .bypassPermissions) ? .always : setting
    }

    /// Asks the user about a call of the app's tool `name` with `input`, from the chat's Claude: a card in the
    /// chat, answered with Allow or Don't Allow. Refused when the chat has no process, and when the request is
    /// cancelled (Stop, the process's end, quitting); expired when no one answered in `approvalLimit`.
    public func requestApproval(_ chatID: String, tool name: String, input: JSONValue) async -> ApprovalAnswer {
        guard runs[chatID] != nil else { return .refused }
        let request = PermissionRequestItem(requestID: UUID().uuidString.lowercased(), created: now(),
                                            toolName: "mcp__\(MCPProtocol.serverName)__\(name)", input: input)
        record(.permissionRequest(request), in: chatID)
        let limit = approvalLimit
        return await withCheckedContinuation { continuation in
            approvals[chatID, default: [:]][request.requestID] = continuation
            refreshState(chatID)
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.expireApproval(chatID, requestID: request.requestID)
            }
        }
    }

    func cancelApprovals(of chatID: String, by device: String?) {
        for (id, continuation) in approvals[chatID] ?? [:] {
            continuation.resume(returning: .refused)
            decide(chatID, requestID: id, decision: .deny, by: device)
        }
        approvals[chatID] = nil
    }

    /// A card still waiting after `approvalLimit`: the app withdraws it as it does on Stop, so that it can't be
    /// answered once the CLI has given up on the call (docs/mcp.md › Permissions).
    func expireApproval(_ chatID: String, requestID: String) {
        guard let continuation = approvals[chatID]?.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: .expired)
        decide(chatID, requestID: requestID, decision: .deny, by: nil)
        refreshState(chatID)
    }

    /// Records the decision of a permission request in its item.
    private func decide(_ chatID: String, requestID: String, decision: PermissionRequestItem.Decision, by device: String?) {
        let id = "perm-\(requestID)"
        guard case .permissionRequest(var request)? = item(id, in: chatID) ?? pendingItem(id, in: chatID) else { return }
        request.decision = decision
        request.decidedBy = device
        record(.permissionRequest(request), in: chatID, op: .update)
    }

    /// A permission item of a transcript that isn't in memory: read from its file.
    private func pendingItem(_ id: String, in chatID: String) -> ChatItem? {
        guard transcripts[chatID] == nil, let url = transcriptURL(chatID) else { return nil }
        return Transcript.replay((try? Data(contentsOf: url)) ?? Data()).first { $0.id == id }
    }

    /// The CLI changed its permission mode itself: the chat's setting follows, without telling the CLI back, so
    /// the menus show it, the app's tools obey it and the next process starts in it (docs/data.md › Chat
    /// settings). An unknown mode is ignored.
    func followCLIPermissionMode(_ value: String, in chatID: String) {
        guard let mode = value == "default" ? .manual : ChatPermissionMode(rawValue: value),
              let chat = chats[chatID], chat.file.settings.permissionMode != mode.rawValue else { return }
        change(chatID) { $0.settings.permissionMode = mode.rawValue }
    }

    // MARK: Settings

    /// Changes the chat's model and effort; a running process takes them at once, when the CLI accepts.
    public func setSettings(_ chatID: String, model: String, effort: Effort) throws(ChatError) {
        guard var settings = chats[chatID]?.file.settings else { throw .notFound("Chat \(chatID) not found.") }
        settings.model = model
        settings.effort = effort
        try setSettings(chatID, settings)
    }

    /// Changes the chat's settings, as V2's composer menus did: a running process takes the model, the effort, the
    /// permission mode and Ultracode at once, when the CLI accepts; a new context window ends it once no turn
    /// runs, so that the next message resumes with it.
    public func setSettings(_ chatID: String, _ settings: ChatSettings) throws(ChatError) {
        guard let chat = chats[chatID] else { throw .notFound("Chat \(chatID) not found.") }
        guard ChatSettings.isModel(settings.model) else { throw .invalid("model: use a model of the list.") }
        guard ChatPermissionMode(rawValue: settings.permissionMode) != nil else { throw .invalid("permissionMode: use a mode of the list.") }
        guard ChatContextWindow(rawValue: settings.contextWindow) != nil else { throw .invalid("contextWindow: use auto, 200k or 1m.") }
        let old = chat.file.settings
        let model = settings.model
        let effort = settings.effort
        change(chatID) {
            $0.settings.model = settings.model
            $0.settings.effort = settings.effort
            $0.settings.permissionMode = settings.permissionMode
            $0.settings.ultracode = settings.ultracode
            $0.settings.contextWindow = settings.contextWindow
        }
        guard let run = runs[chatID] else { return }
        if old.permissionMode != settings.permissionMode {
            let id = run.controlID()
            let mode = ChatPermissionMode(stored: settings.permissionMode)
            run.modeRequests[id] = mode
            run.connection.write(ClaudeInput.control(id, ["subtype": "set_permission_mode", "mode": .string(mode.cliValue)]))
            expectAnswer(id, of: run)
        }
        if old.ultracode != settings.ultracode {
            let id = run.controlID()
            run.settingsRequests[id] = "Ultracode"
            run.connection.write(ClaudeInput.control(id, ["subtype": "apply_flag_settings", "settings": ["ultracode": .bool(settings.ultracode)]]))
            expectAnswer(id, of: run)
        }
        // A new context window waits for the turn and for the background work, as docs/data.md says.
        if ChatContextWindow(stored: settings.contextWindow) != run.contextWindow, !run.inTurn, !run.hasBackgroundWork {
            run.end(closingInput: true, grace: Self.signalGrace)
        }
        if old.model != model {
            let id = run.controlID()
            run.settingsRequests[id] = "model"
            run.connection.write(ClaudeInput.control(id, ["subtype": "set_model", "model": .string(model)]))
            expectAnswer(id, of: run)
        }
        if old.effort != effort {
            let id = run.controlID()
            run.settingsRequests[id] = "effort"
            run.mapper.effort = effort
            run.connection.write(ClaudeInput.control(id, ["subtype": "apply_flag_settings", "settings": ["effortLevel": .string(effort.rawValue)]]))
            expectAnswer(id, of: run)
        }
    }

    /// A settings, mode or Stop Workflow request the CLI hasn't answered in `controlAnswerLimit` is forgotten, with
    /// the warning its refusal adds and `no answer`, as V2 did; an answer coming later is ignored.
    /// The line a process's first `system/init` adds, as V2's did: `Session started · <model name> · effort <effort> ·
    /// <mode label>`, then ` · Ultracode` when on. The chat's settings stand for what the line lacks.
    nonisolated static func sessionStartText(model: String?, mode: String?, settings: ChatSettings, models: [ClaudeModel]) -> String {
        let cliMode = mode ?? ChatPermissionMode(stored: settings.permissionMode).cliValue
        var text = "Session started · \(ClaudeModel.name(of: model ?? settings.model, in: models)) · effort \(settings.effort.rawValue)"
            + " · \(ChatPermissionMode.systemLineLabel(cliMode))"
        if settings.ultracode { text += " · Ultracode" }
        return text
    }

    func expectAnswer(_ requestID: String, of run: ChatRun) {
        let limit = controlAnswerLimit
        Task { [weak self, weak run] in
            try? await Task.sleep(for: limit)
            guard let self, let run, self.runs[run.chatID] === run else { return }
            if run.modeRequests.removeValue(forKey: requestID) != nil {
                self.record(.system(SystemItem(created: self.now(), text: "Claude did not accept the new permission mode now: no answer. It applies the next time Claude starts.",
                                               level: .warning)), in: run.chatID)
            } else if let setting = run.settingsRequests.removeValue(forKey: requestID) {
                self.record(.system(SystemItem(created: self.now(), text: "Claude did not accept the new \(setting) now: no answer. It applies the next time Claude starts.",
                                               level: .warning)), in: run.chatID)
            } else if run.stopRequests[requestID] != nil {
                _ = self.stopAnswered(requestID, success: false, error: nil, run: run)
            }
        }
    }

    /// Renames a chat: one line, 1 to 100 characters.
    public func rename(_ chatID: String, to title: String) throws(ChatError) {
        guard let chat = chats[chatID] else { throw .notFound("Chat \(chatID) not found.") }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(trimmed.count), !trimmed.contains(where: \.isNewline) else {
            throw .invalid("title: use 1 to 100 characters on one line.")
        }
        var file = chat.file
        file.title = trimmed
        file.updated = now()
        try write(file, projectID: chat.projectID)
    }

    // MARK: Result images

    /// Writes a tool result's images into the chat's folder, `<UUID>-image-<n>.<extension>` from 1, and lists
    /// them on its item, as V2 did: the transcript shows them. An image that can't be written is left out.
    /// Writes a result's images beside the chat, off the main actor (a screenshot is megabytes), then records them on
    /// the result.
    func storeResultImages(_ images: [ResultImage], of toolUseID: String, in chatID: String) async {
        guard let folder = folder(of: chatID)?.chatsFolder.appendingPathComponent(chatID, isDirectory: true),
              case .toolResult? = item("\(toolUseID)#result", in: chatID) else { return }
        let files = await Task.detached(priority: .userInitiated) { () -> [MessageAttachment] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [MessageAttachment] = []
            for (index, image) in images.enumerated() {
                let fileID = UUID().uuidString
                let name = "image-\(index + 1).\(image.fileExtension)"
                guard (try? image.data.write(to: folder.appendingPathComponent("\(fileID)-\(name)"), options: .atomic)) != nil else { continue }
                var file = MessageAttachment.stored(id: fileID, name: name, chatID: chatID, size: image.data.count)
                file.contentType = image.mediaType
                files.append(file)
            }
            return files
        }.value
        // The result as it is now: it may have been updated meanwhile.
        guard !files.isEmpty, case .toolResult(var result)? = item("\(toolUseID)#result", in: chatID) else { return }
        result.images = .array(files.map(\.json))
        record(.toolResult(result), in: chatID, op: .update)
    }

    // MARK: Models

    /// Reads the CLI's models and commands: a process without session, tools or MCP servers that only answers
    /// `initialize`, with the chats' plugin, so that its commands are those of a chat outside any project.
    func probeModels() async {
        guard let path = status.path, let dataFolder = projects.dataFolder else { return }
        let folder = dataFolder.url.appendingPathComponent("Runtime/claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                         "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        if let plugin = try? dataFolder.writeChatPlugin() {
            arguments += ["--plugin-dir", plugin.path]
        }
        let request = ProcessRequest(executable: path, arguments: arguments, environment: ShellEnvironment.forChildren(projects.tools.environment),
                                     currentDirectory: folder.path, standardInput: .pipe, standardOutput: .pipe, standardError: .null)
        guard let connection = try? launcher.launch(request, log: nil, logLine: "") else { return }
        connection.write(ClaudeInput.control("hephaestus-models", ["subtype": "initialize"]))
        let reader = Task { () -> (models: [ClaudeModel]?, commands: [ClaudeCommand]?)? in
            for await line in connection.lines {
                guard let value = try? JSONValue.parse(line), value["type"]?.stringValue == "control_response",
                      value["response"]?["request_id"]?.stringValue == "hephaestus-models" else { continue }
                let answer = value["response"]?["response"]
                return (ClaudeModel.list(answer?["models"]), ClaudeCommand.list(answer?["commands"]))
            }
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            reader.cancel()
        }
        let answer = await reader.value
        timeout.cancel()
        connection.closeInput()
        connection.signal(SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !connection.hasExited { connection.signal(SIGKILL) }
        }
        if let list = answer?.models, list != models { models = list }
        if let list = answer?.commands.map(markingSynced), list != commands { commands = list }
    }
}

/// A message as written to the CLI: its text, with the items' lines, and the images before it.
struct OutgoingMessage {
    var text: String
    var images: [ClaudeImage] = []
}

/// How a card of the app ended: allowed, refused (Don't Allow, Stop, the process's end, quitting), or withdrawn
/// by the app because no one answered in time.
public enum ApprovalAnswer: Sendable, Hashable {
    case allowed, refused, expired
}
