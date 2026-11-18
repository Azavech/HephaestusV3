import AppKit
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

/// Ids of the app's scenes.
enum SceneID {
    /// Every window but Settings and the menu bar panel: the app's tabs.
    static let workspace = "workspace"
}

/// Every window of the app.
///
/// - One kind of window, which holds tabs drawn by the app (`WorkspaceRoot`): Projects, a tool for a
///   project, a project's settings, Virtual Machines. Each tab's sidebar is inside the tab, and one chat
///   panel sits on the right, outside the tabs. The first window, at launch, shows Projects.
/// - A menu bar item that opens a project from anywhere.
/// - Settings, with the chat's pane.
///
/// Chat is a tool like the others, and its panel sits beside every tab: Claude reads items through
/// `toolReader`, which sends each to the tool it belongs to.
///
/// A route never opens a second tab for what a tab already shows: `WindowDirectory` selects that tab and
/// brings its window forward instead.
///
/// This is the only target that knows every tool. Tools ask for a `Route`; `RouteHost` opens it.
public struct ToolsScenes: Scene {
    /// The project data and the directory every window reads.
    @State private var appData = AppData()
    /// The project selected in Projects, which is one tab in the whole app.
    @State private var selectedProjectID: Project.ID?
    /// The machine the Virtual Machines tab opens on.
    @State private var machineFocus: String?
    /// A route's ask to select a machine in the open Virtual Machines tab.
    @State private var machineFocusRequest: FocusRequest?

    public init() {
        // The app draws its own tabs: macOS's tab items and tabbing are off.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public var body: some Scene {
        WindowGroup(Text(verbatim: "Hephaestus V3"), id: SceneID.workspace, for: WorkspaceValue.self) { $value in
            routeHost {
                WorkspaceRoot(value: $value, appData: appData, selectedProjectID: $selectedProjectID, machineFocus: machineFocus,
                              machineFocusRequest: machineFocusRequest)
            }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            SystemPromptsCommands()
            NewItemCommands()
            ToolCommands()
            TabCommands()
            ChatPanelCommands()
            FeedbackCommands()
        }

        // Type a few letters, then Return: the project's tab comes forward.
        MenuBarExtra(String(localized: "Open Project", bundle: #bundle), systemImage: "wrench.and.screwdriver") {
            routeHost {
                ProjectLauncher(projects: appData.directory.projects)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                GeneralSettingsPane(appData: appData)
                    .tabItem {
                        Label(String(localized: "General", bundle: #bundle, comment: "The Settings tab of the app's general settings"), systemImage: "gearshape")
                    }
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
                    NotificationSettingsPane(appData: appData)
                        .tabItem {
                            Label(String(localized: "Notifications", bundle: #bundle, comment: "The Settings tab of the chats' notifications"), systemImage: "bell.badge")
                        }
                }
            }
            .frame(width: 520, height: 440)
            .tint(.accent)
        }
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

    /// Opens a route: selects the tab that shows it and brings its window forward, or opens a tab
    /// (docs/ui/navigation.md › Routes).
    private var openRouteAction: OpenRouteAction {
        OpenRouteAction { [openWindow, $selectedProjectID, $machineFocus, $machineFocusRequest] route in
            let windows = WindowDirectory.shared
            switch route {
            case .project(let id):
                $selectedProjectID.wrappedValue = id
                windows.showOrOpen(.projects, openWindow: openWindow)
            case .projectWindow(let id):
                if !windows.show(where: { $0.tab(showingProject: id) }) {
                    $selectedProjectID.wrappedValue = id
                    windows.showOrOpen(.projects, openWindow: openWindow)
                }
            case .tool(let tool, let projectID, let focus):
                windows.showOrOpen(.tool(tool, project: projectID), focus: focus, openWindow: openWindow)
            case .projectSettings(let id):
                windows.showOrOpen(.projectSettings(id), openWindow: openWindow)
            case .machine(let id):
                // A new tab opens on the machine; an open one is asked to select it.
                $machineFocus.wrappedValue = id
                if windows.show(.machines) {
                    if let id {
                        $machineFocusRequest.wrappedValue = FocusRequest(id)
                    }
                } else {
                    windows.open(WorkspaceTab(content: .machines), openWindow: openWindow)
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
            .environment(\.dashboardWidgetRenderer, DashboardWidgetRenderer { DashboardWidgetView(widget: $0, context: $1) })
            .environment(\.contractStore, appData.contractStore)
            .environment(\.buildStore, appData.buildStore)
            .environment(\.projectDirectory, appData.directory)
            .environment(\.ticketStore, appData.ticketStore)
            .environment(\.dashboardStore, appData.dashboardStore)
            .environment(\.chatStore, appData.chatStore)
            .environment(\.availableTools, AppData.availableTools)
            .environment(\.feedbackTarget, appData.feedbackTarget)
            .environment(\.chatSession, appData.chats)
            .environment(\.generateTitle, appData.generateTitle)
            .task {
                if appData.openRoute == nil { appData.openRoute = openRouteAction }
                await appData.start()
            }
            .tint(.accent)
    }
}

/// File ▸ New, as in a Mac app (the user's choice): ⌘N opens a window, ⌘T a tab, both on the key window's
/// tool and project, ⇧⌘N creates the key window's own kind of item ("New Ticket…" in Tickets); ⌘W closes
/// the tab, ⇧⌘W the window. They replace the items SwiftUI adds for the window group, and its Close.
private struct NewItemCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewWindowMenuItem()
            NewTabMenuItem()
            NewItemMenuItem()
            AddFolderMenuItem()
            Divider()
            CloseMenuItems()
            Divider()
            ProjectSettingsMenuItem()
        }
        // SwiftUI's Close: Close Tab and Close Window replace it.
        CommandGroup(replacing: .saveItem) {}
    }
}

/// Hephaestus V3 ▸ System Prompts… (⌥⌘,), after Settings…: the internal skills, in their tab.
private struct SystemPromptsCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            SystemPromptsMenuItem()
        }
    }
}

private struct SystemPromptsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "System Prompts…", bundle: #bundle, comment: "App menu item, ⌥⌘,: the internal skills")) {
            WindowDirectory.shared.showOrOpen(.systemPrompts, openWindow: openWindow)
        }
        .keyboardShortcut(",", modifiers: [.command, .option])
    }
}

