import Foundation
import ToolsFoundation

extension DashboardWidget {
    /// The lists of the sample projects that have one, as if the user had arranged them: Orders and
    /// Shop watch their services. The other projects show the default list, without positions,
    /// which the Dashboard places two a row (docs/ui/dashboard.md › Lists without positions).
    static func sample(for projectID: Project.ID) -> [DashboardWidget]? {
        switch projectID {
        case "ORD": [
            placed(1, .project, column: 0, row: 0, width: 6, height: 4),
            placed(2, .tickets, column: 6, row: 0, width: 11, height: 4),
            placed(3, .requestsPerMinute, column: 17, row: 0, width: 7, height: 4),
            placed(4, .serviceGraph, column: 0, row: 4, width: 15, height: 9),
            placed(5, .busiestCalls, column: 15, row: 4, width: 9, height: 5),
            placed(6, .failedRequests, column: 15, row: 9, width: 9, height: 4),
            placed(7, .instances, column: 0, row: 13, width: 13, height: 4),
            placed(8, .recentBuilds, column: 13, row: 13, width: 11, height: 4),
        ]
        case "SHOP": [
            placed(1, .tickets, column: 0, row: 0, width: 12, height: 4),
            placed(2, .requestsPerMinute, column: 12, row: 0, width: 12, height: 4),
            placed(3, .serviceGraph, column: 0, row: 4, width: 16, height: 11),
            placed(4, .busiestCalls, column: 16, row: 4, width: 8, height: 6, count: 8),
            placed(5, .failedRequests, column: 16, row: 10, width: 8, height: 5),
            placed(6, .recentBuilds, column: 0, row: 15, width: 12, height: 4, title: "Chart Builds"),
        ]
        default: nil
        }
    }

    private static func placed(
        _ number: Int, _ kind: DashboardWidgetKind, column: Int, row: Int, width: Int, height: Int,
        count: Int = 5, title: String = ""
    ) -> DashboardWidget {
        DashboardWidget(
            id: UUID(uuidString: String(format: "D0000000-0000-0000-0000-%012d", number))!, kind: kind, title: title,
            column: column, row: row, width: width, height: height, count: count
        )
    }
}
