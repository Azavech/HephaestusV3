import AZDesign
import BuildsKit
import ChatKit
import ContractsKit
import DashboardsKit
import MachinesKit
import ProjectData
import ProjectsKit
import ServiceMapKit
import SwiftUI
import TicketsKit
import ToolsFoundation

/// Ids of the windows that aren't project tools.
enum SceneID {
    static let projects = "projects"
    static let machines = "machines"
    static let projectSettings = "projectSettings"
}

/// Every window of the app.
///
/// - Projects: the project selector, opened at launch.
/// - One window group per tool. Each window shows one project, which its toolbar switches,
///   so Tickets for Orders and Service Map for Payments can sit side by side.
/// - Virtual Machines: one window for the whole Mac.
/// - A menu bar item that opens a project from anywhere.
/// - Settings, with the chat's pane.
///
/// Chat is a tool like the others, and its panel can sit beside any other tool's window: Claude reads
/// items through `toolReader`, which sends each to the tool it belongs to.
///
/// A route never opens a second window for what a window already shows: `WindowDirectory` brings that
/// window forward instead, out of the Dock if it was minimised.
///
/// This is the only target that knows every tool. Tools ask for a `Route`; `RouteHost` opens it.
public struct ToolsScenes: Scene {
    /// The project data and the directory every window reads.
    @State private var appData = AppData()
    @State private var selectedProjectID: Project.ID?
    /// The machine the Virtual Machines window opens on.
    @State private var machineFocus: String?
    /// A route's ask to select a machine in the open Virtual Machines window.
    @State private var machineFocusRequest: FocusRequest?

    public init() {}

