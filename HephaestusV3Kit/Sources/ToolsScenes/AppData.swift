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
import MachinesKit
import MCPKit
import Observation
import ProjectData
import ProjectsKit
import TicketData
import TicketsKit
import ToolsFoundation

/// The app's data, shared by every window: the project session, and the directory the windows read, kept
/// in step with it.
@MainActor @Observable
final class AppData {
    /// The tools the running app offers; the others are hidden in the running app
    /// (docs/ui/navigation.md › Available tools). Previews show every tool.
    static let availableTools: Set<ToolKind> = Set(ToolKind.allCases)
    /// Whether the Virtual Machines window is available.
    static let machinesAvailable = true

    let session: ProjectSession
    let directory = ProjectDirectory(projects: [], state: .loading)
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
    /// The images and virtual machines of the data folder, and the machines that run (docs/architecture.md › MachineData).
    let machineHost: MachineHost
    /// The machines as the Virtual Machines window shows them.
    let machineStore: LiveMachineStore
    /// The chats and their Claude processes (docs/architecture.md › ChatData).
    let chats: ChatSession
    /// The chats as the Chat windows and panels show them.
    let chatStore: LiveChatStore
    /// The internal skills' content, in the data folder (System Prompts).
    let skillStore: LiveInternalSkillStore
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

    /// The project that receives feedback tickets: `settings.yml`'s `feedbackProjectID`, nil until read.
    private(set) var feedbackProjectID: Project.ID?

    /// The feedback project while it is loaded; nil hides the status bar and Help ▸ Send Feedback….
    var feedbackTarget: FeedbackTarget? {
        directory.project(feedbackProjectID).map { FeedbackTarget(project: $0, store: ticketStore) }
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
        buildStore = LiveBuildStore(cli: {
            GitHubCLI(gh: session.tools.gh, environment: session.tools.environment, runner: SystemProcessRunner.shared)
        }, temporary: downloads, toolsReady: { await session.waitForTools() })
        let host = MachineHost(dataFolder: DataFolder.resolve())
        machineHost = host
        machineStore = LiveMachineStore(host: host)
        skillStore = LiveInternalSkillStore(dataFolder: DataFolder.resolve())
        let tokens = MCPTokens()
        self.tokens = tokens
        chats = ChatSession(projects: session, tokens: tokens, device: TicketSession.computerName())
        let operations = Operations()
        self.operations = operations
        chatStore = LiveChatStore(session: chats) { name, input in
            operations.registry?[name]?.describe?(input)
        }
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
            MainActor.assumeIsolated {
                chats.stopAll()
                // Every machine and setup stops at once, every download and install ends.
                machines.stopAll()
            }
            let forwards = maps.forwards
            Task { await forwards.stopAll() }
        }
        await session.start()
        if let folder = session.dataFolder {
            let settings = folder.readSettings()
            opensWindowsAsTabs = settings.opensWindowsAsTabs
            feedbackProjectID = settings.feedbackProjectID
        }
        machineHost.load()
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

    /// **Generate Title**, in New Ticket and the editor: a title for a description from `set-ticket-title`,
    /// linking the ticket when it exists.
    var generateTitle: GenerateTitleAction {
        GenerateTitleAction { [chats] description, ticket throws(GenerateTitleError) in
            let answer: String
            do throws(ChatError) {
                answer = try await chats.run(.setTicketTitle, input: description,
                                             attaching: ticket.map { [Self.link(ticket: $0.id, in: $0.projectID)] } ?? [])
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

    /// Asks `set-ticket-title` for the ticket's title, linking the ticket, and gives it to the ticket while it
    /// still has its provisional title. A failure leaves the provisional title.
    private func titleUntitled(_ ticket: TicketLibrary.UntitledTicket) async {
        guard let answer = try? await chats.run(.setTicketTitle, input: ticket.description,
                                                attaching: [Self.link(ticket: ticket.id, in: ticket.projectID)]),
              let title = TicketRules.title(fromAnswer: answer), let library = tickets.library else { return }
        if (try? await library.setGeneratedTitle(title, of: ticket.id, replacing: ticket.provisionalTitle)) != nil {
            await tickets.refresh()
        }
    }

    /// Gives the directory the ticket counts now, and again each time the tickets change.
    private func followTickets() {
        withObservationTracking {
            directory.update(ticketCounts: ticketStore.counts())
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
                                          machines: machineHost) { [weak self] route in
            guard let open = self?.openRoute else { return false }
            open(route)
            return true
        }
        operations.registry = registry
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let chats = chats
        // A chat's Claude makes a change only as Settings ▸ Chat allows, asking first where it says so.
        let gate: MCPProtocol.Gate = { caller, operation, arguments in
            await ChatGate.check(caller, operation, arguments, chats: chats)
        }
        let server = MCPServer(protocol: MCPProtocol(registry: registry, version: version, gate: gate), tokens: tokens)
        self.server = server
        Task { [weak self] in
            for await state in server.states {
                self?.mcpState = state
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
