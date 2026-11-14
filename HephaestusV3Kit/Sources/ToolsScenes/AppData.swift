import AppKit
import ChatData
import ChatKit
import DashboardsKit
import ExternalTools
import FileStorage
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
    /// The tools whose feature has come over from HephaestusV2; the others are hidden in the running app
    /// (docs/ui/navigation.md › Available tools). Previews show every tool.
    static let availableTools: Set<ToolKind> = [.dashboard, .tickets, .chat]
    /// Whether the Virtual Machines window has come over.
    static let machinesAvailable = false

    let session: ProjectSession
    let directory = ProjectDirectory(projects: [], state: .loading)
    /// The tickets and bundles of the loaded projects, and the store the Tickets windows read.
    let tickets: TicketSession
    let ticketStore: LiveTicketStore
    /// The Dashboards of the loaded projects, kept in their project files.
    let dashboardStore: LiveDashboardStore
    /// The chats and their Claude processes (docs/architecture.md › ChatData).
    let chats: ChatSession
    /// The chats as the Chat windows and panels show them.
    let chatStore: LiveChatStore
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

    init() {
        session = ProjectSession(dataFolder: DataFolder.resolve())
        tickets = TicketSession(projects: session)
        ticketStore = LiveTicketStore(session: tickets)
        dashboardStore = LiveDashboardStore(session: session)
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
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // The tools started for the projects end with the app, the chats' Claude processes too; the lock
            // goes with the process.
            SystemProcessRunner.shared.terminateAll()
            MainActor.assumeIsolated { chats.stopAll() }
        }
        await session.start()
        await tickets.start()
        followTickets()
        await startMCP()
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
        let registry = AppTools.registry(session: session, tickets: tickets, chats: chats) { [weak self] route in
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
