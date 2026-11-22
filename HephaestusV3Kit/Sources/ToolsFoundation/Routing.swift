import SwiftUI

/// A tool, shown in a tab for one project at a time.
nonisolated public enum ToolKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The project on one screen, in widgets the user places on a grid.
    case dashboard
    case tickets
    case serviceMap
    case contracts
    case builds
    /// Conversations with Claude about the project. Claude reads and changes things only through
    /// the other tools, as one more client of them.
    case chat

    public var id: Self { self }
}

/// A place in the app. Tools ask for a route; only ToolsScenes knows how to open it.
nonisolated public enum Route: Hashable, Sendable {
    /// Projects, with this project selected.
    case project(Project.ID)
    /// The project's own tab: the first tab already showing it in the frontmost window that has one,
    /// selected and brought forward, or Projects with it selected when none shows it.
    case projectWindow(Project.ID)
    /// A tool's tab for a project: the one already showing it, selected and brought forward, or a new
    /// one. A `focus` is selected in either.
    case tool(ToolKind, project: Project.ID, focus: String? = nil)
    /// The Virtual Machines tab, with this machine selected.
    case machine(String? = nil)
    /// A project's Project Settings tab.
    case projectSettings(Project.ID)
    /// A chat in a window of its own, V2's chat window: the one already showing it, brought forward, or a new
    /// one.
    case chatWindow(chat: String)
    /// The Settings window, on this tab.
    case settings(SettingsPane)
    /// The System Prompts tab, with this internal skill selected, by its name, as V2's `skill` target.
    case systemPrompts(skill: String? = nil)
}

/// A tab of the Settings window, by its stored name.
nonisolated public enum SettingsPane: String, Hashable, Sendable, CaseIterable {
    case general, projects, mcp, machines, chat, notifications, updates

    /// Where Settings keeps its tab, in the user defaults: it opens on the last one, or on a route's.
    public static let storageKey = "settings.pane"
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
/// A request is acted on once: a tool view made again later with it (its tab selected anew) doesn't select
/// the item a second time.
///
/// A window opened by a route gets the focus in its value instead, and selects it as it starts.
nonisolated public struct FocusRequest: Equatable, Sendable {
    /// The tool's id for the item, in the route's focus format.
    public let focus: String
    private let id = UUID()
    /// Shared by every copy of the request: whether a view has acted on it.
    private let delivery = Delivery()

    public init(_ focus: String) {
        self.focus = focus
    }

    /// The focus, the first time it is asked for; nil afterwards.
    @MainActor func take() -> String? {
        guard !delivery.done else { return nil }
        delivery.done = true
        return focus
    }

    public static func == (lhs: FocusRequest, rhs: FocusRequest) -> Bool {
        lhs.id == rhs.id
    }

    @MainActor private final class Delivery {
        var done = false
        nonisolated init() {}
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
    /// Runs `select` with the focus of each route that arrives while this window is open, or that waited for
    /// its tab to be drawn, so the tool selects the item without starting afresh.
    public func onFocusRequest(_ select: @escaping (String) -> Void) -> some View {
        modifier(FocusRequestModifier(select: select))
    }
}

private struct FocusRequestModifier: ViewModifier {
    let select: (String) -> Void
    @Environment(\.focusRequest) private var request

    func body(content: Content) -> some View {
        // `initial`: a tab that wasn't the selected one is drawn with the request already in its environment.
        content.onChange(of: request, initial: true) { _, request in
            if let focus = request?.take() {
                select(focus)
            }
        }
    }
}