/// Project Settings…, ⇧⌘,: the settings of the key window's project, in their tab.
private struct ProjectSettingsMenuItem: View {
    @FocusedValue(\.activeProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "Project Settings…", bundle: #bundle, comment: "File menu item, ⇧⌘,")) {
            if let project {
                WindowDirectory.shared.showOrOpen(.projectSettings(project.id), openWindow: openWindow)
            }
        }
        .keyboardShortcut(",", modifiers: [.command, .shift])
        .disabled(project == nil)
    }
}

/// Add Existing Folder…, ⌘O: adds a folder that holds a project, from Projects.
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

/// New Window, ⌘N: a window with a new tab of the key window's tool and project, even when a tab shows them
/// already; routes keep reusing the open one. Disabled where the selected tab isn't a tool's.
private struct NewWindowMenuItem: View {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "New Window", bundle: #bundle)) {
            if let content = toolContent {
                openWindow(id: SceneID.workspace, value: WorkspaceValue(content))
            }
        }
        .keyboardShortcut("n")
        .disabled(toolContent == nil)
    }

    private var toolContent: WorkspaceContent? {
        guard let content = workspace?.selectedTab?.content, content.tool != nil else { return nil }
        return content
    }
}

/// New Tab, ⌘T: a tab of the selected tab's tool and project, after it, as the tab bar's + does.
private struct NewTabMenuItem: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button(String(localized: "New Tab", bundle: #bundle)) {
            if let workspace, let content = workspace.selectedTab?.content, content.tool != nil {
                workspace.add(WorkspaceTab(content: content))
            }
        }
        .keyboardShortcut("t")
        .disabled(workspace?.selectedTab?.content.tool == nil)
    }
}

