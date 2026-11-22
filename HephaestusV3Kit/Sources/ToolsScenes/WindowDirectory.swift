import AppKit
import SwiftUI
import ToolsFoundation

/// The app's windows and their tabs, so that a route selects a tab already showing what it asks for, and
/// brings its window forward, out of the Dock if it was minimised, instead of opening a second one
/// (docs/ui/navigation.md › Window reuse).
///
/// Each window reports itself, with its `Workspace`, when it appears and at each update. The app draws its
/// own tabs (docs/ui/navigation.md › Tabs): macOS's window tabs are off.
final class WindowDirectory {
    static let shared = WindowDirectory()

    /// Whether a tab the app opens goes into the frontmost window rather than a window of its own
    /// (Settings ▸ General, `AppData.opensWindowsAsTabs`).
    var opensWindowsAsTabs = true

    private struct Entry {
        weak var window: NSWindow?
        weak var workspace: Workspace?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private struct ChatEntry {
        weak var window: NSWindow?
        let chatID: String
    }

    /// The chat windows, each showing one chat.
    private var chatEntries: [ObjectIdentifier: ChatEntry] = [:]

    /// Lists a chat window with its chat.
    func register(_ window: NSWindow, chat chatID: String) {
        chatEntries[ObjectIdentifier(window)] = ChatEntry(window: window, chatID: chatID)
        if window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
        }
    }

    /// The chat a chat window shows.
    func chatID(of window: NSWindow) -> String? {
        chatEntries[ObjectIdentifier(window)].flatMap { $0.window === window ? $0.chatID : nil }
    }

    /// The chat window showing the chat, minimised or not.
    func chatWindow(showing chatID: String) -> NSWindow? {
        chatEntries = chatEntries.filter { $0.value.window != nil }
        return chatEntries.values.first { entry in
            guard let window = entry.window else { return false }
            return entry.chatID == chatID && (window.isVisible || window.isMiniaturized)
        }?.window
    }

    /// Lists `window` with its tabs, or updates it.
    func register(_ window: NSWindow, workspace: Workspace) {
        entries[ObjectIdentifier(window)] = Entry(window: window, workspace: workspace)
        // The app's tab bar replaces macOS's tabs, which would also put the sidebar beside the tab bar.
        if window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
        }
    }

    /// The open windows with their tabs, front to back, minimised windows last.
    func windows() -> [(window: NSWindow, workspace: Workspace)] {
        entries = entries.filter { $0.value.window != nil && $0.value.workspace != nil }
        // `NSApp` is nil until an application exists, as in a test that makes no window.
        let order = NSApp?.orderedWindows ?? []
        return entries.values
            .compactMap { entry -> (NSWindow, Workspace)? in
                guard let window = entry.window, let workspace = entry.workspace, window.isVisible || window.isMiniaturized else { return nil }
                return (window, workspace)
            }
            .sorted { rank($0.0, in: order) < rank($1.0, in: order) }
    }

    private func rank(_ window: NSWindow, in order: [NSWindow]) -> Int {
        order.firstIndex(of: window) ?? Int.max
    }

    /// The frontmost window, the one a new tab goes into.
    func frontmost() -> (window: NSWindow, workspace: Workspace)? {
        windows().first { !$0.window.isMiniaturized } ?? windows().first
    }

    /// The window of a workspace.
    func window(of workspace: Workspace) -> NSWindow? {
        windows().first { $0.workspace === workspace }?.window
    }

    /// Selects the tab that `find` picks in the frontmost window that has one, gives it `focus`, and brings
    /// its window forward. False when no window has such a tab.
    @discardableResult
    func show(where find: (Workspace) -> WorkspaceTab?, focus: String? = nil) -> Bool {
        for (window, workspace) in windows() {
            guard let tab = find(workspace) else { continue }
            workspace.select(tab.id)
            if let focus {
                workspace.request(focus, in: tab.id)
            }
            Self.show(window)
            return true
        }
        return false
    }

    /// Selects the tab that shows `content`, as `show(where:focus:)`.
    @discardableResult
    func show(_ content: WorkspaceContent, focus: String? = nil) -> Bool {
        show(where: { $0.tab(showing: content) }, focus: focus)
    }

    /// Opens a tab: in the frontmost window when `opensWindowsAsTabs` and a window is open, else in a new
    /// window, which `newWindow` opens.
    func open(_ tab: WorkspaceTab, newWindow: (WorkspaceValue) -> Void) {
        if opensWindowsAsTabs, let front = frontmost() {
            front.workspace.add(tab)
            Self.show(front.window)
        } else {
            newWindow(WorkspaceValue(tabs: [tab]))
            Self.activate()
        }
    }

    /// Opens a tab, a new window with SwiftUI's `openWindow`.
    func open(_ tab: WorkspaceTab, openWindow: OpenWindowAction) {
        open(tab) { openWindow(id: SceneID.workspace, value: $0) }
    }

    /// Opens `content` where a route would: its tab when one is open, else a new tab.
    func showOrOpen(_ content: WorkspaceContent, focus: String? = nil, openWindow: OpenWindowAction) {
        if !show(content, focus: focus) {
            open(WorkspaceTab(content: content, focus: focus), openWindow: openWindow)
        }
    }

    /// Window ▸ Merge All Windows: every other window's tabs, in window order, after `workspace`'s; those
    /// windows close. The selected tab stays selected.
    func mergeAll(into workspace: Workspace) {
        let selected = workspace.selectedTab?.id
        for (window, other) in windows() where other !== workspace {
            for tab in other.tabs {
                workspace.add(tab)
            }
            window.close()
        }
        if let selected {
            workspace.select(selected)
        }
    }

    /// Makes `window` the key window of the active app.
    static func show(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Activates the app after SwiftUI opened a window, for a route sent from the menu bar while another app
    /// was in front.
    static func activate() {
        NSApp.activate()
    }

    /// A tab's title: the window's, then its project's name, such as "Tickets – Orders".
    static func tabTitle(_ window: String, project: String) -> String {
        String(localized: "\(window) – \(project)", bundle: #bundle, comment: "A window's tab title: the window, then its project, such as Tickets – Orders")
    }
}

/// Reports the window its view is in, when the view moves into it and at each update.
struct WindowReader: NSViewRepresentable {
    let report: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.report = report
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.report = report
        if let window = view.window {
            report(window)
        }
    }

    final class ReaderView: NSView {
        var report: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                report?(window)
            }
        }
    }
}
