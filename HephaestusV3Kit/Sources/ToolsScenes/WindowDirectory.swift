import AppKit
import SwiftUI
import ToolsFoundation

/// The app's windows and what each shows, so that a route brings forward a window already showing
/// what it asks for, out of the Dock if it was minimised, instead of opening a second one.
///
/// Each window reports itself with `WindowReader` when it appears and again whenever what it shows
/// changes, e.g. when its project switcher picks another project.
final class WindowDirectory {
    static let shared = WindowDirectory()

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
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ window: NSWindow, role: Role, projectID: Project.ID?, select: ((String) -> Void)? = nil) {
        entries[ObjectIdentifier(window)] = Entry(window: window, role: role, projectID: projectID, select: select)
    }

    /// The frontmost window that matches, minimised windows after the others; nil when none is
    /// open. `role` nil matches any window of the project.
    private func entry(role: Role?, projectID: Project.ID?) -> Entry? {
        entries = entries.filter { $0.value.window != nil }
        let order = NSApp.orderedWindows
        return entries.values
            .filter { entry in
                guard let window = entry.window, window.isVisible || window.isMiniaturized else { return false }
                return (role == nil || entry.role == role) && (projectID == nil || entry.projectID == projectID)
            }
            .min { rank($0.window, in: order) < rank($1.window, in: order) }
    }

    private func rank(_ window: NSWindow?, in order: [NSWindow]) -> Int {
        window.flatMap { order.firstIndex(of: $0) } ?? Int.max
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

    /// Makes `window` the key window of the active app.
    static func show(_ window: NSWindow) {
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
    /// Lists the window this view is in with the `WindowDirectory`.
    func registersWindow(
        _ role: WindowDirectory.Role, projectID: Project.ID?, select: ((String) -> Void)? = nil
    ) -> some View {
        background {
            WindowReader { window in
                WindowDirectory.shared.register(window, role: role, projectID: projectID, select: select)
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}
