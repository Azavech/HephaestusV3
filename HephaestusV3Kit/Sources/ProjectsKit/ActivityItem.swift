import AZDesign
import SwiftUI
import ToolsFoundation

/// Something that happened in one of a project's tools, as the overview lists it.
///
/// In the real suite each tool reports its own events through a shared protocol, so this window
/// never imports a tool. Here they are sample values.
nonisolated struct ActivityItem: Identifiable, Hashable, Sendable {
    enum Tone: Sendable {
        case neutral
        case info
        case success
        case warning
        case danger
    }

    /// Stable within its project: the tool and the subject, such as `builds.1288` or `tickets.ORD-142`.
    let id: String
    let tool: ToolKind
    let text: String
    /// What the event is about, as its tool names it: a ticket number, a run number, a version, a service.
    let subject: String
    let date: Date
    let tone: Tone
    /// What the tool selects when the event opens it.
    let focus: String?

    init(tool: ToolKind, text: String, subject: String, date: Date, tone: Tone, focus: String?) {
        self.id = "\(tool.rawValue).\(subject.trimmingPrefix("#"))"
        self.tool = tool
        self.text = text
        self.subject = subject
        self.date = date
        self.tone = tone
        self.focus = focus
    }

    func route(in projectID: Project.ID) -> Route {
        .tool(tool, project: projectID, focus: focus)
    }
}

extension ActivityItem.Tone {
    var color: Color {
        switch self {
        case .neutral: .textSecondary
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .danger
        }
    }
}

extension ActivityItem {
    /// The events of a sample project, newest first.
    static func samples(for projectID: Project.ID) -> [ActivityItem] {
        let rows: [(minutesAgo: Int, tool: ToolKind, text: String, subject: String, tone: Tone, focus: String?)] = switch projectID {
        case "ORD": [
            (6, .builds, "Run started: add backoff to the payments client", "#1288", .info, "1288"),
            (14, .serviceMap, "payments-api is degraded in Staging, 6.8 % of calls fail", "payments-api", .warning, "service:payments-api"),
            (16, .serviceMap, "Checkout timed out after 4.2 s in Staging", "req-8f3a", .danger, "request:req-8f3a"),
            (120, .builds, "Run passed: document cursor pagination", "#1287", .success, "1287"),
            (190, .builds, "Run failed: index orders by customer", "#1286", .danger, "1286"),
            (360, .tickets, "You started work on the retry storm between checkout and payments", "ORD-142", .info, "ORD-142"),
            (1_200, .tickets, "You sent the slow customer orders query to review", "ORD-139", .warning, "ORD-139"),
            (1_320, .tickets, "Claude drafted a ticket to document cursor pagination", "ORD-141", .neutral, "ORD-141"),
            (1_500, .builds, "Release 1.4.0 built and published", "v1.4.0", .success, nil),
            (1_520, .contracts, "Contract 1.4.0 adds order cancellation", "1.4.0", .neutral, "cancelOrder"),
            (1_640, .builds, "Run passed: cancel orders waiting for payment", "#1284", .success, "1284"),
            (1_860, .serviceMap, "1.4.0 deployed to Production", "Production", .success, nil),
            (2_900, .builds, "Run cancelled: bump the Go toolchain", "#1283", .neutral, "1283"),
            (3_000, .tickets, "You closed the ticket to add the customer id to every log line", "ORD-130", .success, "ORD-130"),
            (4_300, .tickets, "You created a ticket to cancel orders that wait for payment", "ORD-137", .neutral, "ORD-137"),
            (8_640, .contracts, "Contract 1.3.2 fixes totals with discounts", "1.3.2", .neutral, nil),
        ]
        case "PAY": [
            (5, .builds, "Run failed: verify webhook signatures with the new secret", "#641", .danger, "641"),
            (7, .builds, "Run passed: poll the provider after a timeout", "#640", .success, "640"),
            (20, .serviceMap, "stripe answers slowly in Staging, p95 3.8 s", "stripe", .warning, "service:stripe"),
            (95, .tickets, "You started work on charges that fail when the provider times out", "PAY-58", .info, "PAY-58"),
            (2_100, .builds, "Release 2.1.0 built and published", "v2.1.0", .success, nil),
            (2_160, .contracts, "Contract 2.1.0 adds refunds", "2.1.0", .neutral, nil),
            (2_400, .serviceMap, "2.1.0 deployed to Production", "Production", .success, nil),
            (5_700, .tickets, "Claude drafted a ticket for refunds of partial captures", "PAY-57", .neutral, "PAY-57"),
        ]
        case "GW": [
            (4, .builds, "Run started: propagate traceparent", "#377", .info, "377"),
            (240, .tickets, "You created a ticket for trace IDs missing from gateway logs", "GW-21", .neutral, "GW-21"),
            (800, .builds, "Run passed: route /charges to payments-api", "#376", .success, "376"),
            (900, .contracts, "Contract 1.0.2 routes /charges", "1.0.2", .neutral, nil),
        ]
        case "TLS": [
            (40, .tickets, "You sent the project switcher to review", "TLS-12", .warning, "TLS-12"),
            (1_260, .builds, "Run passed: project switcher in tool windows", "#58", .success, "58"),
            (1_440, .builds, "Release 0.3.0 built and published", "v0.3.0", .success, nil),
            (1_500, .builds, "Run passed: service map inspector", "#57", .success, "57"),
            (2_880, .tickets, "You started moving the badge style into AZDesign", "TLS-9", .info, "TLS-9"),
        ]
        case "SHOP": [
            (35, .serviceMap, "Staging needs attention: 2 of 9 services degraded", "staging-eu", .warning, nil),
            (540, .builds, "Run passed: Helm charts render for every environment", "#212", .success, nil),
            (600, .tickets, "You started moving the namespace to the new staging cluster", "SHOP-14", .info, "SHOP-14"),
            (1_380, .tickets, "Claude drafted a ticket for one Helm chart shared by the services", "SHOP-12", .neutral, "SHOP-12"),
            (2_950, .builds, "Shared chart 3.2 rolled out to Production", "v3.2.0", .success, nil),
        ]
        case "TKIT": [
            (90, .tickets, "You sent string catalogs for the package targets to review", "TKIT-4", .warning, "TKIT-4"),
            (2_200, .tickets, "You created a ticket to move the shared components into AZDesign", "TKIT-3", .neutral, "TKIT-3"),
        ]
        case "AZD": [
            (420, .builds, "Run passed: readable colors and High Contrast values", "#12", .success, "12"),
            (430, .builds, "Release 0.2.1 published", "0.2.1", .success, nil),
            (2_000, .tickets, "You created a ticket for a Fira Code target in code views", "AZD-7", .neutral, "AZD-7"),
        ]
        default: []
        }
        let items = rows.map { row in
            ActivityItem(
                tool: row.tool, text: row.text, subject: row.subject,
                date: SampleClock.date(minutes: -row.minutesAgo), tone: row.tone, focus: row.focus
            )
        }
        return items + olderItems(of: projectID, after: items)
    }

