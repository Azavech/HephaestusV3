import AZDesign
import BuildsKit
import ChatKit
import ContractsKit
import DashboardsKit
import MachinesKit
import ProjectsKit
import ServiceMapKit
import SwiftUI
import TicketsKit
import ToolsFoundation

/// Ids of the windows that aren't project tools.
enum SceneID {
    static let projects = "projects"
    static let machines = "machines"
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
    @State private var selectedProjectID: Project.ID? = Project.samples.first?.id
    /// The machine the Virtual Machines window opens on.
    @State private var machineFocus: String?
    /// A route's ask to select a machine in the open Virtual Machines window.
    @State private var machineFocusRequest: FocusRequest?

    public init() {}

    public var body: some Scene {
        Window(Text("Projects", bundle: #bundle), id: SceneID.projects) {
            routeHost {
                ProjectsRootView(projects: Project.samples, selection: $selectedProjectID)
                    .focusedSceneValue(\.activeProject, selectedProjectID.flatMap(Project.sample))
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

        Window(Text("Virtual Machines", bundle: #bundle), id: SceneID.machines) {
            routeHost {
                MachinesRootView(focus: machineFocus)
                    .environment(\.focusRequest, machineFocusRequest)
                    .registersWindow(.machines, projectID: nil)
            }
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.suppressed)

        // Type a few letters, then Return: the project's window comes forward.
        MenuBarExtra(String(localized: "Open Project", bundle: #bundle), systemImage: "wrench.and.screwdriver") {
            routeHost {
                ProjectLauncher(projects: Project.samples)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TabView {
                ChatSettingsView()
                    .tabItem {
                        Label(ToolKind.chat.title, systemImage: ToolKind.chat.symbol)
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
            selectedProjectID: $selectedProjectID, machineFocus: $machineFocus, machineFocusRequest: $machineFocusRequest,
            content: content
        )
    }
}

/// Reads an item through the tool it belongs to: each tool's own read function, as any client of
/// the tool would call it.
private let appToolReader = ToolReader { reference in
    guard let project = Project.sample(reference.projectID) else { return nil }
    switch reference.tool {
    case .tickets: return TicketsReader.read(reference.focus)
    case .serviceMap: return ServiceMapReader.read(reference.focus, environment: reference.environment, project: project)
    case .contracts: return ContractsReader.read(reference.focus, project: project)
    case .builds: return BuildsReader.read(reference.focus, project: project)
    case .dashboard, .chat: return nil
    }
}

/// Gives a window's views the action that opens routes, and the app's tint.
private struct RouteHost<Content: View>: View {
    @Binding var selectedProjectID: Project.ID?
    @Binding var machineFocus: String?
    @Binding var machineFocusRequest: FocusRequest?
    let content: Content

    @Environment(\.openWindow) private var openWindow

    init(
        selectedProjectID: Binding<Project.ID?>, machineFocus: Binding<String?>, machineFocusRequest: Binding<FocusRequest?>,
        @ViewBuilder content: () -> Content
    ) {
        _selectedProjectID = selectedProjectID
        _machineFocus = machineFocus
        _machineFocusRequest = machineFocusRequest
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.openRoute, OpenRouteAction { [openWindow, $selectedProjectID, $machineFocus, $machineFocusRequest] route in
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
            })
            .environment(\.toolReader, appToolReader)
            .tint(.accent)
    }
}

/// A tool's window: the tool for its project, with the project switcher in the toolbar, and the chat
/// panel beside it when the window shows it.
private struct ToolWindowRoot: View {
    let tool: ToolKind
    @Binding var value: ToolWindowValue?

    /// Whether this window shows the chat panel; each window keeps its own, across launches.
    @SceneStorage("chatPanelShown") private var chatPanelShown = false
    /// Whether tool windows offer the chat panel at all (Settings ▸ Chat).
    @AppStorage(ChatPreferences.showsPanelKey) private var chatPanelEnabled = true
    /// The item the tool has selected, which the chat panel asks about.
    @State private var chatSubject: ChatReference?
    /// The panel's conversation and draft, kept while the panel is hidden, until the window switches
    /// to another project.
    @State private var chatPanelModel = ChatPanelModel()
    /// A route's ask to select an item in this window, once it is open.
    @State private var focusRequest: FocusRequest?
    /// The window's width, which picks the Mac's, an iPad's or an iPhone's layout. Wide until measured.
    @State private var windowWidth: CGFloat = 10_000
    /// The window's size classes, from its size: compact width is an iPhone's, compact height an
    /// iPhone held sideways. Regular until measured.
    @State private var sizeClasses = WindowSizeClasses.regular
    /// Whether the window has shown a regular width since it opened.
    @State private var wasRegularWidth = false

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
            .onChange(of: value?.projectID) {
                chatPanelModel = ChatPanelModel()
                chatSubject = nil
            }
    }

    @ViewBuilder private var window: some View {
        if let value, let project = Project.sample(value.projectID) {
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
                    .environment(\.toolLayout, layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, showsChatPanel && layout == .mac ? Self.panelWidth : 0)
                if showsChatPanel {
                    HStack(spacing: 0) {
                        if layout != .phone {
                            Divider()
                        }
                        ChatPanel(project: project, origin: tool, subject: chatSubject, model: chatPanelModel) {
                            chatPanelControl.toggle()
                        }
                    }
                    .frame(width: layout == .phone ? windowWidth : Self.panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.canvas)
                    // Over the content on an iPad, a shadow sets it apart.
                    .shadow(radius: layout == .pad ? 14 : 0)
                    // It slides in from the window's right edge and back out (AZDesign's `panel`
                    // motion; a fade under Reduce Motion).
                    .motionTransition(.panel, edge: .trailing)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                windowWidth = size.width
                sizeClasses = WindowSizeClasses(size: size)
                if sizeClasses.horizontal == .regular {
                    wasRegularWidth = true
                }
            }
            // The system's size classes, as iPadOS and iOS would set them for a window this size.
            .windowSizeClasses(sizeClasses)
            .environment(\.collapsedFromRegularWidth, wasRegularWidth && sizeClasses.horizontal == .compact)
            .frame(minWidth: Self.minimumWidth, minHeight: 420)
            // No clipping here: it would take the toolbar's room from the tool's columns. The window's
            // edge already hides the panel while it slides.
            // The tool puts the panel's button last in its toolbar, at the right end.
            .environment(\.chatPanel, offersChatPanel ? chatPanelControl : nil)
                .navigationTitle(Text(tool.title))
                .navigationSubtitle(Text(verbatim: Project.tree.path(of: project.id)))
                // A narrow toolbar has no room for the title: the switcher names the project.
                .toolbar(removing: windowWidth < Self.titleWidth ? .title : nil)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ProjectSwitcher(projects: Project.samples, selection: projectBinding, tool: tool)
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
    private var layout: ToolLayout {
        ToolLayout.forWidth(windowWidth, macWidth: tool.macLayoutWidth, panelWidth: showsChatPanel ? Self.panelWidth : 0)
    }

    @ViewBuilder private func content(for project: Project, focus: String?) -> some View {
        switch tool {
        case .dashboard:
            DashboardRootView(project: project) { widget, context in
                DashboardWidgetView(widget: widget, context: context)
            }
        case .tickets: TicketsRootView(project: project, focus: focus)
        case .serviceMap: ServiceMapRootView(project: project, focus: focus)
        case .contracts: ContractsRootView(project: project, focus: focus)
        case .builds: BuildsRootView(project: project, focus: focus)
        case .chat: ChatRootView(project: project, focus: focus)
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
        }
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

        ForEach(ToolKind.allCases) { tool in
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

        Button(String(localized: "Virtual Machines", bundle: #bundle)) {
            if !WindowDirectory.shared.bringForward(role: .machines, projectID: nil) {
                openWindow(id: SceneID.machines)
            }
        }
        .keyboardShortcut("7")

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
        }
    }
}

extension ToolKind {
    /// The width the tool's columns need side by side, below which its window takes an iPad's layout.
    var macLayoutWidth: CGFloat {
        switch self {
        // V2's grid needs 900 points (below that the Dashboard lists its widgets); with the chat panel
        // open, the panel slides over it rather than narrowing it.
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
