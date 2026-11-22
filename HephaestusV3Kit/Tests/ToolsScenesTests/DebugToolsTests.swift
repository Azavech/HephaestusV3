import AppKit
import Foundation
import MCPKit
import ProjectData
import TicketData
import Testing
@testable import ToolsScenes

/// docs/mcp.md › Debug tools: the window information, the screenshot's file name, the click's bounds. Windows are
/// ordered far off screen, never shown.
@Suite("Debug tools")
@MainActor
struct DebugToolsTests {
    @Test("The UTC time of a screenshot's file name")
    func timestamp() {
        #expect(DebugTools.timestamp(Date(timeIntervalSince1970: 1_793_455_380.123)) == "20261031T140300.123Z")
        #expect(DebugTools.number(812) == "812" && DebugTools.number(812.5) == "812.5")
    }

    @Test("A window's information, a sheet's kind, and a click outside it refused")
    func window() async throws {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Probe"
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let info = DebugTools.info(of: window)
        #expect(info["id"]?.intValue == window.windowNumber)
        #expect(info["kind"] == "other" && info["title"] == "Probe" && info["state"] == .null)
        #expect(info["frame"]?["width"] == .double(window.frame.width))
        #expect(try DebugTools.window(window.windowNumber) === window)
        #expect(throws: ToolError(.notFound, "No window with id -7.")) { _ = try DebugTools.window(-7) }
        let click = DebugTools.click()
        let height = Int(window.frame.height)
        await #expect(throws: ToolError(.invalid, "The point (401, 10) is outside the window \(window.windowNumber), which is 400 × \(height) points.")) {
            _ = try await click.run(["window": .int(window.windowNumber), "x": 401, "y": 10])
        }
    }

    @Test("Listed only with the switch, after open_in_app")
    func registry() {
        let session = ProjectSession(dataFolder: nil)
        let tickets = TicketSession(projects: session, device: "Test")
        #expect(DebugTools.operations(session: session, tickets: tickets) { _ in true }.map(\.name)
            == ["debug_screenshot", "debug_navigate", "debug_ui_state", "debug_click"])
    }
}
