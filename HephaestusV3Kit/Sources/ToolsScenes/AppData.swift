import AppKit
import ChatData
import BuildData
import BuildsKit
import ContractsKit
import ServiceMapKit
import ChatKit
import DashboardsKit
import ExternalTools
import FileStorage
import MachineData
import KafkaData
import KafkaKit
import MachinesKit
import MemoryData
import MCPKit
import Observation
import ProjectData
import ProjectsKit
import TicketData
import TicketsKit
import ToolsFoundation
import UpdateData

/// The app's data, shared by every window: the project session, and the directory the windows read, kept
/// in step with it.
@MainActor @Observable
final class AppData {
    /// The tools the running app offers; the others are hidden in the running app
    /// (docs/ui/navigation.md › Available tools). Previews show every tool.
    static let availableTools: Set<ToolKind> = Set(ToolKind.allCases)
    /// Whether the Virtual Machines window is available.
    static let machinesAvailable = true

    /// The app's one instance: the scenes show it, and the app delegate starts it at launch.
    static let shared = AppData()

    let session: ProjectSession
    let directory = ProjectDirectory(projects: [], state: .loading)
    /// A route's ask to select an internal skill in System Prompts.
    var skillFocus: FocusRequest?
    /// The scope a route asks the Memories tab to show: `global` or a project's id.
    var memoryFocus: FocusRequest?

    /// Where the memories are, for the chats' environment as the login shell gives it (docs/data.md › Memories).
    var memoryLocations: () -> MemoryLocations {
        { [session] in MemoryLocations(environment: session.tools.environment) }
    }
    /// The app's log (docs/data.md › App log), made once the data folder is known.
    @ObservationIgnored private(set) var appLog = AppLog(url: nil)
    /// The project selected in Projects, which is one tab in the whole app; kept for the next launch, as V2 did. Held
    /// here rather than by the scene, so that a selection redraws the views that read it, not every window's root.
    var projectSelection: Project.ID? {
        get { storedProjectSelection }
        set {
            storedProjectSelection = newValue
            UserDefaults.standard.set(newValue, forKey: Self.projectSelectionKey)
        }
    }
    private var storedProjectSelection = UserDefaults.standard.string(forKey: AppData.projectSelectionKey)
    static let projectSelectionKey = "projects.selection"
    /// What every window's views get in their environment, made once: made at each pass of a window's root, they were
    /// new values each time, which redrew every view that reads them.
    @ObservationIgnored private(set) lazy var toolReader = appToolReader(directory: directory, tickets: ticketStore, builds: buildStore,
                                                                          contracts: contractStore, maps: serviceMapStore)
    @ObservationIgnored private(set) lazy var soundPlayer = ChatSounds.player(chats)
    @ObservationIgnored let dashboardWidgetRenderer = DashboardWidgetRenderer { DashboardWidgetView(widget: $0, context: $1) }
    /// The tickets and bundles of the loaded projects, and the store the Tickets windows read.
    let tickets: TicketSession
    let ticketStore: LiveTicketStore
    /// The Dashboards of the loaded projects, kept in their project files.
    let dashboardStore: LiveDashboardStore
    /// The services' namespaces, read with kubectl, gh and Jaeger, and their port forwards.
    let serviceMapStore: LiveServiceMapStore
    /// The projects' OpenAPI contracts, their requests and the values typed for them.
    let contractStore: LiveContractStore
    /// The runs and releases of the projects' GitHub repositories, read with gh.
    let buildStore: LiveBuildStore
    /// The Kafka tool's reads and spies, through kcat (docs/data.md › Kafka).
    let kafkaStore: LiveKafkaStore
    /// The images and virtual machines of the data folder, and the machines that run (docs/architecture.md › MachineData).
    let machineHost: MachineHost
    /// The machines as the Virtual Machines window shows them.
    let machineStore: LiveMachineStore
    /// The chats and their Claude processes (docs/architecture.md › ChatData).
    let chats: ChatSession
    /// The chats as the Chat windows and panels show them.
    let chatStore: LiveChatStore
    /// Claude's answers to the comments that mention it.
    let answerer: CommentAnswerer
    /// The internal skills' content, in the data folder (System Prompts).
    let skillStore: LiveInternalSkillStore
    /// The Updater, its status and the restart for an update (docs/updater.md).
    let updates = UpdateController()
    /// The titling of tickets created without a title, one after the other (`titleUntitled(_:)`).
    @ObservationIgnored private var titling: Task<Void, Never>?
    /// The MCP server's tools, once it starts: the chats word their calls with them.
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private var started = false

