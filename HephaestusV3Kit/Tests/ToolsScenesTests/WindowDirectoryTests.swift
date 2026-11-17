import AppKit
import Testing
@testable import ToolsScenes

/// Window tabs: every window the directory lists can be a tab of any other, names its project in its tab,
/// and takes the tab bar's + itself. Windows are created and never shown.
@MainActor
@Suite("Window tabs")
struct WindowDirectoryTests {
    private func window(title: String = "Tickets") -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    /// The `NewTabResponder`s in the window's responder chain.
    private func newTabResponders(of window: NSWindow) -> [NewTabResponder] {
        var found: [NewTabResponder] = []
        var next = window.nextResponder
        var steps = 0
        while let responder = next, steps < 32 {
            if let newTab = responder as? NewTabResponder {
                found.append(newTab)
            }
            next = responder.nextResponder
            steps += 1
        }
        return found
    }

    @Test("A window, even one SwiftUI made single, joins the app's tabs")
    func joins() {
        let window = window(title: "Projects")
        window.tabbingIdentifier = "SwiftUI-SingleWindow-projects"
        window.tabbingMode = .disallowed
        WindowDirectory().register(window, role: .projects, projectID: nil)
        #expect(window.tabbingIdentifier == WindowDirectory.tabbingIdentifier)
        #expect(window.tabbingMode == .automatic)
    }

    @Test("A tab names the window and its project, or follows the window's title")
    func titles() {
        #expect(WindowDirectory.tabTitle("Tickets", project: "Orders") == "Tickets – Orders")
        let directory = WindowDirectory()
        let window = window()
        directory.register(window, role: .tool(.tickets), projectID: "ORD", tabTitle: "Tickets – Orders")
        #expect(window.tab.title == "Tickets – Orders")
        directory.register(window, role: .tool(.tickets), projectID: "PAY", tabTitle: "Tickets – Payments")
        #expect(window.tab.title == "Tickets – Payments")
        directory.register(window, role: .tool(.tickets), projectID: nil)
        #expect(window.tab.title == "Tickets")
    }

    @Test("The tab bar's + opens what the window's last report gives, ahead of the rest of the chain")
    func newTab() {
        let directory = WindowDirectory()
        let window = window()
        let controller = NSResponder()
        window.nextResponder = controller
        var opened: [String] = []
        directory.register(window, role: .tool(.tickets), projectID: "ORD", newTab: { opened.append("ORD") })
        #expect(window.tryToPerform(#selector(NSResponder.newWindowForTab(_:)), with: nil))
        directory.register(window, role: .tool(.tickets), projectID: "PAY", newTab: { opened.append("PAY") })
        #expect(window.tryToPerform(#selector(NSResponder.newWindowForTab(_:)), with: nil))
        #expect(opened == ["ORD", "PAY"])
        // One responder, just after the window, followed by what followed the window.
        withExtendedLifetime(directory) {
            let responders = newTabResponders(of: window)
            #expect(responders.count == 1)
            #expect(window.nextResponder === responders.first)
            #expect(responders.first?.nextResponder === controller)
        }
    }

    @Test("A window whose + has nothing to open still takes it, so SwiftUI opens no empty window")
    func nothingToOpen() {
        let directory = WindowDirectory()
        let window = window(title: "Projects")
        directory.register(window, role: .projects, projectID: nil)
        withExtendedLifetime(directory) {
            let responder = newTabResponders(of: window).first
            #expect(responder != nil)
            #expect(responder?.open == nil)
            #expect(responder?.responds(to: #selector(NSResponder.newWindowForTab(_:))) == true)
        }
    }

    @Test("The directory keeps the responder while the window lives; the chain doesn't")
    func keptByTheDirectory() {
        let window = window()
        WindowDirectory().register(window, role: .tool(.tickets), projectID: "ORD")
        // A responder chain holds its responders weakly: without the directory, nothing is left to call.
        #expect(newTabResponders(of: window).isEmpty)
    }

    @Test("The app's ask for a window is taken by the next window shown, once; a window not shown leaves it")
    func askedWindow() {
        let directory = WindowDirectory()
        let hidden = window(title: "Closed")
        directory.register(hidden, role: .tool(.tickets), projectID: "ORD")
        directory.willOpenWindow()
        #expect(directory.isExpectingWindow)
        // A closed window SwiftUI still updates isn't the new one.
        directory.register(hidden, role: .tool(.tickets), projectID: "ORD")
        #expect(directory.isExpectingWindow)
        let shown = window(title: "Builds")
        shown.setFrame(NSRect(x: -20_000, y: -20_000, width: 400, height: 300), display: false)
        shown.orderBack(nil)
        defer { shown.orderOut(nil) }
        directory.register(shown, role: .tool(.builds), projectID: "ORD")
        #expect(!directory.isExpectingWindow)
        // With no other window shown, it stays a window of its own.
        #expect((shown.tabGroup?.windows.count ?? 1) == 1)
    }

    @Test("The window asked for becomes a tab of the frontmost window, or a window of its own when the setting says so",
          arguments: [true, false])
    func asTab(opensWindowsAsTabs: Bool) {
        let directory = WindowDirectory()
        directory.opensWindowsAsTabs = opensWindowsAsTabs
        let front = window(title: "Projects")
        front.setFrame(NSRect(x: -20_000, y: -20_000, width: 700, height: 500), display: false)
        front.orderBack(nil)
        let new = window(title: "Tickets")
        defer {
            new.orderOut(nil)
            front.orderOut(nil)
        }
        directory.register(front, role: .projects, projectID: nil)
        directory.willOpenWindow()
        new.setFrame(NSRect(x: -19_000, y: -19_000, width: 400, height: 300), display: false)
        new.orderBack(nil)
        directory.register(new, role: .tool(.tickets), projectID: "ORD", tabTitle: "Tickets – Orders")
        if opensWindowsAsTabs {
            #expect(front.tabGroup?.windows == [front, new])
            #expect(front.tabGroup?.selectedWindow === new)
        } else {
            #expect((new.tabGroup?.windows.count ?? 1) == 1)
        }
    }

    @Test("A window shown when the app asks isn't the new one")
    func openWindowsAreNotNew() {
        let directory = WindowDirectory()
        let front = window(title: "Projects")
        front.setFrame(NSRect(x: -20_000, y: -20_000, width: 400, height: 300), display: false)
        front.orderBack(nil)
        defer { front.orderOut(nil) }
        directory.register(front, role: .projects, projectID: nil)
        directory.willOpenWindow()
        directory.register(front, role: .projects, projectID: "ORD")
        #expect(directory.isExpectingWindow)
    }

    @Test("A responder something else moved further along the chain isn't added a second time")
    func onceInTheChain() {
        let directory = WindowDirectory()
        let window = window()
        directory.register(window, role: .tool(.tickets), projectID: "ORD")
        let other = NSResponder()
        other.nextResponder = window.nextResponder
        window.nextResponder = other
        directory.register(window, role: .tool(.tickets), projectID: "ORD")
        withExtendedLifetime(directory) {
            #expect(window.nextResponder === other)
            #expect(newTabResponders(of: window).count == 1)
        }
    }
}
