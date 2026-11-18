import ExternalTools
import FileStorage
import Foundation
import MCPKit
import Observation
import ProjectData

/// A chat as the app knows it: its file, in a project's `.hephaestus/chats/`.
public struct LoadedChat: Sendable, Hashable, Identifiable {
    public var file: ChatFile
    public var projectID: String

    public var id: String { file.id }
}

/// What a chat is doing (docs/ui/chat.md › States).
public enum ChatState: Sendable, Hashable {
    /// No turn: Claude answered, or was never asked.
    case idle
    /// The CLI was started and hasn't begun the turn yet.
    case starting
    /// Claude works on the messages.
    case running
    /// A card waits for the user's answer.
    case waitingPermission
    /// No turn, and questions or a picker request wait for the user's answers.
    case waitingAnswers
    /// The CLI failed: the transcript says why. The next message tries again.
    case error

    /// Starting, running or waiting: Stop applies.
    public var isRunning: Bool { self == .starting || self == .running || self == .waitingPermission }
}

/// Why a chat change failed.
public enum ChatError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The CLI can't run: the message says why.
    case unavailable(String)
    case notFound(String)
    case invalid(String)
    /// The chat already waits for the user's answers.
    case conflict(String)
    case storage(StorageError)

    public var description: String {
        switch self {
        case .unavailable(let message), .notFound(let message), .invalid(let message), .conflict(let message): message
        case .storage(let error): error.description
        }
    }
}

/// Text streaming into a chat: the block that will become the item `itemID`.
public struct StreamingText: Sendable, Hashable {
    public var itemID: String
    public var text: String

    public init(itemID: String, text: String) {
        self.itemID = itemID
        self.text = text
    }
}

/// The chats as the windows see them, and their Claude processes (docs/architecture.md › ChatData). One session
/// serves the whole app: the Chat windows and panels, and the MCP tools of chats.
@MainActor @Observable
public final class ChatSession {
    /// Every chat of the loaded projects, by id.
    public internal(set) var chats: [String: LoadedChat] = [:]
    public internal(set) var isLoaded = false
    public internal(set) var status = ClaudeStatus.checking
    /// The CLI's models, from its last `initialize` answer; the fallback list until one came.
    public internal(set) var models = ClaudeModel.fallback
    /// The CLI's commands from the probe, which runs outside any project with the chats' plugin: the user's
    /// skills, the plugins' and the app's own. Empty until it answers.
    public internal(set) var commands: [ClaudeCommand] = []
    /// The commands of each project's chats, by project id, from the last chat process of the project that
    /// answered `initialize`: the probe's and the project's own skills.
    public internal(set) var projectCommands: [String: [ClaudeCommand]] = [:]
    /// The transcripts read, by chat id: those of chats open in a window, and of chats that run.
    public internal(set) var transcripts: [String: [ChatItem]] = [:]
    /// The text Claude is writing, by chat id.
    public internal(set) var streaming: [String: StreamingText] = [:]
    public internal(set) var states: [String: ChatState] = [:]
    /// The chats whose process has background work running: a task, or the turn that will report one
    /// (docs/data.md › Background work). The chat's state doesn't change for it.
    public internal(set) var backgroundWork: Set<String> = []
    /// Each chat's workflows and agents, once read (docs/data.md › Agents).
    public internal(set) var agentRecords: [String: ChatAgents] = [:]
    /// The workflow agents' transcripts read.
    public internal(set) var agentTranscripts: [String: [ChatItem]] = [:]
    /// The folders of the workflows launched, and their readers.
    @ObservationIgnored var workflowFolders: [String: (chatID: String, folder: URL)] = [:]
    @ObservationIgnored var workflowReaders: [String: WorkflowFolderReader] = [:]
    /// The ticket and bundle ids each chat mentions (docs/data.md › Mentioned ids).
    public internal(set) var mentions: [String: Set<String>] = [:]
    /// The chats whose transcript was read for their ids, and the scan that reads them.
    @ObservationIgnored var mentionsScanned: Set<String> = []
    @ObservationIgnored var mentionScan: Task<Void, Never>?
    @ObservationIgnored var mentionRescan = false
    /// When the turn began, by chat id, for the status line's time.
    public internal(set) var turnStarts: [String: Date] = [:]
    /// The chats whose conversation the CLI is compacting.
    public internal(set) var compacting: Set<String> = []
    /// The model and effort of new chats.
    public internal(set) var defaults = ChatSettings()
    /// The path set in Settings ▸ Chat; nil finds the CLI.
    public internal(set) var claudePath: String?