    // MARK: MCP server (docs/mcp.md)

    /// The server's state, as Settings ▸ MCP shows it.
    private(set) var mcpState = MCPServer.State.stopped
    /// The token of terminal Claude sessions; nil until the server starts, or when it can't be stored.
    private(set) var externalToken: String?
    /// The port in `settings.yml`.
    private(set) var settingsPort = SettingsFile.defaultMCPPort
    /// `HEPHAESTUS_MCP_PORT`, which replaces the setting while it is set.
    let environmentPort: Int? = ProcessInfo.processInfo.environment["HEPHAESTUS_MCP_PORT"].flatMap(Int.init)
    /// What opens a route, from the first window that appears; `open_in_app` uses it.
    @ObservationIgnored var openRoute: OpenRouteAction?
    @ObservationIgnored private var server: MCPServer?
    @ObservationIgnored private let tokens: MCPTokens

    /// The port the server listens on.
    var mcpPort: Int { environmentPort ?? settingsPort }

    // MARK: Windows (docs/ui/navigation.md › Settings ▸ General)

    /// Whether the windows the app opens become tabs of the frontmost window: `settings.yml`'s `newWindows`,
    /// tabs until it is read.
    private(set) var opensWindowsAsTabs = true {
        didSet { WindowDirectory.shared.opensWindowsAsTabs = opensWindowsAsTabs }
    }

    /// The project that receives feedback chats: `settings.yml`'s `feedbackProjectID`, nil until read.
    private(set) var feedbackProjectID: Project.ID?

    /// The feedback project while it is loaded; nil hides the status bar's ladybug and Help ▸ Send Feedback….
    var feedbackTarget: FeedbackTarget? {
        directory.project(feedbackProjectID).map { FeedbackTarget(project: $0, chats: chatStore) }
    }

    /// Stores the feedback project, nil for none. Throws the storage error when it can't be stored; without a
    /// data folder it holds until the app quits.
    func setFeedbackProject(_ id: Project.ID?) throws(StorageError) {
        if let folder = session.dataFolder {
            var settings = folder.readSettings()
            settings.feedbackProjectID = id
            try folder.writeSettings(settings)
        }
        feedbackProjectID = id
    }

    /// Stores how new windows open. Throws the storage error when it can't be stored; without a data folder it
    /// holds until the app quits.
    func setOpensWindowsAsTabs(_ value: Bool) throws(StorageError) {
        if let folder = session.dataFolder {
            var settings = folder.readSettings()
            settings.opensWindowsAsTabs = value
            try folder.writeSettings(settings)
        }
        opensWindowsAsTabs = value
    }

    // MARK: Mentioned In (docs/ui/tickets.md › Mentioned In)

    /// The chats that mention a ticket or bundle, as the Tickets window lists them: its own chats are in its Chats.
    var chatMentions: ChatMentionsReader {
        ChatMentionsReader { [chats, chatStore] id in
            let own = Set((chats.chats(ofTicket: id) + chats.chats(ofBundle: id)).map(\.id))
            return chats.chats(mentioning: id).filter { !own.contains($0.id) }.map { Self.row($0, chats, closed: chatStore.isClosed($0)) }
        }
    }

    /// A ticket's or bundle's own chats (docs/ui/tickets.md › Chats).
    var itemChats: ItemChatsReader {
        ItemChatsReader { [chats, chatStore] id in
            let list = TicketIDs.parseBundle(id) != nil ? chats.chats(ofBundle: id) : chats.chats(ofTicket: id)
            return list.map { Self.row($0, chats, closed: chatStore.isClosed($0)) }
        }
    }

    /// A chat as the Tickets window lists it.
    private static func row(_ chat: LoadedChat, _ chats: ChatSession, closed: Bool) -> MentioningChat {
        let state: MentioningChat.State = switch chats.state(of: chat.id) {
        case .starting, .running: .working
        case .waitingPermission, .waitingAnswers: .waiting
        case .error: .error
        case .idle: .idle
        }
        let kind: MentioningChat.Kind = switch chat.file.kind {
        case .ticket, .bundle: .implement
        case .ci: .ci
        case .feedback: .feedback
        case .project, .setup: .chat
        }
        return MentioningChat(id: chat.id, title: chat.file.title, projectID: chat.projectID, updated: chat.file.updated,
                              state: state, closed: closed, kind: kind)
    }

