import AZDesign
import SwiftUI

// What the chat and the tools share. The chat never looks into a tool's window: a tool window says
// which item is selected, as a reference, and the chat reads that item through the tool's own read
// function, as any other client of the tool would.

/// An item of a tool that a chat can point at, read and open: a ticket, a service, a request, a run,
/// an operation. It is the place a route opens, plus a title to show.
nonisolated public struct ChatReference: Hashable, Codable, Sendable, Identifiable {
    public let tool: ToolKind
    public let projectID: Project.ID
    /// The tool's id for the item, as a route's focus: `ORD-142`, `service:payments-api`,
    /// `request:req-8f3a`, `1288`, `createOrder`.
    public let focus: String
    /// How the item is named in a chip or a list: `ORD-142`, `payments-api`, `Run 1288`.
    public let title: String
    /// The environment the item was seen in, for a tool that shows one at a time (the Service Map), so
    /// that a read describes what the user has on screen. Nil for the other tools.
    public let environment: String?

    /// The same item seen in two environments is two references.
    public var id: String {
        let base = "\(tool.rawValue)/\(projectID)/\(focus)"
        return environment.map { "\(base)@\($0)" } ?? base
    }

    public init(tool: ToolKind, projectID: Project.ID, focus: String, title: String, environment: String? = nil) {
        self.tool = tool
        self.projectID = projectID
        self.focus = focus
        self.title = title
        self.environment = environment
    }

    /// The window that shows the item, with it selected.
    public var route: Route {
        .tool(tool, project: projectID, focus: focus)
    }
}

/// What a tool says about one of its items when it is read: what was read, and the gist of it.
nonisolated public struct ToolReading: Hashable, Sendable {
    /// `Read ticket ORD-142`.
    public let action: String
    /// `Retry storm between checkout and payments · In Progress`.
    public let detail: String
    /// Questions worth asking about the item in its current state, which the chat offers as
    /// suggestions: "Why did run 1288 fail?" only for a run that failed. The tool knows its items, so
    /// it words them.
    public let suggestions: [String]

    public init(action: String, detail: String, suggestions: [String] = []) {
        self.action = action
        self.detail = detail
        self.suggestions = suggestions
    }
}

/// Reads an item through the tool it belongs to. ToolsScenes, which knows every tool, provides it.
nonisolated public struct ToolReader: Sendable {
    private let read: @MainActor @Sendable (ChatReference) -> ToolReading?

    public init(_ read: @escaping @MainActor @Sendable (ChatReference) -> ToolReading?) {
        self.read = read
    }

    @MainActor
    public func callAsFunction(_ reference: ChatReference) -> ToolReading? {
        read(reference)
    }
}

/// Tells the window which item its tool has selected, for the chat panel beside it.
nonisolated public struct ReportChatSubjectAction: Sendable {
    private let handler: @MainActor @Sendable (ChatReference?) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (ChatReference?) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ subject: ChatReference?) {
        handler(subject)
    }
}

nonisolated private struct ToolReaderKey: EnvironmentKey {
    static let defaultValue = ToolReader { _ in nil }
}

nonisolated private struct ReportChatSubjectKey: EnvironmentKey {
    static let defaultValue = ReportChatSubjectAction { _ in }
}

nonisolated extension EnvironmentValues {
    /// Reads an item through its tool. Previews get a reader that reads nothing.
    public var toolReader: ToolReader {
        get { self[ToolReaderKey.self] }
        set { self[ToolReaderKey.self] = newValue }
    }

    /// Reports the item a tool has selected. Outside a tool window it does nothing.
    public var reportChatSubject: ReportChatSubjectAction {
        get { self[ReportChatSubjectKey.self] }
        set { self[ReportChatSubjectKey.self] = newValue }
    }
}

/// The chat panel beside a tool window: whether it shows. The window provides it; a tool window
/// without a panel, and the Chat window, get none.
nonisolated public struct ChatPanelControl: Sendable {
    public let isShown: Binding<Bool>

    public init(isShown: Binding<Bool>) {
        self.isShown = isShown
    }

    /// Shows or hides the panel, sliding it in or out with AZDesign's `panel` motion (a fade under
    /// Reduce Motion).
    @MainActor
    public func toggle() {
        withMotion(.panel) {
            isShown.wrappedValue.toggle()
        }
    }
}

nonisolated private struct ChatPanelControlKey: EnvironmentKey {
    static let defaultValue: ChatPanelControl? = nil
}

nonisolated extension EnvironmentValues {
    /// The window's chat panel, if it has one.
    public var chatPanel: ChatPanelControl? {
        get { self[ChatPanelControlKey.self] }
        set { self[ChatPanelControlKey.self] = newValue }
    }
}

/// The button that shows or hides the chat panel. Each tool puts it last in its toolbar, so it sits
/// at the right end, where a Mac app keeps the toggle of a panel on the right. It shows nothing when
/// the window has no panel.
public struct ChatPanelToolbarItem: ToolbarContent {
    /// For a toolbar whose items start at the left of their column, as a detail column's do: a
    /// flexible space before the button takes it to the column's right edge.
    let pushesToTrailingEdge: Bool

    @Environment(\.chatPanel) private var chatPanel

    public init(pushesToTrailingEdge: Bool = false) {
        self.pushesToTrailingEdge = pushesToTrailingEdge
    }

    public var body: some ToolbarContent {
        if let chatPanel {
            if pushesToTrailingEdge {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chatPanel.toggle()
                } label: {
                    // The Mac's icon for a panel on the right, which is where the chat opens.
                    Label(String(localized: "Chat", bundle: #bundle), systemImage: "sidebar.right")
                }
                .help(
                    chatPanel.isShown.wrappedValue
                        ? String(localized: "Hide the Chat Panel (⌃⌘C)", bundle: #bundle)
                        : String(localized: "Show the Chat Panel (⌃⌘C)", bundle: #bundle)
                )
                .accessibilityIdentifier("toolbar.chatPanel")
            }
        }
    }
}
