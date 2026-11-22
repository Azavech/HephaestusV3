import AppKit
@testable import ChatKit
import Foundation
import Testing
import ToolsFoundation
@testable import ToolsScenes

private let orders = WorkspaceContent.tool(.tickets, project: "ORD")
private let payments = WorkspaceContent.tool(.builds, project: "PAY")

/// A window's tabs: their order, selection and what each keeps (docs/ui/navigation.md › Tabs).
@MainActor
@Suite("Tabs")
struct WorkspaceTests {
    @Test("A window without tabs shows Projects; a selection it doesn't have falls back on the first tab")
    func initial() {
        #expect(Workspace(WorkspaceValue(tabs: [])).tabs.map(\.content) == [.projects])
        let tab = WorkspaceTab(content: orders)
        let workspace = Workspace(WorkspaceValue(tabs: [tab], selection: UUID()))
        #expect(workspace.selectedTab?.id == tab.id)
        #expect(workspace.lastProjectID == "ORD")
    }

    @Test("A new tab goes after the selected one and is selected; closing selects the next, else the one before")
    func addAndRemove() {
        let first = WorkspaceTab(content: .projects)
        let last = WorkspaceTab(content: payments)
        let workspace = Workspace(WorkspaceValue(tabs: [first, last]))
        let added = WorkspaceTab(content: orders)
        workspace.add(added)
        #expect(workspace.tabs.map(\.id) == [first.id, added.id, last.id])
        #expect(workspace.selectedTab?.id == added.id)
        #expect(workspace.remove(added.id)?.id == added.id)
        #expect(workspace.selectedTab?.id == last.id)
        workspace.remove(last.id)
        #expect(workspace.selectedTab?.id == first.id)
        #expect(workspace.remove(UUID()) == nil)
    }

    @Test("The tab bar shows only with two tabs or more")
    func tabBar() {
        let workspace = Workspace(WorkspaceValue(tabs: [WorkspaceTab(content: orders)]))
        #expect(!workspace.showsTabBar)
        let second = WorkspaceTab(content: payments)
        workspace.add(second)
        #expect(workspace.showsTabBar)
        workspace.remove(second.id)
        #expect(!workspace.showsTabBar)
    }

    @Test("Tabs move within bounds, and Next and Previous wrap around")
    func moveAndStep() {
        let tabs = [WorkspaceTab(content: .projects), WorkspaceTab(content: orders), WorkspaceTab(content: payments)]
        let workspace = Workspace(WorkspaceValue(tabs: tabs))
        workspace.move(tabs[0].id, to: 10)
        #expect(workspace.tabs.map(\.id) == [tabs[1].id, tabs[2].id, tabs[0].id])
        workspace.move(tabs[0].id, to: -3)
        #expect(workspace.tabs.map(\.id) == tabs.map(\.id))
        workspace.selectPrevious()
        #expect(workspace.selectedTab?.id == tabs[2].id)
        workspace.selectNext()
        #expect(workspace.selectedTab?.id == tabs[0].id)
    }

    @Test("A tab keeps its tool state while another is in front, until it shows another project or closes")
    func keptState() {
        let tab = WorkspaceTab(content: orders)
        let other = WorkspaceTab(content: payments)
        let workspace = Workspace(WorkspaceValue(tabs: [tab, other]))
        let state = workspace.state(for: tab) { NSObject() }
        workspace.select(other.id)
        workspace.select(tab.id)
        #expect(workspace.state(for: tab) { NSObject() } === state)
        workspace.switchProject(of: tab.id, to: "SHOP")
        let moved = workspace.tab(tab.id)!
        #expect(moved.content == .tool(.tickets, project: "SHOP"))
        #expect(workspace.state(for: moved) { NSObject() } !== state)
        #expect(TabIdentity(moved) != TabIdentity(tab), "The tool's views are made again, on the new state")
        #expect(TabIdentity(workspace.tab(other.id)!) == TabIdentity(other))
        #expect(workspace.lastProjectID == "SHOP")
        workspace.remove(tab.id)
        #expect(!workspace.keepsState(of: tab.id))
    }

    @Test("A tab's reported item is the chat panel's subject and its focus for restoration")
    func reportedItem() {
        let tab = WorkspaceTab(content: orders)
        let workspace = Workspace(WorkspaceValue(tabs: [tab]))
        let subject = ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142")
        workspace.report(subject, in: tab.id)
        #expect(workspace.subjects[tab.id] == subject)
        #expect(workspace.selectedTab?.focus == "ORD-142")
        workspace.switchProject(of: tab.id, to: "PAY")
        #expect(workspace.subjects[tab.id] == nil)
        #expect(workspace.selectedTab?.focus == nil)
    }

    @Test("The chat panel keeps one conversation per project")
    func panels() {
        let workspace = Workspace(WorkspaceValue(tabs: [WorkspaceTab(content: orders)]))
        let store = SampleChatStore.transient()
        let first = workspace.panel(for: "ORD") { ChatPanelModel(chats: store) }
        #expect(workspace.panel(for: "ORD") { ChatPanelModel(chats: store) } === first)
        #expect(workspace.panel(for: "PAY") { ChatPanelModel(chats: store) } !== first)
    }

    @Test("A project's tab is the selected one when it shows it, else the first that does")
    func projectTab() {
        let settings = WorkspaceTab(content: .projectSettings("ORD"))
        let tickets = WorkspaceTab(content: orders)
        let workspace = Workspace(WorkspaceValue(tabs: [settings, tickets], selection: tickets.id))
        #expect(workspace.tab(showingProject: "ORD")?.id == tickets.id)
        workspace.select(settings.id)
        #expect(workspace.tab(showingProject: "ORD")?.id == settings.id)
        #expect(workspace.tab(showing: orders)?.id == tickets.id)
        #expect(workspace.tab(showingProject: "PAY") == nil)
    }

