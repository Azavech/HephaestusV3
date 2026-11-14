import Foundation
import Observation
import ProjectData
import SwiftUI
import ToolsFoundation

/// The app's store: each project's Dashboard in its project file, the keys `dashboardWidgets` and
/// `dashboardGraphWindow`, and the environment its widgets read, the project's current environment
/// (docs/ui/dashboard.md › Saving, docs/data.md › Dashboard widget).
///
/// A change shows at once: the store keeps it until it is written. Changes are written one after the other,
/// in the order they were made; one that fails shows its message, the Dashboard shows the stored list again,
/// and the changes made after it are dropped, since they were made on top of it. A change written by another
/// window or another program shows when the project file is read again.
@MainActor
@Observable
public final class LiveDashboardStore: DashboardStore {
    @ObservationIgnored private let session: ProjectSession
    /// What each project shows until its changes are written.
    private var shown: [Project.ID: Shown] = [:]
    private var failures: [Project.ID: String] = [:]
    /// The changes not yet written, by project.
    @ObservationIgnored private var unwritten: [Project.ID: Int] = [:]
    /// Raised by a failure: the changes queued before it are dropped.
    @ObservationIgnored private var generations: [Project.ID: Int] = [:]
    /// The last change queued: each one waits for it.
    @ObservationIgnored private var queue: Task<Void, Never>?

    private struct Shown {
        var widgets: [DashboardWidget]?
        var window: TimeWindow?
        var environment: String?
    }

    public init(session: ProjectSession) {
        self.session = session
    }

    // MARK: Reading

    func widgets(of project: Project.ID) -> [DashboardWidget]? {
        if let widgets = shown[project]?.widgets { return widgets }
        return session.snapshot.project(project)?.file.dashboardWidgets.map { $0.map(Self.widget) }
    }

    func window(of project: Project.ID) -> TimeWindow? {
        if let window = shown[project]?.window { return window }
        return session.snapshot.project(project)?.file.dashboardGraphWindow.flatMap(Self.window)
    }

    func environment(of project: Project.ID) -> String? {
        shown[project]?.environment
    }

    func failure(of project: Project.ID) -> String? {
        failures[project]
    }

    // MARK: Changing

    func setWidgets(_ widgets: [DashboardWidget], of project: Project.ID) {
        let stored = session.snapshot.project(project)?.file.dashboardWidgets ?? []
        shown[project, default: Shown()].widgets = widgets
        // Each write is made from the list shown when the change was made, merged with the stored entries
        // when it runs, so that the keys V3 doesn't show survive.
        enqueue(project) { [session] in
            let current = session.snapshot.project(project)?.file.dashboardWidgets ?? stored
            return ProjectChange(dashboardWidgets: Self.entries(widgets, merging: current))
        }
    }

    func setWindow(_ window: TimeWindow, of project: Project.ID) {
        shown[project, default: Shown()].window = window
        enqueue(project) { ProjectChange(dashboardGraphWindow: Self.graphWindow(window)) }
    }

