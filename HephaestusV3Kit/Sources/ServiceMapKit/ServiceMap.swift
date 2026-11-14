import Foundation
import ToolsFoundation

/// What the map shows for one environment: services, the calls between them, recent requests and logs.
///
/// In the real suite this comes from the cluster (deployments, eBPF or mesh flows, traces);
/// here it is sample data.
struct ServiceMap: Hashable, Sendable {
    let nodes: [ServiceNode]
    let calls: [ServiceCall]
    let requests: [ServiceRequest]
    let logs: [LogLine]

    func node(_ id: ServiceNode.ID) -> ServiceNode? {
        nodes.first { $0.id == id }
    }

    func request(_ id: ServiceRequest.ID) -> ServiceRequest? {
        requests.first { $0.id == id }
    }

    /// The services of the namespace: gateways, services and workers, not the databases, queues and
    /// external services they call.
    var services: [ServiceNode] {
        nodes.filter(\.kind.isService)
    }

    /// How many services `request` went through: its spans' services, each once, without the
    /// databases, queues and external services.
    func serviceCount(of request: ServiceRequest) -> Int {
        Set(request.services).count { id in node(id)?.kind.isService ?? false }
    }

    /// The calls to and from `node`, in the map's order.
    func calls(of node: ServiceNode.ID) -> [ServiceCall] {
        calls.filter { $0.from == node || $0.to == node }
    }
}

/// A box on the map. Where it goes is the graph layout's business, not the node's.
struct ServiceNode: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case gateway
        case service
        case worker
        case database
        case queue
        /// An object storage bucket of a service (`s3.enabled`, or yc-shared's `s3store`), as V2 drew it.
        case bucket
        case external
        /// The client that sent a request: the entry point of the view of a request.
        case client

        /// A deployment that calls others. The rest (databases, queues, outside APIs) sits on the ring of
        /// the first service that calls it.
        var isService: Bool {
            switch self {
            case .gateway, .service, .worker: true
            case .database, .queue, .bucket, .external, .client: false
            }
        }
    }

    /// The deployment's name, e.g. `orders-api`.
    let id: String
    let kind: Kind
    let requestsPerSecond: Double
    /// 95th percentile latency, in milliseconds.
    let p95: Int
    /// From 0 to 1.
    let errorRate: Double
    let readyPods: Int
    let pods: Int
    let health: DeploymentEnvironment.Health
    /// Requests per second over the last 30 minutes, one value a minute.
    let throughput: [Double]

    /// Whether the node runs pods: external services run outside the cluster.
    var hasPods: Bool {
        kind != .external && pods > 0
    }
}

extension ServiceNode {
    /// The Client node of the view of a request.
    static let client = ServiceNode(
        id: "client", kind: .client, requestsPerSecond: 0, p95: 0, errorRate: 0,
        readyPods: 0, pods: 0, health: .healthy, throughput: []
    )
}

/// An arrow of the graph as drawn: what it links, what its colour weighs, and what is written on it.
struct GraphArrow: Identifiable, Hashable, Sendable {
    var id: String { "\(from)→\(to)" }
    let from: ServiceNode.ID
    let to: ServiceNode.ID
    /// What the colour scale weighs: calls per second on the whole graph, the call's duration in a request.
    let weight: Double
    /// Written at the middle of the arrow, or after the kind of a box of a ring.
    let label: String
    /// What VoiceOver reads for the label, in words: "142 calls per second", "4.2 seconds".
    let spokenLabel: String
}

/// An arrow on the map: one service calling another.
struct ServiceCall: Identifiable, Hashable, Sendable {
    var id: String { "\(from)→\(to)" }
    let from: ServiceNode.ID
    let to: ServiceNode.ID
    let requestsPerSecond: Double
    let errorRate: Double

    /// The call as the whole graph draws it: coloured by its calls per second, which it says.
    var graphArrow: GraphArrow {
        GraphArrow(
            from: from, to: to, weight: requestsPerSecond,
            label: ServiceMapFormat.rate(requestsPerSecond), spokenLabel: ServiceMapFormat.spokenRate(requestsPerSecond)
        )
    }

    /// The calls made in `window`, at the call's rate.
    func count(in window: TimeWindow) -> Int {
        Int((requestsPerSecond * Double(window.minutes * 60)).rounded())
    }

    /// The call as the Dashboard's graph draws it: coloured by, and labelled with, its calls in `window`.
    func windowArrow(_ window: TimeWindow) -> GraphArrow {
        let count = count(in: window)
        return GraphArrow(
            from: from, to: to, weight: Double(count),
            label: ServiceMapFormat.compactCount(count), spokenLabel: ServiceMapFormat.spokenCalls(count)
        )
    }
}

/// A request that entered the namespace, with the services it went through.
struct ServiceRequest: Identifiable, Hashable, Sendable {
    let id: String
    let method: String
    let path: String
    let status: Int
    /// In milliseconds.
    let duration: Int
    let startedAt: Date
    let spans: [Span]

    /// The nodes the request went through, in order.
    var services: [ServiceNode.ID] { spans.map(\.service) }

    /// Whether the request was answered with an error: 400 or above.
    var failed: Bool { status >= 400 }

    /// Whether the request took one second or more.
    var isSlow: Bool { duration >= 1_000 }

    /// The calls the request made, in the order of its spans: each span after the first, with its
    /// caller, the closest earlier span that contains it. A span that no other contains has none.
    var calledSpans: [(caller: Span, span: Span)] {
        spans.dropFirst().compactMap { span in
            let caller = spans.last { $0.id != span.id && $0.start <= span.start && $0.start + $0.duration >= span.start + span.duration }
            return caller.map { ($0, span) }
        }
    }
}

/// One service's part of a request.
struct Span: Identifiable, Hashable, Sendable {
    let id: Int
    let service: ServiceNode.ID
    let operation: String
    /// Milliseconds from the start of the request.
    let start: Int
    let duration: Int
    let isError: Bool
}

/// A log line of a service.
struct LogLine: Identifiable, Hashable, Sendable {
    enum Level: Sendable {
        case info
        case warning
        case error
    }

    let id: Int
    let date: Date
    let service: ServiceNode.ID
    let level: Level
    let message: String
    let requestID: ServiceRequest.ID?
}

// `TimeWindow` is in ToolsFoundation: the Dashboard's service widgets count over one too.

/// What the map and its inspector focus on.
enum MapSelection: Hashable, Sendable {
    case service(ServiceNode.ID)
    case request(ServiceRequest.ID)

    /// Reads a window's focus: `service:<name>` or `request:<id>`.
    init?(focus: String?) {
        guard let focus else { return nil }
        let parts = focus.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "service": self = .service(parts[1])
        case "request": self = .request(parts[1])
        default: return nil
        }
    }

    /// The focus of a route to it: `service:<name>` or `request:<id>`.
    var focus: String {
        switch self {
        case .service(let id): "service:\(id)"
        case .request(let id): "request:\(id)"
        }
    }

    var isRequest: Bool {
        if case .request = self { true } else { false }
    }
}

extension Project {
    /// The environment a Service Map opens on, and the chat reads without one: the first that isn't
    /// healthy, or else the first, among the environments the project's tools read (its own, or those of
    /// the project it takes its settings from).
    var openingEnvironment: DeploymentEnvironment? {
        deploymentEnvironments.first { $0.health != .healthy } ?? deploymentEnvironments.first
    }
}