    @Test("The window's value round-trips through its restoration, tabs, focus and selection included")
    func value() throws {
        let tabs = [WorkspaceTab(content: .projects), WorkspaceTab(content: orders, focus: "ORD-142"),
                    WorkspaceTab(content: .projectSettings("ORD")), WorkspaceTab(content: .machines), WorkspaceTab(content: .systemPrompts)]
        let value = WorkspaceValue(tabs: tabs, selection: tabs[1].id)
        let decoded = try JSONDecoder().decode(WorkspaceValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(Workspace(decoded).value == value)
        #expect(WorkspaceContent.systemPrompts.isSingle && WorkspaceContent.systemPrompts.projectID == nil)
        #expect(WorkspaceContent.projects.isSingle && WorkspaceContent.machines.isSingle && WorkspaceContent.projectSettings("ORD").isSingle)
        #expect(!orders.isSingle)
    }
}

/// Routes and the Window menu over the windows' tabs (docs/ui/navigation.md › Window reuse). Windows are
/// ordered far off screen.
@MainActor
@Suite("Window directory")
struct WindowDirectoryTests {
    private func window(_ x: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .automatic
        window.setFrame(NSRect(x: x, y: -20_000, width: 400, height: 300), display: false)
        window.orderBack(nil)
        return window
    }

    @Test("A registered window takes no macOS tabs")
    func noSystemTabs() {
        let window = window(-20_000)
        defer { window.orderOut(nil) }
        WindowDirectory().register(window, workspace: Workspace(.initial))
        #expect(window.tabbingMode == .disallowed)
    }

    @Test("A chat window is found by its chat while it is open or minimised, never as a workspace, and takes no macOS tabs")
    func chatWindows() {
        let directory = WindowDirectory()
        let one = window(-20_000)
        let two = window(-19_000)
        defer {
            one.orderOut(nil)
            two.orderOut(nil)
        }
        directory.register(one, chat: "C1")
        directory.register(two, chat: "C2")
        #expect(directory.chatWindow(showing: "C1") === one && directory.chatWindow(showing: "C2") === two)
        #expect(directory.chatWindow(showing: "C3") == nil)
        #expect(one.tabbingMode == .disallowed)
        #expect(directory.windows().isEmpty, "Routes to tabs never pick a chat window")
        two.orderOut(nil)
        #expect(directory.chatWindow(showing: "C2") == nil, "A closed window shows nothing")
        #expect(ChatWindowValue(chatID: "C1") == (try? JSONDecoder().decode(ChatWindowValue.self, from: JSONEncoder().encode(ChatWindowValue(chatID: "C1")))))
    }

    @Test("A route selects the tab that shows it and asks it for the focus; nothing shows what no tab does")
    func show() {
        let directory = WindowDirectory()
        let one = window(-20_000)
        let two = window(-19_000)
        defer {
            one.orderOut(nil)
            two.orderOut(nil)
        }
        let tickets = WorkspaceTab(content: orders)
        let first = Workspace(WorkspaceValue(tabs: [WorkspaceTab(content: .projects)]))
        let second = Workspace(WorkspaceValue(tabs: [WorkspaceTab(content: payments), tickets]))
        directory.register(one, workspace: first)
        directory.register(two, workspace: second)
        #expect(directory.show(orders, focus: "ORD-142"))
        #expect(second.selectedTab?.id == tickets.id)
        #expect(second.focusRequests[tickets.id] != nil)
        #expect(!directory.show(.tool(.serviceMap, project: "ORD")))
        #expect(directory.window(of: second) === two)
    }

    @Test("A new tab goes into the frontmost window, or into a window of its own when the setting says so")
    func open() {
        let directory = WindowDirectory()
        let window = window(-20_000)
        defer { window.orderOut(nil) }
        let workspace = Workspace(.initial)
        directory.register(window, workspace: workspace)
        var opened: [WorkspaceValue] = []
        directory.open(WorkspaceTab(content: orders)) { opened.append($0) }
        #expect(workspace.tabs.map(\.content) == [.projects, orders])
        #expect(opened.isEmpty)
        directory.opensWindowsAsTabs = false
        directory.open(WorkspaceTab(content: payments)) { opened.append($0) }
        #expect(opened.map { $0.tabs.map(\.content) } == [[payments]])
        #expect(workspace.tabs.count == 2)
    }

    @Test("Without a window, a new tab opens one")
    func openWithoutWindow() {
        _ = NSApplication.shared
        var opened: [WorkspaceValue] = []
        WindowDirectory().open(WorkspaceTab(content: orders)) { opened.append($0) }
        #expect(opened.count == 1)
    }

    @Test("Merge All Windows brings every other window's tabs after the key window's, and closes those windows")
    func merge() {
        let directory = WindowDirectory()
        let one = window(-20_000)
        let two = window(-19_000)
        defer {
            one.orderOut(nil)
            two.orderOut(nil)
        }
        let kept = WorkspaceTab(content: .projects)
        let first = Workspace(WorkspaceValue(tabs: [kept]))
        let second = Workspace(WorkspaceValue(tabs: [WorkspaceTab(content: orders), WorkspaceTab(content: payments)]))
        directory.register(one, workspace: first)
        directory.register(two, workspace: second)
        directory.mergeAll(into: first)
        #expect(first.tabs.map(\.content) == [.projects, orders, payments])
        #expect(first.selectedTab?.id == kept.id)
        #expect(!two.isVisible)
    }
}
