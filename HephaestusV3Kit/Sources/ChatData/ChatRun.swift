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
    var nextControl = 1
    var initializeID = ""
    /// The app's settings requests, by request id: `model` or `effort`.
    var settingsRequests: [String: String] = [:]
    var startTimer: Task<Void, Never>?
    var idleTimer: Task<Void, Never>?
    var stopTimer: Task<Void, Never>?

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
    /// them.
    @discardableResult
    public func send(_ text: String, references: [ChatItemReference], to chatID: String?, projectID: String,
                     origin: String? = nil, title: String? = nil, images: [ClaudeImage] = []) async throws(ChatError) -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw .invalid("text: write a message.") }
        let cli = try await availableCLI()
        let id: String
        if let chatID {
            guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
            id = chatID
            await open(id)
        } else {
            id = try makeChat(projectID: projectID, title: title ?? message, settings: defaults, origin: origin)
        }
        post(message, references: references, images: images, to: id, cli: cli)
        return id
    }

    /// Writes a new chat's file, of `kind`, with the first line of `title`, and lists it.
    func makeChat(_ id: String = ChatIDs.make(), projectID: String, title: String, kind: ChatFile.Kind = .project, settings: ChatSettings,
                  origin: String? = nil) throws(ChatError) -> String {
        guard let project = projects.snapshot.project(projectID) else { throw .notFound("Project \(projectID) not found.") }
        let file = ChatFile(id: id, title: Self.title(of: title), kind: kind, created: now(), settings: settings, origin: origin)
        try? ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true)).ensureGitignore()
        try write(file, projectID: projectID)
        transcripts[id] = []
        touch(id)
        return id
    }

    /// Records the user's message in the chat, then writes it to the chat's process, starting one when none
    /// runs.
    func post(_ message: String, references: [ChatItemReference], images: [ClaudeImage], to id: String, cli: String) {
        let item = UserItem(created: now(), text: message, sender: device, references: references)
        record(.user(item), in: id)
        change(id) {
            $0.updated = item.created
            $0.closed = false
        }
        failed.remove(id)
        let line = OutgoingMessage(text: ClaudeInput.text(message, carrying: references), images: images)
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
        let launch = ChatLaunch(cliPath: cli, chatID: chatID, resume: chat.file.sessionStarted, model: chat.file.settings.model,
                                effort: chat.file.settings.effort, mcpConfig: config, tools: toolNames, workingDirectory: project.root,
                                environment: projects.tools.environment, pluginDir: plugin)
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
        Task { [weak self] in
            for await line in connection.lines {
                self?.handle(line, of: run)
            }
            let termination = await connection.waitForExit()
            self?.exited(run, termination)
        }
        refreshState(chatID)
    }

    // MARK: Output

    func handle(_ line: Data, of run: ChatRun) {
        let chatID = run.chatID
        guard runs[chatID] === run else { return }
        for output in run.mapper.map(line) {
            switch output {
            case .item(let item):
                if streaming[chatID]?.itemID == item.id { streaming[chatID] = nil }
                record(item, in: chatID, op: self.item(item.id, in: chatID) == nil ? .add : .update)
            case .delta(let itemID, let text):
                if streaming[chatID]?.itemID == itemID {
                    streaming[chatID]?.text += text
                } else {
                    streaming[chatID] = StreamingText(itemID: itemID, text: text)
                }
            case .cliTurnOpened(let first, let problem):
                run.cliTurnOpen = true
                run.inTurn = true
                run.idleTimer?.cancel()
                if first {
                    run.initialized = true
                    run.startTimer?.cancel()
                    if chats[chatID]?.file.sessionStarted == false { change(chatID) { $0.sessionStarted = true } }
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
            case .permissionRequest(let request):
                run.cliPermissions[request.requestID] = request.input
                record(.permissionRequest(request), in: chatID)
            case .unsupportedControlRequest(let id, let subtype):
                run.connection.write(ClaudeInput.unsupported(id, subtype: subtype))
            case .controlResponse(let id, let success, let response, let error):
                if id == run.initializeID, success, let list = ClaudeModel.list(response?["models"]) {
                    if models != list { models = list }
                } else if let setting = run.settingsRequests.removeValue(forKey: id), !success {
                    record(.system(SystemItem(created: now(), text: "Claude did not accept the new \(setting) now: \(error ?? "no reason"). It applies the next time Claude starts.",
                                              level: .warning)), in: chatID)
                }
            case .cancelRequest(let id):
                guard run.cliPermissions.removeValue(forKey: id) != nil else { break }
                decide(chatID, requestID: id, decision: .deny, by: nil)
            case .result(let result):
                record(.result(result), in: chatID)
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
            case .ignored, .invalid:
                break
            }
        }
        refreshState(chatID)
    }

    /// Ends the turn once nothing written is outstanding and no CLI turn is open; the idle timer starts.
    private func endTurnIfDone(_ run: ChatRun) {
        guard run.inTurn, run.outstanding.isEmpty, !run.cliTurnOpen else { return }
        run.inTurn = false
        change(run.chatID) { $0.updated = now() }
        run.idleTimer?.cancel()
        run.idleTimer = Task { [weak self, weak run] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, let run, self.runs[run.chatID] === run, !run.inTurn else { return }
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

    /// The user's answer to a card: the CLI's request, or the app's own.
    public func answer(_ chatID: String, requestID: String, allow: Bool) {
        if let run = runs[chatID], let input = run.cliPermissions.removeValue(forKey: requestID) {
            run.connection.write(allow ? ClaudeInput.allow(requestID, input: input)
                                       : ClaudeInput.deny(requestID, message: "Permission denied by the user."))
        } else if let continuation = approvals[chatID]?.removeValue(forKey: requestID) {
            continuation.resume(returning: allow)
        } else {
            return
        }
        decide(chatID, requestID: requestID, decision: allow ? .allow : .deny, by: device)
        refreshState(chatID)
    }

    /// Asks the user about a call of the app's tool `name` with `input`, from the chat's Claude: a card in the
    /// chat, answered with Allow or Don't Allow. False when the chat has no process, and when the request is
    /// cancelled (Stop, the process's end, quitting).
    public func requestApproval(_ chatID: String, tool name: String, input: JSONValue) async -> Bool {
        guard runs[chatID] != nil else { return false }
        let request = PermissionRequestItem(requestID: UUID().uuidString.lowercased(), created: now(),
                                            toolName: "mcp__\(MCPProtocol.serverName)__\(name)", input: input)
        record(.permissionRequest(request), in: chatID)
        return await withCheckedContinuation { continuation in
            approvals[chatID, default: [:]][request.requestID] = continuation
            refreshState(chatID)
        }
    }

    private func cancelApprovals(of chatID: String, by device: String?) {
        for (id, continuation) in approvals[chatID] ?? [:] {
            continuation.resume(returning: false)
            decide(chatID, requestID: id, decision: .deny, by: device)
        }
        approvals[chatID] = nil
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

    // MARK: Settings

    /// Changes the chat's model and effort; a running process takes them at once, when the CLI accepts.
    public func setSettings(_ chatID: String, model: String, effort: Effort) throws(ChatError) {
        guard let chat = chats[chatID] else { throw .notFound("Chat \(chatID) not found.") }
        guard ChatSettings.isModel(model) else { throw .invalid("model: use a model of the list.") }
        let old = chat.file.settings
        change(chatID) {
            $0.settings.model = model
            $0.settings.effort = effort
        }
        guard let run = runs[chatID] else { return }
        if old.model != model {
            let id = run.controlID()
            run.settingsRequests[id] = "model"
            run.connection.write(ClaudeInput.control(id, ["subtype": "set_model", "model": .string(model)]))
        }
        if old.effort != effort {
            let id = run.controlID()
            run.settingsRequests[id] = "effort"
            run.mapper.effort = effort
            run.connection.write(ClaudeInput.control(id, ["subtype": "apply_flag_settings", "settings": ["effortLevel": .string(effort.rawValue)]]))
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

    // MARK: Models

    /// Reads the CLI's models: a process without session, tools or MCP servers that only answers `initialize`.
    func probeModels() async {
        guard let path = status.path, let dataFolder = projects.dataFolder else { return }
        let folder = dataFolder.url.appendingPathComponent("Runtime/claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                         "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        let request = ProcessRequest(executable: path, arguments: arguments, environment: ShellEnvironment.forChildren(projects.tools.environment),
                                     currentDirectory: folder.path, standardInput: .pipe, standardOutput: .pipe, standardError: .null)
        guard let connection = try? launcher.launch(request, log: nil, logLine: "") else { return }
        connection.write(ClaudeInput.control("hephaestus-models", ["subtype": "initialize"]))
        let reader = Task {
            for await line in connection.lines {
                guard let value = try? JSONValue.parse(line), value["type"]?.stringValue == "control_response",
                      value["response"]?["request_id"]?.stringValue == "hephaestus-models" else { continue }
                return ClaudeModel.list(value["response"]?["response"]?["models"])
            }
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            reader.cancel()
        }
        let list = await reader.value
        timeout.cancel()
        connection.closeInput()
        connection.signal(SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !connection.hasExited { connection.signal(SIGKILL) }
        }
        if let list, list != models { models = list }
    }
}

/// A message as written to the CLI: its text, with the items' lines, and the images before it.
struct OutgoingMessage {
    var text: String
    var images: [ClaudeImage] = []
}