/// Close Tab, ⌘W, and Close Window, ⇧⌘W. A window's last tab, and a window without tabs (Settings), close
/// the window.
private struct CloseMenuItems: View {
    @FocusedValue(\.workspace) private var workspace

    var body: some View {
        Button(String(localized: "Close Tab", bundle: #bundle)) {
            if let workspace, workspace.tabs.count > 1, let id = workspace.selectedTab?.id {
                workspace.remove(id)
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
        }
        .keyboardShortcut("w")
        Button(String(localized: "Close Window", bundle: #bundle)) {
            NSApp.keyWindow?.performClose(nil)
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
    }
}

/// New <Item>, ⇧⌘N: what the selected tab creates, from its `newItemCommand`. Disabled where it creates
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
    /// The selected tab's tool, when it is a tool's tab.
    var activeTool: ToolKind? {
        get { self[ActiveToolKey.self] }
        set { self[ActiveToolKey.self] = newValue }
    }
}

/// Window menu items: Projects, each tool for the key window's project, the machines.
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
            WindowDirectory.shared.showOrOpen(.projects, openWindow: openWindow)
        }
        .keyboardShortcut("0")

        // Only the available tools.
        ForEach(ToolKind.allCases.filter(AppData.availableTools.contains)) { tool in
            Button {
                // The tab already showing the tool for this project, or a new one.
                if let project {
                    WindowDirectory.shared.showOrOpen(.tool(tool, project: project.id), openWindow: openWindow)
                }
            } label: {
                Text(tool.title)
            }
            .keyboardShortcut(tool.shortcut)
            .disabled(!(project?.tools.contains(tool) ?? false))
        }

        if AppData.machinesAvailable {
            Button(String(localized: "Virtual Machines", bundle: #bundle)) {
                WindowDirectory.shared.showOrOpen(.machines, openWindow: openWindow)
            }
            .keyboardShortcut("7")
        }

        Divider()
    }
}

/// Window ▸ Show Previous Tab (⌃⇧⇥), Show Next Tab (⌃⇥), Move Tab to New Window and Merge All Windows, for
/// the app's own tabs, under the names and shortcuts of macOS's.
private struct TabCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            TabMenuItems()
        }
    }
}

private struct TabMenuItems: View {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Divider()
        Button(String(localized: "Show Previous Tab", bundle: #bundle)) {
            workspace?.selectPrevious()
        }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled((workspace?.tabs.count ?? 0) < 2)
        Button(String(localized: "Show Next Tab", bundle: #bundle)) {
            workspace?.selectNext()
        }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled((workspace?.tabs.count ?? 0) < 2)
        Button(String(localized: "Move Tab to New Window", bundle: #bundle)) {
            if let workspace, workspace.tabs.count > 1, let id = workspace.selectedTab?.id, let tab = workspace.remove(id) {
                openWindow(id: SceneID.workspace, value: WorkspaceValue(tabs: [tab]))
            }
        }
        .disabled((workspace?.tabs.count ?? 0) < 2)
        Button(String(localized: "Merge All Windows", bundle: #bundle)) {
            if let workspace {
                WindowDirectory.shared.mergeAll(into: workspace)
            }
        }
        .disabled(workspace == nil || WindowDirectory.shared.windows().count < 2)
    }
}

/// View ▸ Show Chat Panel: the panel of the key window, ⌃⌘C.
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
    /// The key window's chat panel; nil where there is no panel to show.
    var chatPanel: ChatPanelControl? {
        get { self[ChatPanelFocusKey.self] }
        set { self[ChatPanelFocusKey.self] = newValue }
    }
}

/// What a Dashboard widget shows: each kind is drawn by the tool whose data it shows. Only this target
/// knows every tool, so it is where the Dashboard meets them.
struct DashboardWidgetView: View {
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
