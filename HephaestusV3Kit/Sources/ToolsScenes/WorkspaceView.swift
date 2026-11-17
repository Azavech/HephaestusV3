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

/// Every window of the app but Settings and the menu bar panel: the app's own tab bar, the selected tab's
/// content with its sidebar inside the tab, and the chat panel on the right, outside the tabs
/// (docs/ui/navigation.md › Tabs).
struct WorkspaceRoot: View {
    @Binding var value: WorkspaceValue?
    let appData: AppData
    @Binding var selectedProjectID: Project.ID?
    let machineFocus: String?
    let machineFocusRequest: FocusRequest?
    @State private var workspace: Workspace

    init(value: Binding<WorkspaceValue?>, appData: AppData, selectedProjectID: Binding<Project.ID?>, machineFocus: String?,
         machineFocusRequest: FocusRequest?) {
        _value = value
        self.appData = appData
        _selectedProjectID = selectedProjectID
        self.machineFocus = machineFocus
        self.machineFocusRequest = machineFocusRequest
        _workspace = State(initialValue: Workspace(value.wrappedValue ?? .initial))
    }

    var body: some View {
        WorkspaceWindow(workspace: workspace, appData: appData, selectedProjectID: $selectedProjectID, machineFocus: machineFocus,
                        machineFocusRequest: machineFocusRequest)
            // The window's value follows its tabs, so that macOS restores them.
            .onChange(of: workspace.value, initial: true) { _, new in
                if value != new {
                    value = new
                }
            }
    }
}

/// A window's layout: the tab area and the chat panel beside it on a Mac, over it on an iPad, the whole
/// window on an iPhone; the status bar under both.
private struct WorkspaceWindow: View {
    let workspace: Workspace
    let appData: AppData
    @Binding var selectedProjectID: Project.ID?
    let machineFocus: String?
    let machineFocusRequest: FocusRequest?

    @Environment(\.openWindow) private var openWindow
    /// Whether this window shows the chat panel; each window keeps its own, across launches. Shown at first.
    @SceneStorage("chatPanelShown") private var chatPanelShown = true
    /// Whether windows offer the chat panel at all (Settings ▸ Chat).
    @AppStorage(ChatPreferences.showsPanelKey) private var chatPanelEnabled = true
    /// The window's size, size classes and whether it narrowed from a regular width (AZDesign), which pick
    /// the Mac's, an iPad's or an iPhone's layout.
    @State private var adaptiveWindow = AdaptiveWindowState()

    /// The chat panel's width beside or over the tabs, its divider included.
    static let panelWidth: CGFloat = 341
    /// No window gets narrower than an iPhone.
    private static let minimumWidth: CGFloat = 390

    var body: some View {
        if let tab = workspace.selectedTab {
            window(tab)
        }
    }