    // MARK: Implement (docs/ui/tickets.md › Implement)

    /// What starts the implement chats: the sheet's Start, and the tools `implement_ticket` and `implement_bundle`.
    var implementer: Implementer {
        Implementer(tickets: tickets, chats: chats)
    }

    // MARK: Updates (docs/ui/updates.md › Restart rules)

    /// What a restart for an update would stop or lose: the chats the status bar counts, the machines, setups and
    /// installs that run and the images that download, the chats' unsent drafts and the Tickets windows' unsaved
    /// edits, and the sheets.
    var runningWork: RunningWork {
        RunningWork(chats: StatusChat.list(chats).count,
                    machines: machineHost.runningCount + machineHost.images.filter { $0.state == .downloading }.count,
                    drafts: chatStore.hasDrafts || TicketsWindows.hasUnsavedEdits,
                    sheet: NSApp.windows.contains { $0.attachedSheet != nil })
    }

    // MARK: Notifications (docs/ui/navigation.md › Settings ▸ Notifications)

    /// The three toggles of Settings ▸ Notifications, all on until read.
    private(set) var notificationChoices = NotificationChoices()
    /// The chats' notifications, the Dock's badge and bounce.
    @ObservationIgnored private(set) lazy var notifier = ChatNotifier(chats: chats, posts: ChatNotifier.posts) { [weak self] in
        self?.notificationChoices ?? NotificationChoices()
    }

    /// Stores the toggles. Throws the storage error when they can't be stored; without a data folder they hold
    /// until the app quits.
    func setNotificationChoices(_ choices: NotificationChoices) throws(StorageError) {
        if let folder = session.dataFolder {
            var settings = folder.readSettings()
            settings.notifyNeedsYou = choices.needsYou
            settings.notifyFinished = choices.finished
            settings.notifyAISummary = choices.aiSummary
            try folder.writeSettings(settings)
        }
        notificationChoices = choices
    }

    init() {
        // The data of earlier builds, kept in the App Group container, is copied once before anything reads the folder.
        DataFolder.resolve()?.migrateFromAppGroup()
        session = ProjectSession(dataFolder: DataFolder.resolve())
        tickets = TicketSession(projects: session)
        ticketStore = LiveTicketStore(session: tickets)
        dashboardStore = LiveDashboardStore(session: session)
        let session = session
        contractStore = LiveContractStore(projects: session)
        serviceMapStore = LiveServiceMapStore(projects: session)
        let downloads = (DataFolder.resolve()?.url ?? FileManager.default.temporaryDirectory).appendingPathComponent("Runtime/downloads", isDirectory: true)
        kafkaStore = LiveKafkaStore(session: session)
        buildStore = LiveBuildStore(cli: {
            GitHubCLI(gh: session.tools.gh, environment: session.tools.environment, runner: SystemProcessRunner.shared)
        }, temporary: downloads, toolsReady: { await session.waitForTools() },
           page: { session.snapshot.project($0)?.resolved.githubPage })
        let host = MachineHost(dataFolder: DataFolder.resolve())
        machineHost = host
        machineStore = LiveMachineStore(host: host)
        skillStore = LiveInternalSkillStore(dataFolder: DataFolder.resolve())
        let tokens = MCPTokens()
        self.tokens = tokens
        chats = ChatSession(projects: session, tokens: tokens, device: TicketSession.computerName())
        // Which file tools a chat's Claude gets, and when an edit runs without asking: Settings ▸ Chat.
        chats.fileEdits = { ChatPreferences.fileEdits() }
        let operations = Operations()
        self.operations = operations
        chatStore = LiveChatStore(session: chats) { name, input in
            operations.registry?[name]?.describe?(input)
        }
        // A comment Claude added names the model and effort that wrote it, as V2's did.
        let chatSession = chats
        LiveTicketStore.commentCaption = { model, effort in ChatModelNames.caption(model: model, effort: effort, models: chatSession.models) }
        // A new comment of the user that mentions Claude gets Claude's answer, as V2's did.
        let answerer = CommentAnswerer(tickets: tickets, projects: session, chats: chats)
        self.answerer = answerer
        tickets.onMention = { [weak answerer] ticketID, commentID in answerer?.answer(commentID, of: ticketID) }
        // A ticket's chats count as closed while it is done, as V2 counted them.
        let tickets = tickets
        chatStore.isTicketDone = { id in tickets.snapshot.ticket(id)?.file.status == .done }
    }

