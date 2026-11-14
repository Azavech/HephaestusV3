import Foundation

// Values that more than one tool speaks of: the Dashboard's widgets show them, and the tool they
// belong to shows them in full. Their names and colors are in Appearance.swift.

/// Where a ticket is in its life, in workflow order.
nonisolated public enum TicketStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case draft
    case created
    case inProgress
    case inReview
    case done

    public var id: Self { self }
}

/// How far back the Service Map and the Dashboard's service widgets count calls and requests.
nonisolated public enum TimeWindow: String, CaseIterable, Identifiable, Codable, Sendable {
    case fiveMinutes
    case hour
    case day

    public var id: Self { self }

    /// Its length in minutes: the points of a chart with one point a minute.
    public var minutes: Int {
        switch self {
        case .fiveMinutes: 5
        case .hour: 60
        case .day: 1_440
        }
    }
}