    private func window(_ tab: WorkspaceTab) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // A single tab shows no tab bar: its content goes up under the toolbar.
                if workspace.showsTabBar {
                    TabBar(workspace: workspace, title: title(of:), symbol: symbol(of:), newTab: newTab(for: tab), moveToNewWindow: moveToNewWindow)
                    Divider()
                }
                TabContentView(tab: tab, workspace: workspace, appData: appData, selectedProjectID: $selectedProjectID,
                        machineFocus: machineFocus, machineFocusRequest: machineFocusRequest, underTabBar: workspace.showsTabBar)
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsChatPanel(tab), layout(tab) == .mac {
                Divider()
                panel(tab)
                    .frame(width: Self.panelWidth)
                    .motionTransition(.panel, edge: .trailing)
            }
        }
        // On an iPad the panel slides over the tabs, with a shadow; on an iPhone it takes the window.
        .overlay(alignment: .trailing) {
            if showsChatPanel(tab), layout(tab) != .mac {
                HStack(spacing: 0) {
                    if layout(tab) != .phone {
                        Divider()
                    }
                    panel(tab)
                }
                .frame(width: layout(tab) == .phone ? adaptiveWindow.size.width : Self.panelWidth)
                .shadow(radius: layout(tab) == .pad ? 14 : 0)
                .motionTransition(.panel, edge: .trailing)
            }
        }
        // Measures the window and gives the tab and the panel its layout, its size classes and whether it
        // narrowed from a regular width (AZDesign's adaptive window).
        .adaptiveWindow($adaptiveWindow, layout: layout(tab))
        .frame(minWidth: Self.minimumWidth, minHeight: 420)
        .statusBar(FeedbackSource(window: windowName(of: tab), project: project(of: tab), item: workspace.subjects[tab.id]?.title))
        .environment(\.chatPanel, offersChatPanel(tab) ? chatPanelControl : nil)
        .focusedSceneValue(\.chatPanel, offersChatPanel(tab) ? chatPanelControl : nil)
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.activeProject, project(of: tab))
        .focusedSceneValue(\.activeTool, tab.content.tool)
        .background {
            WindowReader { [workspace] window in WindowDirectory.shared.register(window, workspace: workspace) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Chat panel

    /// The selected tab's project's conversation; in a tab without a project, the last one the window showed.
    @ViewBuilder private func panel(_ tab: WorkspaceTab) -> some View {
        if let project = panelProject(of: tab) {
            ChatPanel(project: project, origin: tab.content.tool ?? .dashboard, subject: workspace.subjects[tab.id],
                      model: workspace.panel(for: project.id) { [chatStore = appData.chatStore] in ChatPanelModel(store: chatStore) }) {
                chatPanelControl.toggle()
            }
            .background(.canvas)
        } else {
            ContentUnavailableView {
                Label(String(localized: "No Project", bundle: #bundle), systemImage: ToolKind.chat.symbol)
            } description: {
                Text("Select a project to chat about it.", bundle: #bundle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.canvas)
            .accessibilityIdentifier("chatPanel.noProject")
        }
    }

    private func panelProject(of tab: WorkspaceTab) -> Project? {
        project(of: tab) ?? appData.directory.project(workspace.lastProjectID)
    }

    /// Chat is the chat itself, and Settings ▸ Chat can take the panel off every window.
    private func offersChatPanel(_ tab: WorkspaceTab) -> Bool {
        chatPanelEnabled && tab.content.tool != .chat
    }

    private func showsChatPanel(_ tab: WorkspaceTab) -> Bool {
        offersChatPanel(tab) && chatPanelShown
    }

    private var chatPanelControl: ChatPanelControl {
        ChatPanelControl(isShown: $chatPanelShown)
    }

    /// The Mac's layout while the tab's columns, and the chat panel when it is open beside them, fit; an
    /// iPad's below that; an iPhone's in a narrow window.
    private func layout(_ tab: WorkspaceTab) -> WindowLayout {
        adaptiveWindow.layout(macWidth: tab.content.tool?.macLayoutWidth ?? 760, sidePanelWidth: showsChatPanel(tab) ? Self.panelWidth : 0)
    }

    // MARK: Tabs

    /// The project a tab shows: its own, or the one selected in Projects.
    private func project(of tab: WorkspaceTab) -> Project? {
        if tab.content == .projects {
            return appData.directory.project(selectedProjectID)
        }
        return appData.directory.project(tab.content.projectID)
    }

    /// The window's name a tab stands for: a tool's title, Projects, Project Settings or Virtual Machines.
    private func windowName(of tab: WorkspaceTab) -> String {
        switch tab.content {
        case .projects: String(localized: "Projects", bundle: #bundle)
        case .tool(let tool, _): tool.title
        case .projectSettings: String(localized: "Project Settings", bundle: #bundle)
        case .machines: String(localized: "Virtual Machines", bundle: #bundle)
        }
    }

    /// "Tickets – Orders", "Project Settings – Orders", "Projects", "Virtual Machines".
    private func title(of tab: WorkspaceTab) -> String {
        guard let project = appData.directory.project(tab.content.projectID) else { return windowName(of: tab) }
        return WindowDirectory.tabTitle(windowName(of: tab), project: project.name)
    }

    private func symbol(of tab: WorkspaceTab) -> String {
        switch tab.content {
        case .projects: "folder"
        case .tool(let tool, _): tool.symbol
        case .projectSettings: "gearshape"
        case .machines: "desktopcomputer"
        }
    }

    /// The tab bar's +: another tab of the selected tab's tool and project; none in Projects, Project
    /// Settings and Virtual Machines, which open once each.
    private func newTab(for tab: WorkspaceTab) -> (() -> Void)? {
        guard case .tool = tab.content else { return nil }
        return { [workspace] in workspace.add(WorkspaceTab(content: tab.content)) }
    }

    private func moveToNewWindow(_ id: WorkspaceTab.ID) {
        guard workspace.tabs.count > 1, let tab = workspace.remove(id) else { return }
        openWindow(id: SceneID.workspace, value: WorkspaceValue(tabs: [tab]))
    }
}

// MARK: Tab content

/// What a tab shows, drawn only while it is selected; a tool's state is kept in the window.
private struct TabContentView: View {
    let tab: WorkspaceTab
    let workspace: Workspace
    let appData: AppData
    @Binding var selectedProjectID: Project.ID?
    let machineFocus: String?
    let machineFocusRequest: FocusRequest?
    /// Whether the tab bar is between the toolbar and the tab's content.
    let underTabBar: Bool

    var body: some View {
        content
            // Under the tab bar, the toolbar's edge effect, made for content that scrolls under the toolbar,
            // would blur the content's first rows. A single tab's content goes under the toolbar, and keeps it.
            .scrollEdgeEffectHidden(underTabBar, for: .top)
    }

    @ViewBuilder private var content: some View {
        switch tab.content {
        case .projects:
            ProjectsRootView(directory: appData.directory, session: appData.session, selection: $selectedProjectID)
                .toolbar { ChatPanelToolbarItem() }
        case .tool(let tool, let projectID):
            if let project = appData.directory.project(projectID) {
                ToolTab(tool: tool, project: project, tab: tab, workspace: workspace, appData: appData)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Project", bundle: #bundle), systemImage: "folder")
                } description: {
                    Text("This tab's project isn't loaded. Pick another one in Projects.", bundle: #bundle)
                }
                .accessibilityIdentifier("window.noProject")
                .background(.canvas)
            }
        case .projectSettings(let projectID):
            ProjectSettingsWindow(session: appData.session, projectID: projectID)
                .toolbar { ChatPanelToolbarItem() }
        case .machines:
            MachinesRootView(state: workspace.state(for: tab) { MachinesTabState(focus: machineFocus, store: appData.machineStore) })
                .environment(\.focusRequest, machineFocusRequest)
                .toolbar { ChatPanelToolbarItem() }
        }
    }
}

/// A tool's tab: the tool for its project, with the project switcher in the toolbar.
private struct ToolTab: View {
    let tool: ToolKind
    let project: Project
    let tab: WorkspaceTab
    let workspace: Workspace
    let appData: AppData

    @State private var width: CGFloat = 10_000

    /// Below this width the toolbar drops the window's title, which its buttons need the room of.
    private static let titleWidth: CGFloat = 760

    var body: some View {
        content
            .environment(\.focusRequest, workspace.focusRequests[tab.id])
            .environment(\.reportChatSubject, ReportChatSubjectAction { [workspace, id = tab.id] subject in
                workspace.report(subject, in: id)
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(Text(tool.title))
            .navigationSubtitle(Text(verbatim: appData.directory.tree.path(of: project.id)))
            // A narrow toolbar has no room for the title: the switcher names the project.
            .toolbar(removing: width < Self.titleWidth ? .title : nil)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ProjectSwitcher(projects: appData.directory.projects, selection: projectBinding, tool: tool)
                }
            }
    }

    @ViewBuilder private var content: some View {
        let directory = appData.directory
        switch tool {
        case .dashboard:
            DashboardRootView(state: workspace.state(for: tab) { DashboardTabState(project: project, store: appData.dashboardStore) }) {
                DashboardWidgetView(widget: $0, context: $1)
            }
        case .tickets:
            TicketsRootView(state: workspace.state(for: tab) {
                TicketsTabState(project: project, focus: tab.focus, store: appData.ticketStore, directory: directory)
            })
        case .serviceMap:
            ServiceMapRootView(state: workspace.state(for: tab) {
                ServiceMapTabState(project: project, focus: tab.focus, store: appData.serviceMapStore)
            })
        case .contracts:
            ContractsRootView(state: workspace.state(for: tab) {
                ContractsTabState(project: project, focus: tab.focus, store: appData.contractStore)
            })
        case .builds:
            BuildsRootView(state: workspace.state(for: tab) { BuildsTabState(project: project, focus: tab.focus, store: appData.buildStore) })
        case .chat:
            ChatRootView(state: workspace.state(for: tab) {
                ChatTabState(project: project, focus: tab.focus, store: appData.chatStore, directory: directory)
            })
        }
    }

    /// Switching project keeps the tab and starts the tool afresh on the other project. Picking the project it
    /// already shows changes nothing.
    private var projectBinding: Binding<Project.ID> {
        Binding {
            project.id
        } set: { [workspace, id = tab.id] projectID in
            workspace.switchProject(of: id, to: projectID)
        }
    }
}

// MARK: Tab bar

/// The app's tab bar, across the tab area under the toolbar: one tab per tab of the window, then + for a new
/// tab of the selected tool (docs/ui/navigation.md › Tab bar).
struct TabBar: View {
    let workspace: Workspace
    let title: (WorkspaceTab) -> String
    let symbol: (WorkspaceTab) -> String
    let newTab: (() -> Void)?
    let moveToNewWindow: (WorkspaceTab.ID) -> Void

    @Environment(\.openWindow) private var openWindow
    /// The tab being dragged, and how far.
    @State private var dragged: WorkspaceTab.ID?
    @State private var dragOffset: CGSize = .zero

    /// Tabs share the bar's width, from 120 to 240 points each; past that the bar scrolls.
    static let minimumTabWidth: CGFloat = 120
    static let maximumTabWidth: CGFloat = 240
    static let height: CGFloat = 36
    /// A tab dragged this far up or down out of the bar goes into a window of its own.
    static let tearOffDistance: CGFloat = 48

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                let width = tabWidth(in: geometry.size.width)
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            TabButton(
                                title: title(tab), symbol: symbol(tab), isSelected: tab.id == workspace.selectedTab?.id,
                                canMove: workspace.tabs.count > 1,
                                select: { workspace.select(tab.id) },
                                close: { close(tab.id) },
                                closeOthers: { closeOthers(than: tab.id) },
                                moveToNewWindow: { moveToNewWindow(tab.id) }
                            )
                            .frame(width: width)
                            .offset(dragged == tab.id ? CGSize(width: dragOffset.width, height: 0) : .zero)
                            .opacity(dragged == tab.id && abs(dragOffset.height) > Self.tearOffDistance ? 0.5 : 1)
                            .zIndex(dragged == tab.id ? 1 : 0)
                            .gesture(drag(tab, width: width))
                            .accessibilityIdentifier("tabs.tab.\(identifier(of: tab))")
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
            }
            if let newTab {
                Button(action: newTab) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(Text("New Tab (⌘T)", bundle: #bundle))
                .accessibilityLabel(Text("New Tab", bundle: #bundle))
                .accessibilityIdentifier("tabs.new")
                .padding(.trailing, 8)
            }
        }
        .frame(height: Self.height)
        .background(.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs")
    }

    private func tabWidth(in available: CGFloat) -> CGFloat {
        let count = CGFloat(max(workspace.tabs.count, 1))
        let fitting = (available - 16 - 4 * (count - 1)) / count
        return min(Self.maximumTabWidth, max(Self.minimumTabWidth, fitting))
    }

    /// Sideways, the tab moves among the others; dragged out of the bar, it goes into a window of its own.
    private func drag(_ tab: WorkspaceTab, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragged = tab.id
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    dragged = nil
                    dragOffset = .zero
                }
                if abs(value.translation.height) > Self.tearOffDistance, workspace.tabs.count > 1 {
                    moveToNewWindow(tab.id)
                    return
                }
                guard let from = workspace.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                let steps = Int((value.translation.width / (width + 4)).rounded())
                workspace.move(tab.id, to: from + steps)
            }
    }

    /// Closes a tab; the window's last tab closes the window.
    private func close(_ id: WorkspaceTab.ID) {
        if workspace.tabs.count > 1 {
            workspace.remove(id)
        } else {
            WindowDirectory.shared.window(of: workspace)?.performClose(nil)
        }
    }

    private func closeOthers(than id: WorkspaceTab.ID) {
        for other in workspace.tabs where other.id != id {
            workspace.remove(other.id)
        }
        workspace.select(id)
    }

    /// `projects`, `tickets.ORD`, `projectSettings.ORD`, `machines`.
    private func identifier(of tab: WorkspaceTab) -> String {
        switch tab.content {
        case .projects: "projects"
        case .tool(let tool, let project): "\(tool.rawValue).\(project)"
        case .projectSettings(let project): "projectSettings.\(project)"
        case .machines: "machines"
        }
    }
}

/// One tab of the bar: its symbol and title, and a close button while the pointer is over it or it is selected.
private struct TabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let canMove: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let moveToNewWindow: () -> Void

    @State private var hovers = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .opacity(hovers || isSelected ? 1 : 0)
            .help(Text("Close Tab (⌘W)", bundle: #bundle))
            .accessibilityLabel(Text("Close \(title)", bundle: #bundle))
        }
        .font(.callout)
        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            Capsule()
                .fill(isSelected ? AnyShapeStyle(.surface) : AnyShapeStyle(hovers ? Color.textSecondary.opacity(0.08) : .clear))
        }
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { hovers = $0 }
        .contextMenu {
            Button(String(localized: "Close Tab", bundle: #bundle), action: close)
            Button(String(localized: "Close Other Tabs", bundle: #bundle), action: closeOthers)
                .disabled(!canMove)
            Button(String(localized: "Move Tab to New Window", bundle: #bundle), action: moveToNewWindow)
                .disabled(!canMove)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: Text("Close Tab", bundle: #bundle), close)
        .accessibilityAction(named: Text("Move Tab to New Window", bundle: #bundle), moveToNewWindow)
    }
}

nonisolated extension FocusedValues {
    /// The key window's tabs.
    @Entry var workspace: Workspace?
}