    /// The registry, once made.
    @MainActor private final class Operations {
        var registry: ToolRegistry?
    }

    /// Starts the session once, whichever window appears first, and stops it as the app quits.
    func start() async {
        guard !started else { return }
        started = true
        follow()
        let chats = chats
        let maps = serviceMapStore
        let machines = machineHost
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // The tools started for the projects end with the app, the chats' Claude processes too; the lock
            // goes with the process.
            SystemProcessRunner.shared.terminateAll()
            // The Kafka spies run in process groups of their own.
            KafkaSpy.stopAll()
            MainActor.assumeIsolated {
                chats.stopAll()
                // Every machine and setup stops at once, every download and install ends.
                machines.stopAll()
            }
            let forwards = maps.forwards
            Task { await forwards.stopAll() }
        }
        // The tickets, the machines and the MCP server start without waiting for the login shell and the
        // projects' origins; what runs a tool waits for them (`waitForTools()`).
        await session.load()
        let session = session
        Task { await session.lookUpTools() }
        if let folder = session.dataFolder {
            let settings = folder.readSettings()
            opensWindowsAsTabs = settings.opensWindowsAsTabs
            feedbackProjectID = settings.feedbackProjectID
            notificationChoices = NotificationChoices(settings)
        }
        notifier.open = { [weak self] route in self?.openRoute?(route) }
        notifier.start()
        machineHost.load()
        updates.runningWork = { [weak self] in self?.runningWork ?? RunningWork() }
        QuitConfirmation.runningWork = { [weak self] in self?.runningWork ?? RunningWork() }
        updates.start(dataFolder: session.dataFolder)
        await tickets.start()
        // A ticket created without a title, by anyone, gets one from `set-ticket-title` (docs/ui/tickets.md ›
        // Titles written by Claude).
        await tickets.library?.onUntitled { [weak self] ticket in
            Task { @MainActor in self?.queueTitling(ticket) }
        }
        followTickets()
        await startMCP()
    }

    // MARK: Titles (docs/ui/tickets.md › Titles written by Claude)

    /// **Generate Title**, in New Ticket and the editor: a title from `set-ticket-title`. In the editor, the run
    /// links the ticket, which Claude reads whole; its message holds the description only while the editor's
    /// differs from the saved one. In New Ticket, before the ticket exists, the message is the description.
    var generateTitle: GenerateTitleAction {
        GenerateTitleAction { [chats, tickets] description, ticket throws(GenerateTitleError) in
            let answer: String
            do throws(ChatError) {
                if let ticket {
                    let saved = tickets.snapshot.ticket(ticket.id)?.file.description
                    answer = try await chats.run(.setTicketTitle, input: description == saved ? "" : description,
                                                 attaching: [Self.link(ticket: ticket.id, in: ticket.projectID)])
                } else {
                    answer = try await chats.run(.setTicketTitle, input: description)
                }
            } catch {
                throw GenerateTitleError(error.description)
            }
            guard let title = TicketRules.title(fromAnswer: answer) else {
                throw GenerateTitleError(String(localized: "Claude's answer has no title.", bundle: #bundle))
            }
            return title
        }
    }

    /// Titles one untitled ticket after the ones before it, so that many at once start one Claude process at a
    /// time.
    private func queueTitling(_ ticket: TicketLibrary.UntitledTicket) {
        let previous = titling
        titling = Task { [weak self] in
            await previous?.value
            await self?.titleUntitled(ticket)
        }
    }

    /// The link of a ticket in a skill's run: the line a chat's message carries for it.
    static func link(ticket id: String, in projectID: String) -> ChatItemReference {
        ChatItemReference(tool: ToolKind.tickets.rawValue, projectID: projectID, focus: id, title: id)
    }

    /// Asks `set-ticket-title` for the ticket's title, with the ticket's link alone: Claude reads the ticket
    /// whole. Gives the title to the ticket while it still has its provisional title; a failure leaves the
    /// provisional title.
    private func titleUntitled(_ ticket: TicketLibrary.UntitledTicket) async {
        let answer: String
        do {
            answer = try await chats.run(.setTicketTitle, input: "", attaching: [Self.link(ticket: ticket.id, in: ticket.projectID)])
        } catch {
            appLog.write(.warning, "titles", "\(ticket.id): \(error)")
            return
        }
        guard let title = TicketRules.title(fromAnswer: answer) else {
            appLog.write(.warning, "titles", "\(ticket.id): the answer gives no title")
            return
        }
        guard let library = tickets.library else { return }
        if (try? await library.setGeneratedTitle(title, of: ticket.id, replacing: ticket.provisionalTitle)) != nil {
            await tickets.refresh()
        }
    }

    /// Gives the directory the ticket counts now, and again each time the tickets change.
    private func followTickets() {
        withObservationTracking {
            directory.update(ticketCounts: ticketStore.counts())
            // A deleted comment or ticket stops its answer's run.
            answerer.follow(tickets.snapshot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTickets() }
        }
    }

    /// Starts the MCP server once the projects are loaded: the external token is read, or made and stored.
    private func startMCP() async {
        guard let folder = session.dataFolder, session.phase == .ready, server == nil else { return }
        settingsPort = folder.readSettings().mcpPort
        externalToken = try? folder.externalToken(make: MCPTokens.generate)
        tokens.replace(with: Set([externalToken].compactMap { $0 }))
        let registry = AppTools.registry(session: session, tickets: tickets, chats: chats, contracts: contractStore, maps: serviceMapStore,
                                          machines: machineHost, implementer: implementer, kafka: kafkaStore,
                                          debugTools: DebugTools.isEnabled) { [weak self] route in
            guard let open = self?.openRoute else { return false }
            open(route)
            return true
        }
        operations.registry = registry
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let chats = chats
        let tickets = tickets
        let session = session
        // A chat's Claude makes a change only as Settings ▸ Chat allows, asking first where it says so; an implement
        // chat's changes to its own items don't ask (docs/mcp.md › Permissions).
        let gate: MCPProtocol.Gate = { caller, operation, arguments in
            await ChatGate.check(caller, operation, arguments, chats: chats, bundleTickets: { @MainActor id in
                tickets.snapshot.bundle(id)?.ticketIDs
            }, projectFamily: { @MainActor id in
                Set(session.snapshot.family(of: id).map(\.id))
            })
        }
        let log = AppLog(url: session.dataFolder?.url.appendingPathComponent("Logs/engine.log"))
        appLog = log
        chats.appLog = log
        answerer.log = log
        let server = MCPServer(protocol: MCPProtocol(registry: registry, version: version, gate: gate, log: { log.write(.info, "mcp", $0) }),
                               tokens: tokens)
        self.server = server
        Task { [weak self] in
            for await state in server.states {
                switch state {
                case .listening(let port): log.write(.info, "mcp", "listening on 127.0.0.1:\(port)")
                case .failed(let message): log.write(.error, "mcp", "not listening: \(message)")
                case .stopped: log.write(.info, "mcp", "stopped")
                }
                self?.mcpState = state
                if case .failed(let message) = state {
                    self?.chats.mcpUnavailable = message
                } else {
                    self?.chats.mcpUnavailable = nil
                }
            }
        }
        await server.start(port: mcpPort)
        await chats.start(tools: registry.names, port: mcpPort)
    }

    /// Stores a new port and moves the server to it. Throws the storage error when it can't be stored.
    func changePort(to port: Int) async throws(StorageError) {
        guard let folder = session.dataFolder else { return }
        var settings = folder.readSettings()
        settings.mcpPort = port
        try folder.writeSettings(settings)
        settingsPort = port
        if environmentPort == nil {
            await server?.start(port: port)
            chats.setPort(port)
        }
    }

    /// Replaces the external token: requests with the old one are refused at once.
    func regenerateToken() throws(StorageError) {
        guard let folder = session.dataFolder else { return }
        let token = MCPTokens.generate()
        try folder.replaceExternalToken(with: token)
        externalToken = token
        tokens.replace(with: [token])
    }

    /// The command that adds the server to Claude Code in Terminal.
    var addCommand: String? {
        externalToken.map {
            "claude mcp add --transport http hephaestus http://127.0.0.1:\(mcpPort)/mcp --header \"Authorization: Bearer \($0)\""
        }
    }

    /// Updates the directory now, and again each time what it reads of the session changes.
    private func follow() {
        withObservationTracking {
            directory.update(from: session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}
