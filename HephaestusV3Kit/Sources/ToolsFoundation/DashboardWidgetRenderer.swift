import SwiftUI

/// Draws a Dashboard widget of any tool. ToolsScenes, the one target that knows every tool, sets it for every
/// window, so that a window can show another tool's widget: the project overview shows the Service Map's graph
/// with it. Nil in previews and tests, where nothing draws other tools' widgets.
nonisolated public struct DashboardWidgetRenderer: Sendable {
    private let render: @MainActor @Sendable (DashboardWidget, DashboardContext) -> AnyView

    public init<Content: View>(@ViewBuilder _ render: @escaping @MainActor @Sendable (DashboardWidget, DashboardContext) -> Content) {
        self.render = { AnyView(render($0, $1)) }
    }

    @MainActor
    public func callAsFunction(_ widget: DashboardWidget, _ context: DashboardContext) -> AnyView {
        render(widget, context)
    }
}

nonisolated extension EnvironmentValues {
    /// Draws other tools' widgets; set by ToolsScenes.
    @Entry public var dashboardWidgetRenderer: DashboardWidgetRenderer? = nil
}
