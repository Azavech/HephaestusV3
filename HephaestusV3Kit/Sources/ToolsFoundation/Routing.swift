import SwiftUI

/// A tool that has its own window, opened for one project at a time.
nonisolated public enum ToolKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The project on one screen, in widgets the user places on a grid (V2's Dashboard).
    case dashboard
    case tickets
    case serviceMap
    case contracts
    case builds
    /// Conversations with Claude about the project. Claude reads and changes things only through
    /// the other tools, as one more client of them.
    case chat

    public var id: Self { self }

    /// The id of the tool's window scene.
    public var windowID: String { rawValue }
}

/// What a tool window shows: a project, and optionally something to select in it when it opens.
nonisolated public struct ToolWindowValue: Codable, Hashable, Sendable {
    public var projectID: Project.ID
    /// A tool-specific id: a service name, an operation id, a run number…
    public var focus: String?
    /// Set by File ▸ New Window (⌘N), so that SwiftUI opens another window rather than bringing
    /// forward one that shows the same project.
    public var instance: UUID?

    public init(projectID: Project.ID, focus: String? = nil, instance: UUID? = nil) {
        self.projectID = projectID
        self.focus = focus
        self.instance = instance
    }
}

/// A place in the app. Tools ask for a route; only ToolsScenes knows how to open it.
nonisolated public enum Route: Hashable, Sendable {
    /// The Projects window, with this project selected.
    case project(Project.ID)
    /// The project's own window: the frontmost window already showing it, brought forward and out of
    /// the Dock, or the Projects window with it selected when none shows it.
    case projectWindow(Project.ID)
    /// A tool's window for a project: the one already showing it, brought forward and out of the
    /// Dock, or a new one. A `focus` is selected in either.
    case tool(ToolKind, project: Project.ID, focus: String? = nil)
    /// The Virtual Machines window, with this machine selected.
    case machine(String? = nil)
}

/// Opens a route. Read it from the environment: `@Environment(\.openRoute) private var openRoute`.
nonisolated public struct OpenRouteAction: Sendable {
    private let handler: @MainActor @Sendable (Route) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (Route) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ route: Route) {
        handler(route)
    }
}

nonisolated private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue = OpenRouteAction { _ in }
}

nonisolated private struct ActiveProjectKey: FocusedValueKey {
    typealias Value = Project
}

nonisolated extension EnvironmentValues {
    /// Opens another window of the app. Previews get an action that does nothing.
    public var openRoute: OpenRouteAction {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}

nonisolated extension FocusedValues {
    /// The project of the key window, for the menu commands.
    public var activeProject: Project? {
        get { self[ActiveProjectKey.self] }
        set { self[ActiveProjectKey.self] = newValue }
    }
}

/// A route's ask to select an item in a window that is already open. Every request is a new value,
/// even for the item asked for last time, so a tool selects it again after the user picked another.
///
/// A window opened by a route gets the focus in its value instead, and selects it as it starts.
nonisolated public struct FocusRequest: Equatable, Sendable {
    /// The tool's id for the item, in the route's focus format.
    public let focus: String
    private let id = UUID()

    public init(_ focus: String) {
        self.focus = focus
    }
}

nonisolated private struct FocusRequestKey: EnvironmentKey {
    static let defaultValue: FocusRequest? = nil
}

nonisolated extension EnvironmentValues {
    /// The latest route's ask to select an item in this window. Nil until one arrives.
    public var focusRequest: FocusRequest? {
        get { self[FocusRequestKey.self] }
        set { self[FocusRequestKey.self] = newValue }
    }
}

extension View {
    /// Runs `select` with the focus of each route that arrives while this window is open, so the tool
    /// selects the item without starting afresh.
    public func onFocusRequest(_ select: @escaping (String) -> Void) -> some View {
        modifier(FocusRequestModifier(select: select))
    }
}

private struct FocusRequestModifier: ViewModifier {
    let select: (String) -> Void
    @Environment(\.focusRequest) private var request

    func body(content: Content) -> some View {
        content.onChange(of: request) { _, request in
            if let request {
                select(request.focus)
            }
        }
    }
}
