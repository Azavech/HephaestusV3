import AZDesign
import SwiftUI
import ToolsFoundation

/// The Dashboard's Tickets widget: one count per status checked in its settings, side by side in
/// workflow order, each a number in a large font above its label (V2's docs/dashboard.md › Widgets).
/// With `Include sub projects`, the counts cover the project and its sub projects, as its Tickets
/// window lists them.
public struct TicketsDashboardWidget: View {
    let widget: DashboardWidget
    let project: Project
    let store: any TicketStore
    @Environment(\.projectDirectory) private var directory

    public init(widget: DashboardWidget, context: DashboardContext) {
        self.init(widget: widget, project: context.project, store: SampleTicketStore())
    }

    init(widget: DashboardWidget, project: Project, store: any TicketStore) {
        self.widget = widget
        self.project = project
        self.store = store
    }

    public var body: some View {
        let statuses = TicketStatus.allCases.filter(widget.statuses.contains)
        VStack(alignment: .leading, spacing: 8) {
            if !statuses.isEmpty {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(statuses) { status in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(count(status), format: .number)
                                .font(.title.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.textPrimary)
                            Label(status.title, systemImage: status.symbol)
                                .foregroundStyle(.textSecondary)
                                .labelStyle(.tintedIcon(status.color))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dashboard.tickets.\(status.rawValue)")
                    }
                }
                // The counts are never truncated or wrapped: a narrower widget scrolls them.
                .fixedSize()
            }
            if widget.includeSubprojects, !directory.tree.children(of: project.id).isEmpty {
                Text("Sub projects included", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("dashboard.tickets.subprojects")
            }
        }
    }

    private func count(_ status: TicketStatus) -> Int {
        store.count(of: status, in: project.id, includingSubprojects: widget.includeSubprojects, tree: directory.tree)
    }
}

#Preview("Loaded", traits: .appChrome, .sizeThatFitsLayout) {
    TicketsDashboardWidget(
        widget: DashboardWidget(kind: .tickets, includeSubprojects: false),
        project: Project.sample("ORD")!, store: SampleTicketStore()
    )
    .padding()
}

#Preview("Sub Projects", traits: .appChrome, .sizeThatFitsLayout) {
    TicketsDashboardWidget(widget: DashboardWidget(kind: .tickets), project: Project.sample("SHOP")!, store: SampleTicketStore())
        .padding()
}

#Preview("Two Statuses, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    TicketsDashboardWidget(
        widget: DashboardWidget(kind: .tickets, statuses: [.inProgress, .inReview]),
        project: Project.sample("ORD")!, store: SampleTicketStore()
    )
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("No Statuses", traits: .appChrome, .sizeThatFitsLayout) {
    TicketsDashboardWidget(widget: DashboardWidget(kind: .tickets, statuses: []), project: Project.sample("SHOP")!, store: SampleTicketStore())
        .padding()
}

#Preview("Largest Text", traits: .largestText, .sizeThatFitsLayout) {
    TicketsDashboardWidget(widget: DashboardWidget(kind: .tickets), project: Project.sample("SHOP")!, store: SampleTicketStore())
        .padding()
}
