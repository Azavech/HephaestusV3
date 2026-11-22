import AppKit
import Foundation
import MCPKit
import ProjectData
import TicketData
import ToolsFoundation

/// V2's debug tools (docs/mcp.md › Debug tools): see, navigate and click the app's windows from an MCP client, for
/// automated checks, without Screen Recording or Accessibility permission. Listed only when the app was launched with
/// `HEPHAESTUS_DEBUG_TOOLS=1`; they act on this app's own windows.
@MainActor
enum DebugTools {
    /// Whether the app was launched with the debug tools.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["HEPHAESTUS_DEBUG_TOOLS"] == "1"
    }

    /// How long `debug_click` waits after the mouse up, so the effects it starts are in its answer.
    static let clickSettle: Duration = .milliseconds(500)

    static func operations(session: ProjectSession, tickets: TicketSession, open: @escaping @MainActor (Route) -> Bool) -> [ToolOperation] {
        [screenshot(session: session), navigate(session: session, tickets: tickets, open: open), uiState(), click()]
    }

    // MARK: Tools

    static func screenshot(session: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "debug_screenshot",
            description: "Debug: capture a Hephaestus V3 window of this Mac to a PNG file, without screen-recording permission, and return its path and size in pixels. window is an id from debug_ui_state; the key window when omitted.",
            inputSchema: .object(properties: [("window", .integer("Window id from debug_ui_state; the key window when omitted."))]),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Captured a window of Hephaestus", bundle: #bundle)) }
        ) { @MainActor arguments throws(ToolError) in
            let window = try window(arguments["window"]?.intValue)
            guard let png = WindowCapture.capture(window), let image = NSBitmapImageRep(data: png) else {
                throw ToolError(.internal, "The window couldn't be rendered.")
            }
            guard let data = session.dataFolder?.url else { throw ToolError(.unavailable, "The app has no data folder.") }
            let folder = data.appendingPathComponent("Runtime/screenshots")
            let file = folder.appendingPathComponent("\(window.windowNumber)-\(timestamp()).png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: file)
            } catch {
                throw ToolError(.internal, "The PNG couldn't be written: \(error.localizedDescription)")
            }
            return ["path": .string(file.path), "width": .int(image.pixelsWide), "height": .int(image.pixelsHigh)]
        }
    }

    static func navigate(session: ProjectSession, tickets: TicketSession, open: @escaping @MainActor (Route) -> Bool) -> ToolOperation {
        ToolOperation(
            name: "debug_navigate",
            description: "Debug: show a target in Hephaestus V3, as open_in_app does, and return the information of the window that shows it once it is updated.",
            inputSchema: .object(properties: [("target", AppTools.targetSchema)], required: ["target"]),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Opened a window of Hephaestus", bundle: #bundle)) }
        ) { @MainActor arguments throws(ToolError) in
            guard let target = arguments["target"] else { throw ToolError(.invalid, "target: required.") }
            let route = try AppTools.route(of: target, session: session, tickets: tickets)
            guard open(route) else { throw ToolError(.unavailable, "The app has no window to show it in.") }
            // The window opens or comes forward, then draws its new state: at most 10 s.
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                if let front = WindowDirectory.shared.frontmost()?.window, front.isVisible { return info(of: front) }
            }
            throw ToolError(.unavailable, "No window showed the target within 10 seconds.")
        }
    }

    static func uiState() -> ToolOperation {
        ToolOperation(
            name: "debug_ui_state",
            description: "Debug: list the Hephaestus V3 windows of this Mac from front to back with their id, kind, title, key state, frame and state (tabs and selected tab, or chat).",
            inputSchema: .object(),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Read the windows of Hephaestus", bundle: #bundle)) }
        ) { @MainActor _ throws(ToolError) in
            ["windows": .array(windows().map(info(of:)))]
        }
    }

    static func click() -> ToolOperation {
        ToolOperation(
            name: "debug_click",
            description: "Debug: click once with the left mouse button at a point of a Hephaestus V3 window of this Mac, inside the app, without Accessibility permission, and return the windows as debug_ui_state does, 500 ms after the click. window is an id from debug_ui_state; x and y are points from the top-left corner of that window's debug_screenshot image (image pixels divided by the image width over the window's frame width).",
            inputSchema: .object(properties: [
                ("window", .integer("Window id from debug_ui_state.")),
                ("x", .integer("Points from the left edge of the window's debug_screenshot image.", minimum: 0)),
                ("y", .integer("Points from the top edge of the window's debug_screenshot image.", minimum: 0)),
            ], required: ["window", "x", "y"]),
            permission: .read,
            describe: { _ in ToolCallText(action: String(localized: "Clicked in a window of Hephaestus", bundle: #bundle)) }
        ) { @MainActor arguments throws(ToolError) in
            let window = try window(arguments["window"]?.intValue)
            let x = arguments["x"]?.intValue ?? 0
            let y = arguments["y"]?.intValue ?? 0
            let host = WindowCapture.hostWindow(of: window)
            let size = host.frame.size
            guard CGFloat(x) <= size.width, CGFloat(y) <= size.height else {
                throw ToolError(.invalid, "The point (\(x), \(y)) is outside the window \(window.windowNumber), which is \(number(size.width)) × \(number(size.height)) points.")
            }
            // In screen coordinates, then in the frontmost of the window and its sheets that holds the point.
            let screenPoint = NSPoint(x: host.frame.minX + CGFloat(x), y: host.frame.maxY - CGFloat(y))
            let target = ([host] + WindowCapture.overlayWindows(of: host)).last { $0.frame.contains(screenPoint) } ?? host
            send(click: target.convertPoint(fromScreen: screenPoint), to: target)
            try? await Task.sleep(for: clickSettle)
            return ["windows": .array(windows().map(info(of:)))]
        }
    }

    // MARK: Windows

    /// The app's visible windows, front to back, each followed by its sheets.
    static func windows() -> [NSWindow] {
        var result: [NSWindow] = []
        for window in NSApp.orderedWindows where window.isVisible && window.sheetParent == nil {
            result.append(window)
            var sheet = window.attachedSheet
            while let current = sheet {
                result.append(current)
                sheet = current.attachedSheet
            }
        }
        return result
    }

    /// The window of an id, or the key window, else the frontmost one.
    static func window(_ id: Int?) throws(ToolError) -> NSWindow {
        if let id {
            guard let window = NSApp.window(withWindowNumber: id) ?? NSApp.windows.first(where: { $0.windowNumber == id }) else {
                throw ToolError(.notFound, "No window with id \(id).")
            }
            return window
        }
        guard let window = NSApp.keyWindow ?? windows().first else { throw ToolError(.unavailable, "No window is open.") }
        return window
    }

    /// A window as the tools describe it: id, kind, title, key state, frame, and its state.
    static func info(of window: NSWindow) -> JSONValue {
        let directory = WindowDirectory.shared
        var kind = "other"
        var state: JSONValue = .null
        if window.sheetParent != nil {
            kind = "sheet"
        } else if let workspace = directory.windows().first(where: { $0.window === window })?.workspace {
            kind = "workspace"
            state = (try? JSONValue(encoding: workspace.value)) ?? .null
        } else if let chatID = directory.chatID(of: window) {
            kind = "chat"
            state = ["chatID": .string(chatID)]
        } else if window.identifier?.rawValue.contains("Settings") == true || window.title == "Settings" {
            kind = "settings"
        }
        let frame = window.frame
        return [
            "id": .int(window.windowNumber), "kind": .string(kind), "title": .string(window.title), "isKey": .bool(window.isKeyWindow),
            "frame": ["x": .double(frame.minX), "y": .double(frame.minY), "width": .double(frame.width), "height": .double(frame.height)],
            "state": state,
        ]
    }

    // MARK: Clicks

    /// A left mouse down and up at a point of the window, built inside the app: through the app's queue when the
    /// window takes the click as a user's, else to the view under the point as the key window would send them.
    static func send(click point: NSPoint, to window: NSWindow) {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)
        if window.isKeyWindow || hit?.acceptsFirstMouse(for: down) == true {
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        } else if let hit {
            if hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
            NSApp.postEvent(up, atStart: false)
            hit.mouseDown(with: down)
        }
    }

    // MARK: Formats

    /// The UTC time as `yyyyMMdd'T'HHmmss.SSS'Z'`.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// A size without decimals when whole.
    static func number(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