    func setEnvironment(_ name: String, of project: Project.ID) {
        shown[project, default: Shown()].environment = name
        failures[project] = nil
        let generation = generations[project, default: 0]
        unwritten[project, default: 0] += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if generations[project, default: 0] == generation {
                do throws(ProjectError) {
                    try await session.setCurrentEnvironment(project, to: name)
                } catch {
                    fail(project, error.description)
                }
            }
            written(project)
        }
    }

    /// Queues a write of the project file; the change is made when its turn comes.
    private func enqueue(_ project: Project.ID, _ change: @escaping @MainActor () -> ProjectChange) {
        failures[project] = nil
        let generation = generations[project, default: 0]
        unwritten[project, default: 0] += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if generations[project, default: 0] == generation {
                do throws(ProjectError) {
                    try await session.update(project, change())
                } catch {
                    fail(project, error.description)
                }
            }
            written(project)
        }
    }

    private func fail(_ project: Project.ID, _ message: String) {
        failures[project] = message
        generations[project, default: 0] += 1
        shown[project] = nil
    }

    /// Once every change of the project is written, the Dashboard reads the project file again.
    private func written(_ project: Project.ID) {
        unwritten[project, default: 1] -= 1
        if unwritten[project] == 0 {
            unwritten[project] = nil
            shown[project] = nil
        }
    }

    /// Waits until every queued change is written. For tests.
    func settle() async {
        while let task = queue {
            await task.value
            if queue == task { queue = nil }
        }
    }

    // MARK: Mapping

    /// A widget of the file as the Dashboard shows it.
    nonisolated static func widget(_ entry: DashboardWidgetEntry) -> DashboardWidget {
        DashboardWidget(
            id: entry.id, kind: kind(entry.kind), title: entry.title,
            column: entry.column, row: entry.row, width: entry.width, height: entry.height,
            fields: entry.fields.compactMap { DashboardProjectField(rawValue: $0.rawValue) },
            statuses: entry.statuses.map(status), includeSubprojects: entry.includeSubprojects, count: entry.count
        )
    }

    /// The list the Dashboard shows as entries of the file: each widget takes the stored entry of its slot,
    /// with the keys the Dashboard doesn't show (V2's Recent Chats settings, unknown keys) as stored; a new
    /// widget takes the defaults of the file.
    nonisolated static func entries(_ widgets: [DashboardWidget], merging stored: [DashboardWidgetEntry]) -> [DashboardWidgetEntry] {
        var storedSlots: [UUID: [DashboardWidgetEntry]] = [:]
        for entry in stored {
            storedSlots[entry.id, default: []].append(entry)
        }
        var seen: [UUID: Int] = [:]
        return widgets.map { widget in
            let occurrence = seen[widget.id, default: 0]
            seen[widget.id] = occurrence + 1
            let base = storedSlots[widget.id].flatMap { $0.indices.contains(occurrence) ? $0[occurrence] : nil }
            var entry = base ?? DashboardWidgetEntry(id: widget.id, kind: fileKind(widget.kind))
            entry.kind = fileKind(widget.kind)
            entry.title = widget.title
            entry.column = widget.column
            entry.row = widget.row
            entry.width = widget.width
            entry.height = widget.height
            entry.fields = widget.fields.compactMap { DashboardWidgetEntry.Field(rawValue: $0.rawValue) }
            entry.statuses = widget.statuses.map(fileStatus)
            entry.includeSubprojects = widget.includeSubprojects
            entry.count = widget.count
            return entry
        }
    }

    nonisolated static func kind(_ kind: DashboardWidgetEntry.Kind) -> DashboardWidgetKind {
        switch kind {
        case .project: .project
        case .tickets: .tickets
        case .recentChats: .recentChats
        case .cost: .cost
        case .instances: .instances
        case .serviceGraph: .serviceGraph
        case .busiestCalls: .busiestCalls
        case .failedRequests: .failedRequests
        case .requestsPerMinute: .requestsPerMinute
        case .recentBuilds: .recentBuilds
        }
    }

    nonisolated static func fileKind(_ kind: DashboardWidgetKind) -> DashboardWidgetEntry.Kind {
        switch kind {
        case .project: .project
        case .tickets: .tickets
        case .recentBuilds: .recentBuilds
        case .recentChats: .recentChats
        case .cost: .cost
        case .instances: .instances
        case .serviceGraph: .serviceGraph
        case .busiestCalls: .busiestCalls
        case .failedRequests: .failedRequests
        case .requestsPerMinute: .requestsPerMinute
        }
    }

    nonisolated static func status(_ status: DashboardWidgetEntry.Status) -> TicketStatus {
        switch status {
        case .draft: .draft
        case .todo: .created
        case .inProgress: .inProgress
        case .review: .inReview
        case .done: .done
        }
    }

    nonisolated static func fileStatus(_ status: TicketStatus) -> DashboardWidgetEntry.Status {
        switch status {
        case .draft: .draft
        case .created: .todo
        case .inProgress: .inProgress
        case .inReview: .review
        case .done: .done
        }
    }

    /// V2's `week` has no window in V3 yet: it stays stored, and the last hour shows.
    nonisolated static func window(_ window: DashboardGraphWindow) -> TimeWindow? {
        switch window {
        case .fiveMinutes: .fiveMinutes
        case .hour: .hour
        case .day: .day
        case .week: nil
        }
    }

    nonisolated static func graphWindow(_ window: TimeWindow) -> DashboardGraphWindow {
        switch window {
        case .fiveMinutes: .fiveMinutes
        case .hour: .hour
        case .day: .day
        }
    }
}

extension EnvironmentValues {
    /// The app's Dashboards, for the Dashboard windows; nil in previews, which keep theirs in memory.
    @Entry public var dashboardStore: LiveDashboardStore?
}