    public var body: some Scene {
        Window(Text("Projects", bundle: #bundle), id: SceneID.projects) {
            routeHost {
                ProjectsRootView(directory: appData.directory, session: appData.session, selection: $selectedProjectID)
                    .focusedSceneValue(\.activeProject, appData.directory.project(selectedProjectID))
                    .registersWindow(.projects, projectID: selectedProjectID)
            }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            NewItemCommands()
            ToolCommands()
            ChatPanelCommands()
        }

        toolScene(.dashboard, size: CGSize(width: 1240, height: 820))
        toolScene(.tickets, size: CGSize(width: 1180, height: 760))
        toolScene(.serviceMap, size: CGSize(width: 1320, height: 840))
        toolScene(.contracts, size: CGSize(width: 1120, height: 740))
        toolScene(.builds, size: CGSize(width: 1180, height: 720))
        toolScene(.chat, size: CGSize(width: 1180, height: 780))

        // One Project Settings window per project; a route brings the open one forward.
        WindowGroup(Text("Project Settings", bundle: #bundle), id: SceneID.projectSettings, for: Project.ID.self) { $projectID in
            routeHost {
                if let projectID {
                    ProjectSettingsWindow(session: appData.session, projectID: projectID)
                        .registersWindow(.projectSettings, projectID: projectID)
                }
            }
        }
        .defaultSize(width: 600, height: 720)
        .defaultLaunchBehavior(.suppressed)

        // The Mac's images and virtual machines (`AppData.machinesAvailable`).
        Window(Text("Virtual Machines", bundle: #bundle), id: SceneID.machines) {
            routeHost {
                MachinesRootView(focus: machineFocus, store: appData.machineStore)
                    .environment(\.focusRequest, machineFocusRequest)
                    .registersWindow(.machines, projectID: nil)
            }
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.suppressed)

        // Type a few letters, then Return: the project's window comes forward.
        MenuBarExtra(String(localized: "Open Project", bundle: #bundle), systemImage: "wrench.and.screwdriver") {
            routeHost {
                ProjectLauncher(projects: appData.directory.projects)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                ProjectsSettingsPane(session: appData.session)
                    .tabItem {
                        Label(String(localized: "Projects", bundle: #bundle), systemImage: "folder")
                    }
                MCPSettingsPane(appData: appData)
                    .tabItem {
                        Label(String(localized: "MCP", bundle: #bundle, comment: "The Settings tab of the MCP server"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                if AppData.machinesAvailable {
                    MachineSettingsView(store: appData.machineStore)
                        .tabItem {
                            Label(String(localized: "Virtual Machines", bundle: #bundle), systemImage: "desktopcomputer")
                        }
                }
                if AppData.availableTools.contains(.chat) {
                    ChatSettingsView()
                        .environment(\.chatStore, appData.chatStore)
                        .tabItem {
                            Label(ToolKind.chat.title, systemImage: ToolKind.chat.symbol)
                        }
                }
            }
            .frame(width: 520, height: 440)
            .tint(.accent)
        }
    }

    private func toolScene(_ tool: ToolKind, size: CGSize) -> some Scene {
        WindowGroup(Text(tool.title), id: tool.windowID, for: ToolWindowValue.self) { $value in
            routeHost {
                ToolWindowRoot(tool: tool, value: $value)
            }
        }
        .defaultSize(size)
        .defaultLaunchBehavior(.suppressed)
    }

    private func routeHost(@ViewBuilder content: () -> some View) -> some View {
        RouteHost(
            appData: appData, selectedProjectID: $selectedProjectID, machineFocus: $machineFocus,
            machineFocusRequest: $machineFocusRequest, content: content
        )
    }
}

/// Reads an item through the tool it belongs to: each tool's own read function, as any client of
/// the tool would call it, on the app's data.
@MainActor
func appToolReader(directory: ProjectDirectory, tickets: LiveTicketStore?, builds: LiveBuildStore?, contracts: LiveContractStore?,
                   maps: LiveServiceMapStore?) -> ToolReader {
    ToolReader { reference in
        guard let project = directory.project(reference.projectID) ?? Project.sample(reference.projectID) else { return nil }
        switch reference.tool {
        case .tickets: return TicketsReader.read(reference.focus, store: tickets)
        case .serviceMap: return ServiceMapReader.read(reference.focus, environment: reference.environment, project: project, store: maps)
        case .contracts: return ContractsReader.read(reference.focus, project: project, store: contracts)
        case .builds: return BuildsReader.read(reference.focus, project: project, store: builds)
        case .dashboard, .chat: return nil
        }
    }
}

/// Gives a window's views the action that opens routes, and the app's tint.
private struct RouteHost<Content: View>: View {
    let appData: AppData
    @Binding var selectedProjectID: Project.ID?
    @Binding var machineFocus: String?
    @Binding var machineFocusRequest: FocusRequest?
    let content: Content

    @Environment(\.openWindow) private var openWindow

    init(
        appData: AppData, selectedProjectID: Binding<Project.ID?>, machineFocus: Binding<String?>,
        machineFocusRequest: Binding<FocusRequest?>, @ViewBuilder content: () -> Content
    ) {
        self.appData = appData
        _selectedProjectID = selectedProjectID
        _machineFocus = machineFocus
        _machineFocusRequest = machineFocusRequest
        self.content = content()
    }

    /// Opens a route: brings forward the window that shows it, or opens one (docs/ui/navigation.md › Routes).
    private var openRouteAction: OpenRouteAction {
        OpenRouteAction { [openWindow, $selectedProjectID, $machineFocus, $machineFocusRequest] route in
            let windows = WindowDirectory.shared
            /// The Projects window on `id`: the open one, or a new one.
            @MainActor func showProjects(_ id: Project.ID) {
                $selectedProjectID.wrappedValue = id
                if !windows.bringForward(role: .projects, projectID: nil) {
                    openWindow(id: SceneID.projects)
                    WindowDirectory.activate()
                }
            }
            switch route {
            case .project(let id):
                showProjects(id)
            case .projectWindow(let id):
                if !windows.bringForward(role: nil, projectID: id) {
                    showProjects(id)
                }
            case .tool(let tool, let projectID, let focus):
                if !windows.bringForward(role: .tool(tool), projectID: projectID, focus: focus) {
                    openWindow(id: tool.windowID, value: ToolWindowValue(projectID: projectID, focus: focus))
                    WindowDirectory.activate()
                }
            case .projectSettings(let id):
                if !windows.bringForward(role: .projectSettings, projectID: id) {
                    openWindow(id: SceneID.projectSettings, value: id)
                    WindowDirectory.activate()
                }
            case .machine(let id):
                // A new window opens on the machine; an open one is asked to select it.
                $machineFocus.wrappedValue = id
                if windows.bringForward(role: .machines, projectID: nil) {
                    if let id {
                        $machineFocusRequest.wrappedValue = FocusRequest(id)
                    }
                } else {
                    openWindow(id: SceneID.machines)
                    WindowDirectory.activate()
                }
            }
        }
    }

    var body: some View {
        content
            .environment(\.openRoute, openRouteAction)
            .environment(\.toolReader, appToolReader(directory: appData.directory, tickets: appData.ticketStore, builds: appData.buildStore,
                                                     contracts: appData.contractStore, maps: appData.serviceMapStore))
            .environment(\.serviceMapStore, appData.serviceMapStore)
            .environment(\.contractStore, appData.contractStore)
            .environment(\.buildStore, appData.buildStore)
            .environment(\.projectDirectory, appData.directory)
            .environment(\.ticketStore, appData.ticketStore)
            .environment(\.dashboardStore, appData.dashboardStore)
            .environment(\.chatStore, appData.chatStore)
            .environment(\.availableTools, AppData.availableTools)
            .task {
                if appData.openRoute == nil { appData.openRoute = openRouteAction }
                await appData.start()
            }
            .tint(.accent)
    }
}

/// A tool's window: the tool for its project, with the project switcher in the toolbar, and the chat
/// panel beside it when the window shows it.
private struct ToolWindowRoot: View {
    let tool: ToolKind
    @Binding var value: ToolWindowValue?
    @Environment(\.projectDirectory) private var directory
    @Environment(\.ticketStore) private var ticketStore
    @Environment(\.dashboardStore) private var dashboardStore
    @Environment(\.chatStore) private var chatStore
    @Environment(\.buildStore) private var buildStore
    @Environment(\.contractStore) private var contractStore
    @Environment(\.serviceMapStore) private var serviceMapStore

    /// Whether this window shows the chat panel; each window keeps its own, across launches.
    @SceneStorage("chatPanelShown") private var chatPanelShown = false
    /// Whether tool windows offer the chat panel at all (Settings ▸ Chat).
    @AppStorage(ChatPreferences.showsPanelKey) private var chatPanelEnabled = true
    /// The item the tool has selected, which the chat panel asks about.
    @State private var chatSubject: ChatReference?
    /// The panel's conversation and draft, kept while the panel is hidden, until the window switches
    /// to another project.
    @State private var chatPanelModel: ChatPanelModel?
    /// A route's ask to select an item in this window, once it is open.
    @State private var focusRequest: FocusRequest?
    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which
    /// pick the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()

    /// The chat panel's width beside or over the tool, its divider included.
    private static let panelWidth: CGFloat = 341
    /// Below this width the toolbar drops the window's title, which its buttons need the room of.
    private static let titleWidth: CGFloat = 760
    /// No window gets narrower than an iPhone.
    private static let minimumWidth: CGFloat = 390

    var body: some View {
        window
            // Listed with what it shows, so that a route for it brings this window forward. The tool
            // selects the route's focus without starting afresh; the window's value keeps it, for
            // when the window is restored.
            .registersWindow(.tool(tool), projectID: value?.projectID) { [$value, $focusRequest] focus in
                $focusRequest.wrappedValue = FocusRequest(focus)
                $value.wrappedValue?.focus = focus
            }
            // Another project starts a new conversation in the panel.
            .onChange(of: value?.projectID, initial: true) {
                chatPanelModel = chatStore.map { ChatPanelModel(store: $0) }
                chatSubject = nil
            }
    }

    @ViewBuilder private var window: some View {
        if let value, let project = directory.project(value.projectID) {
            // One panel in every layout, so its conversation survives a resize: beside the tool on a
            // Mac (the tool makes room for it), over the tool on an iPad, the whole window on an iPhone.
            ZStack(alignment: .trailing) {
                content(for: project, focus: value.focus)
                    // Another project starts the tool afresh, without the old selection. A later
                    // route's focus arrives as a request instead, which the tool selects.
                    .id(value.projectID)
                    .environment(\.focusRequest, focusRequest)
                    .environment(\.reportChatSubject, ReportChatSubjectAction { [$chatSubject] subject in
                        $chatSubject.wrappedValue = subject
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, showsChatPanel && layout == .mac ? Self.panelWidth : 0)
                if showsChatPanel, let chatPanelModel {
                    HStack(spacing: 0) {
                        if layout != .phone {
                            Divider()
                        }
                        ChatPanel(project: project, origin: tool, subject: chatSubject, model: chatPanelModel) {
                            chatPanelControl.toggle()
                        }
                    }
                    .frame(width: layout == .phone ? adaptiveWindow.size.width : Self.panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.canvas)
                    // Over the content on an iPad, a shadow sets it apart.
                    .shadow(radius: layout == .pad ? 14 : 0)
                    // It slides in from the window's right edge and back out (AZDesign's `panel`
                    // motion; a fade under Reduce Motion).
                    .motionTransition(.panel, edge: .trailing)
                }
            }
            // Measures the window and gives the tool and the panel its layout, its size classes and
            // whether it narrowed from a regular width (AZDesign's adaptive window).
            .adaptiveWindow($adaptiveWindow, layout: layout)
            .frame(minWidth: Self.minimumWidth, minHeight: 420)
            // No clipping here: it would take the toolbar's room from the tool's columns. The window's
            // edge already hides the panel while it slides.
            // The tool puts the panel's button last in its toolbar, at the right end.
            .environment(\.chatPanel, offersChatPanel ? chatPanelControl : nil)
                .navigationTitle(Text(tool.title))
                .navigationSubtitle(Text(verbatim: directory.tree.path(of: project.id)))
                // A narrow toolbar has no room for the title: the switcher names the project.
                .toolbar(removing: adaptiveWindow.size.width < Self.titleWidth ? .title : nil)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ProjectSwitcher(projects: directory.projects, selection: projectBinding, tool: tool)
                    }
                }
                .focusedSceneValue(\.activeProject, project)
                .focusedSceneValue(\.activeTool, tool)
                .focusedSceneValue(\.chatPanel, offersChatPanel ? chatPanelControl : nil)
        } else {
            ContentUnavailableView {
                Label(String(localized: "No Project", bundle: #bundle), systemImage: "folder")
            } description: {
                Text("Open this window from the Projects window.", bundle: #bundle)
            }
            .accessibilityIdentifier("window.noProject")
            .frame(minWidth: 600, minHeight: 400)
            .background(.canvas)
        }
    }

    /// The Chat window has no panel of its own, and Settings can take it off every window.
    private var offersChatPanel: Bool {
        chatPanelEnabled && tool != .chat
    }

    private var showsChatPanel: Bool {
        offersChatPanel && chatPanelShown
    }

    private var chatPanelControl: ChatPanelControl {
        ChatPanelControl(isShown: $chatPanelShown)
    }

    /// The Mac's layout while the tool's columns, and the chat panel when it is open beside them, fit;
    /// an iPad's below that; an iPhone's in a narrow window.
    private var layout: WindowLayout {
        adaptiveWindow.layout(macWidth: tool.macLayoutWidth, sidePanelWidth: showsChatPanel ? Self.panelWidth : 0)
    }

    @ViewBuilder private func content(for project: Project, focus: String?) -> some View {
        switch tool {
        case .dashboard:
            if let dashboardStore {
                DashboardRootView(project: project, store: dashboardStore) { widget, context in
                    DashboardWidgetView(widget: widget, context: context)
                }
            }
        case .tickets:
            if let ticketStore {
                TicketsRootView(project: project, focus: focus, store: ticketStore, directory: directory)
            }
        case .serviceMap:
            if let serviceMapStore {
                ServiceMapRootView(project: project, focus: focus, store: serviceMapStore)
            }
        case .contracts:
            if let contractStore {
                ContractsRootView(project: project, focus: focus, store: contractStore)
            }
        case .builds:
            if let buildStore {
                BuildsRootView(project: project, focus: focus, store: buildStore)
            }
        case .chat:
            if let chatStore {
                ChatRootView(project: project, focus: focus, store: chatStore, directory: directory)
            }
        }
    }

    /// Switching project keeps the window and clears its focus. Picking the project it already shows
    /// changes nothing.
    private var projectBinding: Binding<Project.ID> {
        Binding {
            value?.projectID ?? ""
        } set: { projectID in
            if projectID != value?.projectID {
                value = ToolWindowValue(projectID: projectID)
            }
        }
    }
}

/// File ▸ New, as in a Mac app (the user's choice): ⌘N opens a new window of the key window's tool, on its
/// project, and ⇧⌘N creates the key window's own kind of item ("New Ticket…" in Tickets). They replace
/// the items SwiftUI adds for each window group, which open a tool window without a project.
private struct NewItemCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewWindowMenuItem()
            NewItemMenuItem()
            AddFolderMenuItem()
            Divider()
            ProjectSettingsMenuItem()
        }
    }
}

/// Project Settings…, ⇧⌘,: the settings of the key window's project, in their window.
private struct ProjectSettingsMenuItem: View {
    @FocusedValue(\.activeProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Project Settings…", bundle: #bundle, comment: "File menu item, ⇧⌘,")) {
            if let project, !WindowDirectory.shared.bringForward(role: .projectSettings, projectID: project.id) {
                openWindow(id: SceneID.projectSettings, value: project.id)
            }
        }
        .keyboardShortcut(",", modifiers: [.command, .shift])
        .disabled(project == nil)
    }
}

/// Add Existing Folder…, ⌘O: adds a folder that holds a project, from the Projects window.
private struct AddFolderMenuItem: View {
    @FocusedValue(\.addFolder) private var addFolder

    var body: some View {
        Button(String(localized: "Add Existing Folder…", bundle: #bundle, comment: "File menu item, ⌘O")) {
            addFolder?()
        }
        .keyboardShortcut("o")
        .disabled(addFolder == nil)
    }
}

/// New <Tool> Window, ⌘N: another window of the key tool window's tool and project, even when one is
/// open already; routes keep reusing the open one. Disabled where the key window isn't a tool window.
private struct NewWindowMenuItem: View {
    @FocusedValue(\.activeTool) private var tool
    @FocusedValue(\.activeProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            if let tool, let project {
                openWindow(id: tool.windowID, value: ToolWindowValue(projectID: project.id, instance: UUID()))
            }
        }
        .keyboardShortcut("n")
        .disabled(tool == nil || project == nil)
    }

    private var title: String {
        switch tool {
        case .dashboard?: String(localized: "New Dashboard Window", bundle: #bundle)
        case .tickets?: String(localized: "New Tickets Window", bundle: #bundle)
        case .serviceMap?: String(localized: "New Service Map Window", bundle: #bundle)
        case .contracts?: String(localized: "New Contracts Window", bundle: #bundle)
        case .builds?: String(localized: "New Builds Window", bundle: #bundle)
        case .chat?: String(localized: "New Chat Window", bundle: #bundle)
        case nil: String(localized: "New Window", bundle: #bundle)
        }
    }
}

/// New <Item>, ⇧⌘N: what the key window creates, from its `newItemCommand`. Disabled where it creates
/// nothing.
private struct NewItemMenuItem: View {
    @FocusedValue(\.newItem) private var newItem

    var body: some View {
        Button(newItem?.title ?? String(localized: "New Item", bundle: #bundle, comment: "File menu item, disabled: the key window creates nothing")) {
            newItem?()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(newItem == nil)
    }
}

nonisolated private struct ActiveToolKey: FocusedValueKey {
    typealias Value = ToolKind
}

nonisolated extension FocusedValues {
    /// The key window's tool, when it is a tool window.
    var activeTool: ToolKind? {
        get { self[ActiveToolKey.self] }
        set { self[ActiveToolKey.self] = newValue }
    }
}

/// Window menu items: the Projects window, each tool for the key window's project, the machines.
private struct ToolCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .windowList) {
            ToolMenuItems()
        }
    }
}

private struct ToolMenuItems: View {
    @FocusedValue(\.activeProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Projects", bundle: #bundle)) {
            if !WindowDirectory.shared.bringForward(role: .projects, projectID: nil) {
                openWindow(id: SceneID.projects)
            }
        }
        .keyboardShortcut("0")

        // Only the available tools.
        ForEach(ToolKind.allCases.filter(AppData.availableTools.contains)) { tool in
            Button {
                // The window already showing the tool for this project, or a new one.
                if let project, !WindowDirectory.shared.bringForward(role: .tool(tool), projectID: project.id) {
                    openWindow(id: tool.windowID, value: ToolWindowValue(projectID: project.id))
                }
            } label: {
                Text(tool.title)
            }
            .keyboardShortcut(tool.shortcut)
            .disabled(!(project?.tools.contains(tool) ?? false))
        }

        if AppData.machinesAvailable {
            Button(String(localized: "Virtual Machines", bundle: #bundle)) {
                if !WindowDirectory.shared.bringForward(role: .machines, projectID: nil) {
                    openWindow(id: SceneID.machines)
                }
            }
            .keyboardShortcut("7")
        }

        Divider()
    }
}

/// View ▸ Show Chat Panel: the panel of the key tool window, ⌃⌘C.
private struct ChatPanelCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ChatPanelMenuItem()
        }
    }
}

private struct ChatPanelMenuItem: View {
    @FocusedValue(\.chatPanel) private var chatPanel

    var body: some View {
        Button(
            chatPanel?.isShown.wrappedValue == true
                ? String(localized: "Hide Chat Panel", bundle: #bundle)
                : String(localized: "Show Chat Panel", bundle: #bundle)
        ) {
            chatPanel?.toggle()
        }
        .keyboardShortcut("c", modifiers: [.control, .command])
        .disabled(chatPanel == nil)
    }
}

nonisolated private struct ChatPanelFocusKey: FocusedValueKey {
    typealias Value = ChatPanelControl
}

nonisolated extension FocusedValues {
    /// The key tool window's chat panel; nil where there is no panel to show.
    var chatPanel: ChatPanelControl? {
        get { self[ChatPanelFocusKey.self] }
        set { self[ChatPanelFocusKey.self] = newValue }
    }
}

/// What a Dashboard widget shows: each kind is drawn by the tool whose data it shows. Only this target
/// knows every tool, so it is where the Dashboard meets them.
private struct DashboardWidgetView: View {
    let widget: DashboardWidget
    let context: DashboardContext

    var body: some View {
        switch widget.kind {
        case .project:
            DashboardProjectWidget(widget: widget, context: context)
        case .tickets:
            TicketsDashboardWidget(widget: widget, context: context)
        case .recentBuilds:
            BuildsDashboardWidget(widget: widget, context: context)
        case .instances, .serviceGraph, .busiestCalls, .failedRequests, .requestsPerMinute:
            ServiceMapDashboardWidget(widget: widget, context: context)
        case .recentChats, .cost:
            // Kept in the list, never shown.
            EmptyView()
        }
    }
}

extension ToolKind {
    /// The width the tool's columns need side by side, below which its window takes an iPad's layout.
    var macLayoutWidth: CGFloat {
        switch self {
        // The grid needs 900 points (below that the Dashboard lists its widgets). With the chat panel
        // open, the window needs 341 points more for the Mac layout, as every tool does.
        case .dashboard: 900
        case .tickets: 900
        case .serviceMap: 880
        case .contracts: 760
        case .builds: 900
        // The list, the conversation and the inspector: below this the conversation gets too narrow.
        case .chat: 960
        }
    }
}
