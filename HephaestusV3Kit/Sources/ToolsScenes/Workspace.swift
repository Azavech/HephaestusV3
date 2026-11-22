import ChatKit
import Foundation
import Observation
import ToolsFoundation

/// What a tab shows (docs/ui/navigation.md › Tabs).
nonisolated enum WorkspaceContent: Codable, Hashable, Sendable {
    /// The project selector; one in the whole app.
    case projects
    /// A tool for a project.
    case tool(ToolKind, project: Project.ID)
    /// A project's settings; one per project in the whole app.
    case projectSettings(Project.ID)
    /// The Mac's virtual machines; one in the whole app.
    case machines
    /// The internal skills' content; one in the whole app.
    case systemPrompts
    /// Claude's memories, global and per project; one in the whole app.
    case memories

    /// The project the tab shows, if it shows one by itself.
    var projectID: Project.ID? {
        switch self {
        case .tool(_, let project): project
        case .projectSettings(let project): project
        case .projects, .machines, .systemPrompts, .memories: nil
        }
    }

    /// The tool, for a tool's tab.
    var tool: ToolKind? {
        if case .tool(let tool, _) = self { tool } else { nil }
    }

    /// Projects, a project's settings, Virtual Machines and System Prompts are each in one tab of the app at
    /// most: a route selects that tab, and New Tab and New Window make none.
    var isSingle: Bool {
        tool == nil
    }
}

/// One tab of a window: what it shows, and the item it has selected.
nonisolated struct WorkspaceTab: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var content: WorkspaceContent
    /// The item the tab has selected, as a route's focus (`ORD-142`, `service:payments-api`); the tab's
    /// tool starts on it when the window is restored.
    var focus: String?
}

/// A window's tabs and the selected one: the window's scene value, which macOS restores.
nonisolated struct WorkspaceValue: Codable, Hashable, Sendable {
    var tabs: [WorkspaceTab]
    var selection: WorkspaceTab.ID?

    init(tabs: [WorkspaceTab], selection: WorkspaceTab.ID? = nil) {
        self.tabs = tabs
        self.selection = selection ?? tabs.first?.id
    }

    /// A window with one tab.
    init(_ content: WorkspaceContent, focus: String? = nil) {
        self.init(tabs: [WorkspaceTab(content: content, focus: focus)])
    }

    /// A window with no value (the first window at launch) shows Projects.
    static let initial = WorkspaceValue(.projects)
}

