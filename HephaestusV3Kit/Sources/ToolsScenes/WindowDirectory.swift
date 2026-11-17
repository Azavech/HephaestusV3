import AppKit
import SwiftUI
import ToolsFoundation

/// The app's windows and what each shows, so that a route brings forward a window already showing
/// what it asks for, out of the Dock if it was minimised, instead of opening a second one.
///
/// Each window reports itself with `WindowReader` when it appears and again whenever what it shows
/// changes, e.g. when its project switcher picks another project.
///
/// Every window it lists can share one window's tabs, as in Safari: Window ▸ Merge All Windows gathers
/// them, Move Tab to New Window or a drag takes one out again. AppKit adds those menu items and the tab
/// bar; the directory gives the windows one tabbing identifier, a tab title that names their project and
/// the tab bar's + (`NewTabResponder`).
final class WindowDirectory {
    static let shared = WindowDirectory()

    /// The tabbing identifier of every window it lists, so that any of them can be a tab of any other.
    /// SwiftUI gives each scene its own, which only lets windows of one tool merge.
    static let tabbingIdentifier = "fr.azavech.hephaestusv3.windows"

    /// Whether a window the app opens becomes a tab of the frontmost window rather than a window of its own
    /// (Settings ▸ General, `AppData.opensWindowsAsTabs`).
    var opensWindowsAsTabs = true

    /// How long after `willOpenWindow()` a new window is taken as the one asked for.
    static let newWindowDelay: TimeInterval = 3

    /// The app's ask for a window: the windows open when it asked, which aren't the new one, and until when
    /// it holds.
    private var newWindowRequest: (open: Set<ObjectIdentifier>, until: Date)?

    /// Whether the app has asked for a window that hasn't appeared yet.
    var isExpectingWindow: Bool { newWindowRequest != nil }

    /// What a window is.
    enum Role: Hashable {
        case projects
        case machines
        case tool(ToolKind)
        /// A project's Project Settings window.
        case projectSettings
    }

