import AppKit
import Foundation
import Testing
import ToolsFoundation
@testable import ToolsScenes

/// The status bar's feedback: the context line, the window's capture, and the sheet's request. Windows are
/// created and never shown.
@MainActor
@Suite("Feedback")
struct FeedbackTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Tickets"
        window.contentView = NSView()
        return window
    }

    @Test("The context line names the app, macOS, the window, then the project and the item when there are some")
    func contextLine() {
        let orders = Project.sample("ORD")!
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        #expect(FeedbackSource(window: "Tickets", project: orders, item: "ORD-142").contextLine(version: "1.0.18", build: "40", system: system)
            == "App: Hephaestus V3 1.0.18 (40) · macOS 27.2 · Window: Tickets · Project: Orders (ORD) · Item: ORD-142")
        let patched = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)
        #expect(FeedbackSource(window: "Virtual Machines", project: nil).contextLine(version: "1.0", build: "1", system: patched)
            == "App: Hephaestus V3 1.0 (1) · macOS 27.2.1 · Window: Virtual Machines")
    }

    @Test("A window's capture is a PNG of its frame at its backing scale")
    func capture() throws {
        let window = window()
        let png = try #require(WindowCapture.capture(window))
        let image = try #require(NSBitmapImageRep(data: png))
        let frame = try #require(window.contentView?.superview).bounds
        let scale = window.backingScaleFactor
        #expect(image.pixelsWide == Int((frame.width * scale).rounded(.up)))
        #expect(image.pixelsHigh == Int((frame.height * scale).rounded(.up)))
        #expect(WindowCapture.hostWindow(of: window) === window)
    }

    @Test("A window drawn over the captured one goes at its place on screen")
    func placement() {
        let rect = WindowCapture.placement(of: NSRect(x: 150, y: 220, width: 300, height: 200), in: NSRect(x: 100, y: 200, width: 800, height: 600))
        #expect(rect == NSRect(x: 50, y: 20, width: 300, height: 200))
    }

    @Test("Feedback captures the window into a temporary folder, which closing the sheet deletes")
    func request() throws {
        let window = window()
        let feedback = FeedbackStarter()
        feedback.window = window
        let source = FeedbackSource(window: "Tickets", project: Project.sample("ORD"), item: "ORD-142")
        feedback.start(source, isOn: false)
        #expect(feedback.request == nil)
        feedback.start(source, isOn: true)
        let request = try #require(feedback.request)
        let screenshot = try #require(request.screenshot)
        #expect(screenshot.lastPathComponent == "screenshot.png")
        #expect(NSBitmapImageRep(data: try Data(contentsOf: screenshot)) != nil)
        #expect(request.context.hasSuffix("Window: Tickets · Project: Orders (ORD) · Item: ORD-142"))
        // A second start while the sheet is open changes nothing.
        feedback.start(source, isOn: true)
        #expect(feedback.request?.id == request.id)
        feedback.finish(request)
        #expect(feedback.request == nil)
        #expect(!FileManager.default.fileExists(atPath: request.folder.path))
    }

    @Test("Without its window, feedback doesn't start")
    func noWindow() {
        let feedback = FeedbackStarter()
        feedback.start(FeedbackSource(window: "Projects", project: nil), isOn: true)
        #expect(feedback.request == nil)
    }
}
