import Foundation
import Observation
import ToolsFoundation

/// Where each project's Dashboard is kept: its widgets and the time window of its service widgets, and the
/// environment its widgets read (docs/ui/dashboard.md › Saving). The app uses `LiveDashboardStore`, on the
/// project files; the previews `SampleDashboardStore`; the tests a mock.
///
/// A store is a shared, `@Observable` reference: every Dashboard window of a project reads the same one, so a
/// change made in one window shows at once in the others.
@MainActor
protocol DashboardStore: AnyObject {
    /// The stored list; nil while the project has none, and the default list shows.
    func widgets(of project: Project.ID) -> [DashboardWidget]?
    /// The stored time window; nil while none is stored, and the last hour shows.
    func window(of project: Project.ID) -> TimeWindow?
    /// The environment chosen in this store and not yet the project's current one; nil for none.
    func environment(of project: Project.ID) -> String?
    /// Why the last change failed, until the next change; nil when it didn't.
    func failure(of project: Project.ID) -> String?
    func setWidgets(_ widgets: [DashboardWidget], of project: Project.ID)
    func setWindow(_ window: TimeWindow, of project: Project.ID)
    func setEnvironment(_ name: String, of project: Project.ID)
}

/// A store that keeps everything in memory. A project with nothing kept shows its sample layout, when it has
/// one, or the default list. For previews.
@MainActor
@Observable
final class SampleDashboardStore: DashboardStore {
    private var widgets: [Project.ID: [DashboardWidget]]
    private var windows: [Project.ID: TimeWindow] = [:]
    private var environments: [Project.ID: String] = [:]
    private var failures: [Project.ID: String]

    init(_ widgets: [Project.ID: [DashboardWidget]] = [:], failures: [Project.ID: String] = [:]) {
        self.widgets = widgets
        self.failures = failures
    }

    func widgets(of project: Project.ID) -> [DashboardWidget]? {
        widgets[project] ?? DashboardWidget.sample(for: project)
    }

    func window(of project: Project.ID) -> TimeWindow? {
        windows[project]
    }

    func environment(of project: Project.ID) -> String? {
        environments[project]
    }

    func failure(of project: Project.ID) -> String? {
        failures[project]
    }

    func setWidgets(_ widgets: [DashboardWidget], of project: Project.ID) {
        failures[project] = nil
        self.widgets[project] = widgets
    }

    func setWindow(_ window: TimeWindow, of project: Project.ID) {
        failures[project] = nil
        windows[project] = window
    }

    func setEnvironment(_ name: String, of project: Project.ID) {
        failures[project] = nil
        environments[project] = name
    }
}
