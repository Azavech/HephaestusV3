import AZDesign
import SwiftUI
import ToolsFoundation

/// The Dashboard's Recent Builds widget, in place of V2's Recent Chats: the newest runs of the
/// project's repository, at most its `Number`, each with its status, its title, its number and
/// workflow, and when it started. A click on a row opens the run in the Builds window.
public struct BuildsDashboardWidget: View {
    let widget: DashboardWidget
    let project: Project
    let editing: Bool
    let store: any BuildStore

    @Environment(\.openRoute) private var openRoute

    public init(widget: DashboardWidget, context: DashboardContext) {
        self.init(widget: widget, context: context, store: SampleBuildStore())
    }

    init(widget: DashboardWidget, context: DashboardContext, store: any BuildStore) {
        self.widget = widget
        self.project = context.project
        self.editing = context.editing
        self.store = store
    }

    /// The newest runs of `project`'s repository, as the Builds window lists them, at most `count`
    /// (kept within the widget's 1–20).
    static func recentRuns(of project: Project, count: Int, store: any BuildStore) -> [WorkflowRun] {
        let limit = min(max(count, DashboardWidget.countRange.lowerBound), DashboardWidget.countRange.upperBound)
        return Array(store.runs(of: project).prefix(limit))
    }

    public var body: some View {
        let runs = Self.recentRuns(of: project, count: widget.count, store: store)
        VStack(alignment: .leading, spacing: 8) {
            if runs.isEmpty {
                Text("No builds yet.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("dashboard.builds.empty")
            }
            ForEach(runs) { run in
                Button {
                    guard !editing else { return }
                    openRoute(.tool(.builds, project: project.id, focus: BuildsFocus.run(run.id).focus))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: run.status.symbol)
                            .foregroundStyle(run.status.color)
                            .frame(width: 14)
                            .accessibilityLabel(run.status.title)
                        Text(verbatim: run.title)
                            .foregroundStyle(.textPrimary)
                            .lineLimit(1)
                        Text("#\(String(run.id)) · \(run.workflow)", bundle: #bundle, comment: "A run's number and workflow, in a list of runs: #641 · CI")
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(run.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.textSecondary)
                            .fixedSize()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open the run in Builds", bundle: #bundle))
                .accessibilityIdentifier("dashboard.build.\(run.id)")
            }
        }
    }
}

#Preview("Recent Builds", traits: .appChrome, .fixedLayout(width: 460, height: 220)) {
    BuildsDashboardWidget(
        widget: DashboardWidget(kind: .recentBuilds),
        context: DashboardContext(project: Project.samples[0], environment: nil, window: .hour, editing: false)
    )
    .padding()
}

#Preview("Recent Builds, Dark", traits: .appChrome, .fixedLayout(width: 460, height: 220)) {
    BuildsDashboardWidget(
        widget: DashboardWidget(kind: .recentBuilds),
        context: DashboardContext(project: Project.samples[1], environment: nil, window: .hour, editing: false)
    )
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("No Builds", traits: .appChrome, .fixedLayout(width: 460, height: 120)) {
    BuildsDashboardWidget(
        widget: DashboardWidget(kind: .recentBuilds),
        context: DashboardContext(project: previewProjectWithoutRuns, environment: nil, window: .hour, editing: false)
    )
    .padding()
}