    /// Two weeks of ordinary history under the events above, as a project in use has.
    private static func olderItems(of projectID: Project.ID, after items: [ActivityItem]) -> [ActivityItem] {
        guard let last = items.last else { return [] }
        let runs = [
            "tidy up the request logging", "bump dependencies", "add the request id to errors",
            "speed up the test suite", "rename the configuration keys", "count retries in the metrics",
            "remove unused handlers", "validate inputs at the edge",
        ]
        let tickets = [
            "flaky timeout test", "configuration keys named twice", "missing retry metrics",
            "unused handlers left after the split", "inputs checked too late", "slow test suite",
        ]
        let minutesAgo = Int(SampleClock.date().timeIntervalSince(last.date) / 60)
        // The run before the oldest one the samples name, so the numbers follow on from the Builds window.
        let lastRun = ["ORD": 1_282, "PAY": 638, "GW": 375, "TLS": 56, "AZD": 11, "SHOP": 211][projectID] ?? 0
        // The ticket before the lowest one the events above name, so no number is used twice.
        let lastTicket = (items.filter { $0.tool == .tickets }.compactMap { Int($0.subject.split(separator: "-").last ?? "") }.min() ?? 61) - 1
        return (0..<24).compactMap { index in
            let isRun = index % 3 != 2
            let date = SampleClock.date(minutes: -(minutesAgo + 300 + index * 410))
            let run = lastRun - index + index / 3
            if isRun {
                guard run > 0 else { return nil }
                let failed = index % 5 == 3
                return ActivityItem(
                    tool: .builds,
                    text: (failed ? "Run failed: " : "Run passed: ") + runs[index % runs.count],
                    subject: "#\(run)", date: date, tone: failed ? .danger : .success, focus: nil
                )
            }
            let ticket = lastTicket - index / 3
            guard ticket > 0 else { return nil }
            return ActivityItem(
                tool: .tickets,
                text: "You closed the ticket about the " + tickets[(index / 3) % tickets.count],
                subject: "\(projectID)-\(ticket)", date: date, tone: .success, focus: nil
            )
        }
    }
}