    /// The Mac's name, recorded with the user's answers.
    public let device: String
    /// The SF Symbols, sounds and fonts that picker requests check and the cards search.
    public let catalogs: PickerCatalogs
    @ObservationIgnored let projects: ProjectSession
    @ObservationIgnored let launcher: any ClaudeLaunching
    @ObservationIgnored let runner: any ProcessRunning
    @ObservationIgnored let tokens: MCPTokens
    @ObservationIgnored let processEnvironment: [String: String]
    /// Called with each chat event, for the app's notifications (docs/data.md › Chat events).
    @ObservationIgnored public var onEvent: (@MainActor (ChatEvent) -> Void)?
    /// Called when a window shows a chat: its notification goes.
    @ObservationIgnored public var onOpen: (@MainActor (String) -> Void)?
    /// The summaries running, and those waiting their turn.
    @ObservationIgnored var summaryRuns = 0
    @ObservationIgnored var summaryWaiters: [CheckedContinuation<Void, Never>] = []
    /// The chat each view of the key window shows, by view: no notification for them.
    @ObservationIgnored var keyViews: [UUID: String] = [:]
    /// Where a deleted chat's files go.
    @ObservationIgnored let trash: Trash
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored let ownWrites = OwnWrites()
    /// Settings ▸ Chat › Edit the project's files, read when a process starts and when its CLI asks before an
    /// edit; Ask First until the app sets it.
    @ObservationIgnored public var fileEdits: @MainActor () -> ChatFileEdits = { .askFirst }
    /// The app's MCP tools, which a chat's Claude may call, and the server's port.
    @ObservationIgnored var toolNames: [String] = []
    @ObservationIgnored var port = SettingsFile.defaultMCPPort
    @ObservationIgnored var runs: [String: ChatRun] = [:]
    /// The app's own approvals, waiting for the user, by chat then request id.
    @ObservationIgnored var approvals: [String: [String: CheckedContinuation<Bool, Never>]] = [:]
    /// The chats whose CLI failed, until their next message.
    @ObservationIgnored var failed: Set<String> = []
    /// The transcripts appended to since launch, which got their LF check.
    @ObservationIgnored var appended: Set<String> = []
    /// The chats whose transcript was read, latest last: the oldest are dropped past `keptTranscripts`.
    @ObservationIgnored var recent: [String] = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// The transcripts kept in memory at most, besides those of running chats.
    static let keptTranscripts = 12
    /// A process that hasn't begun its turn after this is ended.
    static let startTimeout: Duration = .seconds(60)
    /// A process without a turn this long is ended.
    static let idleTimeout: Duration = .seconds(20 * 60)
    /// The pause between the steps of Stop and of an ending process.
    static let signalGrace: Duration = .seconds(5)

    public init(projects: ProjectSession, tokens: MCPTokens, launcher: any ClaudeLaunching = SystemClaudeLauncher(),
                runner: any ProcessRunning = SystemProcessRunner.shared, device: String,
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment, trash: Trash = .system,
                catalogs: PickerCatalogs.Sources? = nil, now: @escaping @Sendable () -> Date = { ISODate.now() }) {
        self.catalogs = PickerCatalogs(sources: catalogs ?? .system(runner: runner, environment: processEnvironment))
        self.projects = projects
        self.tokens = tokens
        self.launcher = launcher
        self.runner = runner
        self.device = device
        self.processEnvironment = processEnvironment
        self.trash = trash
        self.now = now
    }

    // MARK: Starting

    /// Starts once the projects and the tools are loaded: reads the chats of every project, follows the
    /// projects and the chat files changed outside the app, and checks the CLI. `tools` are the MCP tools
    /// a chat's Claude may call, on `port`.
    public func start(tools: [String], port: Int) async {
        guard !isLoaded else { return }
        toolNames = tools
        self.port = port
        let settings = projects.dataFolder?.readSettings() ?? SettingsFile()
        claudePath = settings.claudePath
        defaults = ChatSettings(model: settings.chatModel.flatMap { ChatSettings.isModel($0) ? $0 : nil } ?? ChatSettings.defaultModel,
                                effort: settings.chatEffort.flatMap(Effort.init(rawValue:)) ?? .high)
        reload()
        isLoaded = true
        projects.observeFileEvents { [weak self] batch in
            self?.handle(batch)
        }
        let projects = projects
        Task { [weak self] in
            for await _ in Observations({ projects.snapshot }) {
                guard let self else { return }
                self.reload()
            }
        }
        checkCLI()
    }