/// One window's tabs (docs/ui/navigation.md › Tabs): their order and selection, what each tab keeps while
/// another is in front, the routes' asks, and the chat panel's conversations, one per project.
///
/// Only the selected tab's tool is drawn: each tab's tool model is kept here (`state(for:make:)`) and handed
/// back when the tab comes back, so its selection, filters and drafts are still there.
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [WorkspaceTab]
    private(set) var selection: WorkspaceTab.ID?
    /// The item each tab's tool has selected, which the chat panel asks about.
    private(set) var subjects: [WorkspaceTab.ID: ChatReference] = [:]
    /// A route's ask to select an item in a tab that is already open.
    private(set) var focusRequests: [WorkspaceTab.ID: FocusRequest] = [:]
    /// The project of the last selected tab that showed one: the chat panel's, in a tab that shows none.
    private(set) var lastProjectID: Project.ID?

    /// Each tab's tool state, made the first time the tab is drawn on its project.
    @ObservationIgnored private var states: [WorkspaceTab.ID: (content: WorkspaceContent, state: AnyObject)] = [:]
    /// The chat panel's conversation and draft for each project the window has shown.
    @ObservationIgnored private var panels: [Project.ID: ChatPanelModel] = [:]

    init(_ value: WorkspaceValue) {
        let tabs = value.tabs.isEmpty ? WorkspaceValue.initial.tabs : value.tabs
        self.tabs = tabs
        selection = tabs.contains { $0.id == value.selection } ? value.selection : tabs.first?.id
        lastProjectID = selectedTab?.content.projectID
    }

    /// What the window keeps for its restoration.
    var value: WorkspaceValue {
        WorkspaceValue(tabs: tabs, selection: selection)
    }

    /// The tab bar shows only while the window has two tabs or more (the user's choice).
    var showsTabBar: Bool {
        tabs.count > 1
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selection } ?? tabs.first
    }

    func tab(_ id: WorkspaceTab.ID) -> WorkspaceTab? {
        tabs.first { $0.id == id }
    }

    // MARK: Changing the tabs

    func select(_ id: WorkspaceTab.ID) {
        guard let tab = tab(id) else { return }
        selection = id
        if let project = tab.content.projectID {
            lastProjectID = project
        }
    }

    /// Selects the tab after the selected one, the first after the last.
    func selectNext() {
        step(1)
    }

    /// Selects the tab before the selected one, the last before the first.
    func selectPrevious() {
        step(-1)
    }

    private func step(_ offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTab?.id }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// Adds a tab after the selected one, and selects it.
    func add(_ tab: WorkspaceTab) {
        let index = tabs.firstIndex { $0.id == selectedTab?.id }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        select(tab.id)
    }

    /// Takes a tab out of the window, with what it keeps; the next tab, or else the one before, is selected.
    /// Nil when the window doesn't have it.
    @discardableResult
    func remove(_ id: WorkspaceTab.ID) -> WorkspaceTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        states[id] = nil
        subjects[id] = nil
        focusRequests[id] = nil
        if selection == id, !tabs.isEmpty {
            select(tabs[min(index, tabs.count - 1)].id)
        }
        return tab
    }

    /// Moves a tab to `index` among the tabs (before the tab at that index, or last).
    func move(_ id: WorkspaceTab.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(index, tabs.count)))
    }

    /// Shows another project in a tab: its tool starts afresh there, without the old selection.
    func switchProject(of id: WorkspaceTab.ID, to project: Project.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), case .tool(let tool, let current) = tabs[index].content,
              current != project else { return }
        tabs[index].content = .tool(tool, project: project)
        tabs[index].focus = nil
        states[id] = nil
        subjects[id] = nil
        focusRequests[id] = nil
        if selection == id {
            lastProjectID = project
        }
    }

    /// The tab's tool reports the item it has selected: the chat panel asks about it, and the window keeps
    /// it for its restoration.
    func report(_ subject: ChatReference?, in id: WorkspaceTab.ID) {
        subjects[id] = subject
        if let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].focus != subject?.focus, subject != nil {
            tabs[index].focus = subject?.focus
        }
    }

    /// A route's focus for an open tab: its tool selects it without starting afresh.
    func request(_ focus: String, in id: WorkspaceTab.ID) {
        focusRequests[id] = FocusRequest(focus)
    }

    // MARK: What tabs keep

    /// The tool state of a tab on its current content: the one kept, or a new one from `make`.
    func state<State: AnyObject>(for tab: WorkspaceTab, make: () -> State) -> State {
        if let kept = states[tab.id], kept.content == tab.content, let state = kept.state as? State {
            return state
        }
        let state = make()
        states[tab.id] = (tab.content, state)
        return state
    }

    /// Whether a tab's tool state is kept: for tests.
    func keepsState(of id: WorkspaceTab.ID) -> Bool {
        states[id] != nil
    }

    /// The chat panel's conversation for a project: the one kept, or a new one from `make`.
    func panel(for project: Project.ID, make: () -> ChatPanelModel) -> ChatPanelModel {
        if let panel = panels[project] {
            return panel
        }
        let panel = make()
        panels[project] = panel
        return panel
    }

    // MARK: Finding tabs

    /// The tab that shows `content`: for a tool, the first tab of that tool and project.
    func tab(showing content: WorkspaceContent) -> WorkspaceTab? {
        tabs.first { $0.content == content }
    }

    /// The first tab that shows `project`, whatever it is: a tool's or its settings.
    func tab(showingProject project: Project.ID) -> WorkspaceTab? {
        if selectedTab?.content.projectID == project {
            return selectedTab
        }
        return tabs.first { $0.content.projectID == project }
    }
}