    private struct Entry {
        weak var window: NSWindow?
        var role: Role
        /// The project the window shows: the tool's, or the one selected in the Projects window.
        var projectID: Project.ID?
        /// Selects a tool-specific id in the window, as a route's focus does when it opens one.
        var select: ((String) -> Void)?
        /// The window's tab bar +. Kept here as long as the window lives, since a responder chain doesn't
        /// retain its responders.
        let newTab: NewTabResponder
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// A tab's title: the window's, then its project's name, such as "Tickets – Orders".
    static func tabTitle(_ window: String, project: String) -> String {
        String(localized: "\(window) – \(project)", bundle: #bundle, comment: "A window's tab title: the window, then its project, such as Tickets – Orders")
    }

    /// Lists `window` with what it shows, or updates it. `tabTitle` names its tab, nil for the window's
    /// title; `newTab` is what the tab bar's + opens beside it, nil where + has nothing to open.
    func register(
        _ window: NSWindow, role: Role, projectID: Project.ID?, tabTitle: String? = nil,
        newTab: (() -> Void)? = nil, select: ((String) -> Void)? = nil
    ) {
        let key = ObjectIdentifier(window)
        // An entry left by a window gone since, at the same address, isn't this window's.
        let known = entries[key].flatMap { $0.window === window ? $0 : nil }
        let responder = known?.newTab ?? NewTabResponder()
        responder.open = newTab
        entries[key] = Entry(window: window, role: role, projectID: projectID, select: select, newTab: responder)
        Self.joinTabs(window, title: tabTitle, newTab: responder)
        // The new window is shown by the time it reports; a closed window SwiftUI still updates isn't it.
        if let request = newWindowRequest, !request.open.contains(key), window.isVisible {
            newWindowRequest = nil
            if opensWindowsAsTabs, Date.now < request.until {
                addAsTab(window)
            }
        }
    }

    /// Called just before the app opens a window the user asked for (a route, ⌘N, the Window menu), so that
    /// the next window to appear becomes a tab of the frontmost one when `opensWindowsAsTabs`. Windows macOS
    /// restores at launch aren't asked for, and keep their places. The tab bar's + doesn't ask either: AppKit
    /// makes its window a tab.
    func willOpenWindow(now: Date = .now) {
        let open = entries.filter { $0.value.window.map(Self.isOpen) ?? false }.keys
        newWindowRequest = (Set(open), now.addingTimeInterval(Self.newWindowDelay))
    }

    /// Makes `window` a tab of the frontmost other window of the directory, and selects it; nothing when it
    /// is a tab already or no other window is shown.
    private func addAsTab(_ window: NSWindow) {
        guard (window.tabGroup?.windows.count ?? 1) <= 1 else { return }
        let front = NSApp.orderedWindows.first { other in
            other !== window && other.isVisible && !other.isMiniaturized && entries[ObjectIdentifier(other)]?.window === other
        }
        guard let front else { return }
        front.addTabbedWindow(window, ordered: .above)
        window.tabGroup?.selectedWindow = window
    }

    /// Lets `window` be a tab of any other window of the app, names its tab, and puts `newTab` in its
    /// responder chain just after it, ahead of SwiftUI's window controller.
    static func joinTabs(_ window: NSWindow, title: String?, newTab: NewTabResponder) {
        if window.tabbingIdentifier != tabbingIdentifier {
            window.tabbingIdentifier = tabbingIdentifier
        }
        // SwiftUI's single windows (Projects, Virtual Machines) start with tabs disallowed.
        if window.tabbingMode != .automatic {
            window.tabbingMode = .automatic
        }
        if let title {
            if window.tab.title != title {
                window.tab.title = title
            }
        } else if window.tab.title != window.title {
            // Back to following the window's title.
            window.tab.title = nil
        }
        // Once only: a responder already in the chain, even further along it, is left where it is.
        var next = window.nextResponder
        var steps = 0
        while let responder = next, steps < 32 {
            if responder === newTab { return }
            next = responder.nextResponder
            steps += 1
        }
        newTab.nextResponder = window.nextResponder
        window.nextResponder = newTab
    }

    /// The frontmost window that matches, minimised windows after the others; nil when none is
    /// open. `role` nil matches any window of the project.
    private func entry(role: Role?, projectID: Project.ID?) -> Entry? {
        entries = entries.filter { $0.value.window != nil }
        let order = NSApp.orderedWindows
        return entries.values
            .filter { entry in
                guard let window = entry.window, Self.isOpen(window) else { return false }
                return (role == nil || entry.role == role) && (projectID == nil || entry.projectID == projectID)
            }
            .min { rank($0.window, in: order) < rank($1.window, in: order) }
    }

    /// Shown, minimised, or a tab of a minimised window.
    private static func isOpen(_ window: NSWindow) -> Bool {
        if window.isVisible || window.isMiniaturized {
            return true
        }
        guard let group = window.tabGroup, group.windows.contains(window) else { return false }
        return group.selectedWindow?.isMiniaturized == true
    }

    /// A tab behind another ranks just after the tab in front of it.
    private func rank(_ window: NSWindow?, in order: [NSWindow]) -> Int {
        guard let window else { return Int.max }
        if let index = order.firstIndex(of: window) {
            return index * 2
        }
        if let front = window.tabGroup?.selectedWindow, let index = order.firstIndex(of: front) {
            return index * 2 + 1
        }
        return Int.max
    }

    /// Brings a window that matches forward, out of the Dock if it was minimised. False when none is
    /// open. `focus` is selected in a tool window it brings forward.
    @discardableResult
    func bringForward(role: Role?, projectID: Project.ID?, focus: String? = nil) -> Bool {
        guard let entry = entry(role: role, projectID: projectID), let window = entry.window else { return false }
        if let focus {
            entry.select?(focus)
        }
        Self.show(window)
        return true
    }

    /// Makes `window` the key window of the active app: the selected tab when it is a tab.
    static func show(_ window: NSWindow) {
        if let group = window.tabGroup, group.windows.contains(window) {
            if let front = group.selectedWindow, front !== window, front.isMiniaturized {
                front.deminiaturize(nil)
            }
            group.selectedWindow = window
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Activates the app after SwiftUI opened a window, for a route sent from the menu bar while
    /// another app was in front.
    static func activate() {
        NSApp.activate()
    }
}

/// The tab bar's + of one window, ahead of SwiftUI's window controller in the responder chain. The
/// controller would open the window's scene without its value: a tool window without a project, or a
/// second Projects window. AppKit makes the window opened here a new tab beside the one in front.
final class NewTabResponder: NSResponder {
    /// What + opens; nil where it has nothing to open, and + beeps.
    var open: (() -> Void)?

    override func newWindowForTab(_ sender: Any?) {
        if let open {
            open()
        } else {
            NSSound.beep()
        }
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

extension View {
    /// Lists the window this view is in with the `WindowDirectory`: what it shows, its tab's title (nil
    /// for the window's title) and what the tab bar's + opens beside it (nil for nothing).
    func registersWindow(
        _ role: WindowDirectory.Role, projectID: Project.ID?, tabTitle: String? = nil,
        newTab: (() -> Void)? = nil, select: ((String) -> Void)? = nil
    ) -> some View {
        background {
            WindowReader { window in
                WindowDirectory.shared.register(
                    window, role: role, projectID: projectID, tabTitle: tabTitle, newTab: newTab, select: select
                )
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}