    /// The MCP port changed: later launches use it.
    public func setPort(_ port: Int) {
        self.port = port
    }

    /// Locates the CLI again and reads its version and models.
    public func checkCLI() {
        statusTask?.cancel()
        status = .checking
        let setting = claudePath
        statusTask = Task { [weak self] in
            guard let self else { return }
            let found = await ClaudeCLI.status(setting: setting, processEnvironment: processEnvironment,
                                               environment: projects.tools.environment, runner: runner)
            guard !Task.isCancelled else { return }
            status = found
            if found.isAvailable { await probeModels() }
        }
    }

    /// Waits for the CLI check, at most 20 s.
    func availableCLI() async throws(ChatError) -> String {
        if status.checking, let statusTask {
            let deadline = Task { try? await Task.sleep(for: .seconds(20)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await statusTask.value }
                group.addTask { await deadline.value }
                await group.next()
                group.cancelAll()
            }
            deadline.cancel()
        }
        if status.checking { throw .unavailable("The Claude CLI isn't checked yet. Try again in a moment.") }
        guard let path = status.path, status.isAvailable else {
            throw .unavailable(status.error ?? "The Claude CLI isn't available.")
        }
        return path
    }

    /// Sets the CLI's path (empty finds it) and checks it again.
    public func setClaudePath(_ path: String?) throws(ChatError) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try writeSettings { $0.claudePath = value }
        claudePath = value
        checkCLI()
    }

    /// Sets the model and effort of new chats.
    public func setDefaults(model: String, effort: Effort) throws(ChatError) {
        guard ChatSettings.isModel(model) else { throw .invalid("model: use a model of the list.") }
        try writeSettings {
            $0.chatModel = model == ChatSettings.defaultModel ? nil : model
            $0.chatEffort = effort == .high ? nil : effort.rawValue
        }
        defaults = ChatSettings(model: model, effort: effort)
    }

    private func writeSettings(_ change: (inout SettingsFile) -> Void) throws(ChatError) {
        guard let folder = projects.dataFolder else { throw .unavailable("The app has no data folder.") }
        var settings = folder.readSettings()
        change(&settings)
        do throws(StorageError) {
            try folder.writeSettings(settings)
        } catch {
            throw .storage(error)
        }
    }

    // MARK: Reading

    /// The chats of these projects, the latest first.
    public func chats(of projectIDs: Set<String>) -> [LoadedChat] {
        chats.values.filter { projectIDs.contains($0.projectID) }.sorted { $0.file.updated > $1.file.updated }
    }

    /// The commands a chat of the project can run: its chats' last list, else the probe's.
    public func commands(forProject projectID: String) -> [ClaudeCommand] {
        projectCommands[projectID] ?? commands
    }

    /// `list` with the skills of the plugins the CLI syncs from claude.ai marked synced: those in the CLI's folder
    /// (`CLAUDE_CONFIG_DIR`, else `~/.claude`) of the app's environment; none without either.
    func markingSynced(_ list: [ClaudeCommand]) -> [ClaudeCommand] {
        let folder = processEnvironment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? processEnvironment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(".claude", isDirectory: true) }
        guard let folder else { return list }
        return ClaudeCommand.marking(list, syncedPlugins: ClaudeCommand.syncedPlugins(claudeFolder: folder))
    }

    public func state(of chatID: String) -> ChatState {
        states[chatID] ?? .idle
    }

    /// Reads the chat's transcript, once, so that `transcripts` has it. A request left waiting by a process that
    /// is gone is cancelled.
    public func open(_ chatID: String) async {
        touch(chatID)
        onOpen?(chatID)
        guard transcripts[chatID] == nil, let url = transcriptURL(chatID) else { return }
        let items = await Task.detached { Transcript.replay((try? Data(contentsOf: url)) ?? Data()) }.value
        guard transcripts[chatID] == nil else { return }
        transcripts[chatID] = items
        if runs[chatID] == nil {
            for case .permissionRequest(var request) in items where request.isPending {
                request.decision = .deny
                record(.permissionRequest(request), in: chatID, op: .update)
            }
        }
    }

    // MARK: Files

    func folder(of chatID: String) -> ProjectFolder? {
        guard let chat = chats[chatID], let project = projects.snapshot.project(chat.projectID) else { return nil }
        return ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true))
    }

    func transcriptURL(_ chatID: String) -> URL? {
        folder(of: chatID)?.chatsFolder.appendingPathComponent("\(chatID).jsonl")
    }

    func metadataURL(_ chatID: String) -> URL? {
        folder(of: chatID)?.chatsFolder.appendingPathComponent("\(chatID).yml")
    }

    /// Writes the chat's metadata file.
    func write(_ file: ChatFile, projectID: String) throws(ChatError) {
        guard let project = projects.snapshot.project(projectID) else { throw .notFound("Project \(projectID) not found.") }
        let folder = ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true))
        do throws(StorageError) {
            try YAMLFile.write(file, to: folder.chatsFolder.appendingPathComponent("\(file.id).yml"), ownWrites: ownWrites)
        } catch {
            throw .storage(error)
        }
        chats[file.id] = LoadedChat(file: file, projectID: projectID)
    }

    /// Changes a chat's metadata and writes it; a failed write keeps the change in memory.
    func change(_ chatID: String, _ change: (inout ChatFile) -> Void) {
        guard var chat = chats[chatID] else { return }
        change(&chat.file)
        try? write(chat.file, projectID: chat.projectID)
        chats[chatID] = chat
    }

    /// Adds or replaces an item: in memory when the transcript is read, and as a line of the file.
    func record(_ item: ChatItem, in chatID: String, op: Transcript.Op = .add) {
        if var items = transcripts[chatID] {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
            transcripts[chatID] = items
        }
        noteMentions(of: item, in: chatID)
        guard let url = transcriptURL(chatID) else { return }
        try? Transcript.append(Transcript.line(op, item), to: url, endingLine: appended.insert(chatID).inserted)
    }

    func item(_ id: String, in chatID: String) -> ChatItem? {
        transcripts[chatID]?.first { $0.id == id }
    }

    /// Keeps the chat's transcript, dropping the oldest ones read beyond `keptTranscripts`, except those of
    /// running chats.
    func touch(_ chatID: String) {
        recent.removeAll { $0 == chatID }
        recent.append(chatID)
        while recent.count > Self.keptTranscripts, let oldest = recent.first(where: { runs[$0] == nil && $0 != chatID }) {
            recent.removeAll { $0 == oldest }
            transcripts[oldest] = nil
        }
    }

    /// Reads the chats of every loaded project again: those of a project gone are dropped.
    func reload() {
        var found: [String: LoadedChat] = [:]
        for project in projects.snapshot.projects {
            let folder = ProjectFolder(root: URL(fileURLWithPath: project.root, isDirectory: true))
            for chat in Self.readChats(in: folder.chatsFolder) {
                found[chat.id] = LoadedChat(file: chat, projectID: project.id)
            }
        }
        if found != chats { chats = found }
        dropMentions(keeping: found.keys)
        scanMentions()
    }

    /// The chat files of a `chats/` folder: `<UUID>.yml` names only, an invalid file skipped.
    nonisolated static func readChats(in folder: URL) -> [ChatFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".yml"), ChatIDs.isChatID(String(name.dropLast(4))) else { return nil }
            guard let file = try? YAMLFile.read(ChatFile.self, at: folder.appendingPathComponent(name)),
                  file.id == String(name.dropLast(4)) else { return nil }
            return file
        }
    }

    /// Files changed outside the app: the chats of a project whose `chats/` folder changed are read again.
    func handle(_ events: [FileEvent]) {
        let touched = events.contains { event in
            event.path.contains("/.hephaestus/chats") || event.kind.contains(.mustRescan) || event.kind.contains(.rootChanged)
        }
        if touched { reload() }
    }

    // MARK: State

    func refreshState(_ chatID: String) {
        let state: ChatState
        if failed.contains(chatID) {
            state = .error
        } else if let run = runs[chatID], !run.cliPermissions.isEmpty || !(approvals[chatID] ?? [:]).isEmpty {
            state = .waitingPermission
        } else if let run = runs[chatID], run.inTurn {
            state = run.initialized ? .running : .starting
        } else if waitingQuestions(in: chatID) != nil || waitingPicker(in: chatID) != nil {
            state = .waitingAnswers
        } else {
            state = .idle
        }
        let old = states[chatID]
        if old != state {
            states[chatID] = state
            noticeTransition(chatID, from: old, to: state)
        }
        if state.isRunning {
            if turnStarts[chatID] == nil { turnStarts[chatID] = now() }
        } else if turnStarts[chatID] != nil {
            turnStarts[chatID] = nil
        }
    }
}
