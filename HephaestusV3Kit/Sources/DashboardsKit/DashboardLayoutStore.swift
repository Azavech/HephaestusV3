import Foundation
import Observation
import ToolsFoundation

/// What is kept of a project's Dashboard: its widgets, and the environment and the time window it
/// shows; nil for a value the user never changed (docs/ui/dashboard.md › Saving).
nonisolated struct DashboardLayout: Codable, Equatable, Sendable {
    var widgets: [DashboardWidget]?
    var window: TimeWindow?
    var environment: String?
}

/// Where each project's Dashboard is kept. The app uses `UserDefaultsDashboardLayoutStore.shared`, the
/// previews `SampleDashboardLayoutStore`.
///
/// A store is a shared, `@Observable` reference: every Dashboard window of a project reads the same
/// one, so a change made in one window shows at once in the others.
protocol DashboardLayoutStore: AnyObject {
    /// What is kept for the project; nil when nothing is.
    func layout(of project: Project.ID) -> DashboardLayout?
    func setLayout(_ layout: DashboardLayout, of project: Project.ID)
}

/// The app's store: one entry a project in the user defaults, under `dashboard.<project id>`.
///
/// V2 kept the Dashboard in the project file; this proof of concept keeps it in the user defaults, so
/// that it survives a relaunch.
@Observable
final class UserDefaultsDashboardLayoutStore: DashboardLayoutStore {
    /// The store of the app's windows.
    static let shared = UserDefaultsDashboardLayoutStore(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults
    private var layouts: [Project.ID: DashboardLayout] = [:]

    /// Reads the entries of the sample projects. An entry that can't be read counts as nothing kept.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        for project in Project.samples {
            if let data = defaults.data(forKey: Self.key(project.id)),
               let layout = try? JSONDecoder().decode(DashboardLayout.self, from: data) {
                layouts[project.id] = layout
            }
        }
    }

    func layout(of project: Project.ID) -> DashboardLayout? {
        layouts[project]
    }

    func setLayout(_ layout: DashboardLayout, of project: Project.ID) {
        guard layouts[project] != layout else { return }
        layouts[project] = layout
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Self.key(project))
        }
    }

    /// The user defaults key of a project's entry, such as `dashboard.ORD`.
    static func key(_ project: Project.ID) -> String {
        "dashboard.\(project)"
    }
}

/// A store that keeps everything in memory and starts with nothing kept, unless given layouts: every
/// project shows its sample layout or the default list. For previews.
@Observable
final class SampleDashboardLayoutStore: DashboardLayoutStore {
    private var layouts: [Project.ID: DashboardLayout]

    init(_ layouts: [Project.ID: DashboardLayout] = [:]) {
        self.layouts = layouts
    }

    func layout(of project: Project.ID) -> DashboardLayout? {
        layouts[project]
    }

    func setLayout(_ layout: DashboardLayout, of project: Project.ID) {
        if layouts[project] != layout {
            layouts[project] = layout
        }
    }
}
