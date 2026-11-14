import BuildData
import ExternalTools
import Foundation
import MCPKit

/// What the traces of a time window say about the graph (docs/data.md › Clusters › Calls and requests).
public struct ServiceActivity: Sendable, Hashable {
    public struct Calls: Sendable, Hashable {
        public var count = 0
        public var errors = 0
        public init() {}
    }

    public struct Figures: Sendable, Hashable {
        public var requests = 0
        public var errors = 0
        public var p95Ms = 0
        /// Requests in each of 30 equal parts of the window, oldest first.
        public var series: [Int] = Array(repeating: 0, count: 30)
        public init() {}
    }

    public struct Request: Sendable, Hashable {
        public let id: String
        public let method: String
        public let route: String
        public let status: Int?
        public let start: Date
        public let durationMs: Int
        /// In start order: service, name, start from the request's, duration, failed.
        public let spans: [(service: String, name: String, startMs: Int, durationMs: Int, failed: Bool)]
        public let logs: [Log]

        public static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id && lhs.durationMs == rhs.durationMs && lhs.spans.count == rhs.spans.count }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    public struct Log: Sendable, Hashable {
        public let time: Date
        public let service: String
        public let level: String
        public let message: String
        public let request: String
    }

    /// By arrow, `from→to`.
    public var calls: [String: Calls] = [:]
    /// By service.
    public var figures: [String: Figures] = [:]
    /// Newest first.
    public var requests: [Request] = []
    public var traces = 0

    /// Reads the spans of a window against the graph: client spans count as calls of the graph's arrows, server
    /// spans as each service's requests, and each trace whose first span is a server span of a service as a
    /// request, once it is 3 s old.
    public static func analyze(_ spans: [TraceSpan], graph: ServiceGraph, from start: Date, to end: Date, now: Date = Date()) -> ServiceActivity {
        var activity = ServiceActivity()
        let services = Set(graph.boxes.filter { $0.kind == .service }.map(\.id))
        let arrows = Set(graph.arrows.map { "\($0.from)→\($0.to)" })
        var unique: [String: TraceSpan] = [:]
        for span in spans where span.start >= start && span.start <= end { unique[span.traceID + span.spanID] = span }
        let window = max(1, end.timeIntervalSince(start))
        var durations: [String: [Int]] = [:]
        for span in unique.values where services.contains(span.service) {
            switch span.kind {
            case .client:
                let target: String?
                if span.attributes["db.system.name"] == "postgresql" || span.attributes["db.system"] == "postgresql" {
                    target = "\(span.service)-postgres"
                } else if span.attributes["rpc.system"] == "aws-api", span.attributes["rpc.service"] == "S3" {
                    target = "\(span.service)-bucket"
                } else {
                    target = span.attributes["server.address"].flatMap { $0.split(separator: ".").first.map(String.init) }
                }
                guard let target, arrows.contains("\(span.service)→\(target)") else { continue }
                activity.calls["\(span.service)→\(target)", default: Calls()].count += 1
                if span.failed || (span.status ?? 0) >= 500 { activity.calls["\(span.service)→\(target)", default: Calls()].errors += 1 }
            case .server:
                var figures = activity.figures[span.service, default: Figures()]
                figures.requests += 1
                if span.failed || (span.status ?? 0) >= 500 { figures.errors += 1 }
                let bucket = min(29, max(0, Int(span.start.timeIntervalSince(start) / window * 30)))
                figures.series[bucket] += 1
                activity.figures[span.service] = figures
                durations[span.service, default: []].append(span.durationMs)
            default:
                break
            }
        }
        for (service, values) in durations {
            let sorted = values.sorted()
            activity.figures[service]?.p95Ms = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        }
        let traces = Dictionary(grouping: unique.values, by: \.traceID)
        activity.traces = traces.count
        activity.requests = traces.compactMap { id, spans in request(id, spans, services: services, now: now) }.sorted { $0.start > $1.start }
        return activity
    }

    /// The request of a trace: its first span, a server span of a service, at least 3 s old.
    public static func request(_ id: String, _ spans: [TraceSpan], services: Set<String>, now: Date = Date()) -> Request? {
        let ids = Set(spans.map(\.spanID))
        guard let root = spans.filter({ $0.parentID.map { !ids.contains($0) } ?? true }).min(by: { $0.start < $1.start }),
              root.kind == .server, services.contains(root.service), now.timeIntervalSince(root.start) >= 3 else { return nil }
        let ordered = spans.sorted { $0.start < $1.start }
        let logs = ordered.flatMap { span in
            span.events.compactMap { event -> Log? in
                guard let level = event.attributes["log.level"] else { return nil }
                return Log(time: event.time, service: span.service, level: level, message: event.name, request: id)
            }
        }.sorted { $0.time < $1.time }
        return Request(
            id: id, method: root.attributes["http.request.method"] ?? root.name.split(separator: " ").first.map(String.init) ?? "",
            route: root.attributes["http.route"] ?? root.attributes["url.path"] ?? root.name, status: root.status, start: root.start,
            durationMs: root.durationMs,
            spans: ordered.map { ($0.service, $0.name, max(0, Int($0.start.timeIntervalSince(root.start) * 1000)), $0.durationMs, $0.failed) },
            logs: logs
        )
    }
}

/// The sources of the services, read with gh at their deployed commit and kept until the app quits; a missing file
/// is empty, a failed read is tried again at the next read.
public actor ServiceSources {
    private var files: [String: String] = [:]
    public init() {}

    public func read(_ cli: GitHubCLI, owner: String, repository: String, commit: String) async -> (goMod: String, values: String, problem: String?) {
        var problem: String?
        var texts: [String] = []
        for path in ["go.mod", "deployment/values-prod.yml"] {
            let key = "\(owner)/\(repository)@\(commit):\(path)"
            if let cached = files[key] { texts.append(cached); continue }
            do throws(BuildError) {
                let data = try await cli.run("api", ["api", "--header=Accept: application/vnd.github.raw",
                                                     "repos/\(owner)/\(repository)/contents/\(path)?ref=\(commit)"])
                let text = String(decoding: data, as: UTF8.self)
                files[key] = text
                texts.append(text)
            } catch {
                if error.description.contains("HTTP 404") {
                    files[key] = ""
                    texts.append("")
                } else {
                    problem = problem ?? Self.reason(error)
                    texts.append("")
                }
            }
        }
        return (texts[0], texts[1], problem)
    }

    static func reason(_ error: BuildError) -> String {
        switch error {
        case .unavailable(let message) where message == BuildError.noGH.description: "gh was not found in the PATH of the login shell"
        case .unavailable(let message) where message == BuildError.noLogin.description: "gh is not logged in; run gh auth login in Terminal"
        default: error.description.replacing("gh api failed: ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }
}

/// One read of a namespace's map: the graph, and the traces of a window from its Jaeger.
public struct ServiceMapRead: Sendable, Hashable {
    public var graph: ServiceGraph
    public var activity: ServiceActivity
    /// Why Jaeger couldn't be read; nil when it was.
    public var jaegerProblem: String?
    public var readAt: Date
    public var readSeconds: Double

    /// Reads the Deployments, their sources and the window's traces.
    public static func read(_ cluster: Cluster, gh: GitHubCLI, sources: ServiceSources, forwards: PortForwards,
                            window: TimeInterval, now: Date = Date()) async throws(ClusterError) -> ServiceMapRead {
        let deployments = try await cluster.deployments()
        let graph = await ServiceGraph.build(deployments: deployments) { owner, repository, commit in
            await sources.read(gh, owner: owner, repository: repository, commit: commit)
        }
        let start = now.addingTimeInterval(-window)
        let began = Date()
        var spans: [TraceSpan] = []
        var problem: String?
        if let jaeger = cluster.target.jaeger, !jaeger.isEmpty {
            let parts = jaeger.split(separator: "/", maxSplits: 1).map(String.init)
            let (namespace, name) = parts.count == 2 ? (parts[0], parts[1]) : (cluster.target.namespace ?? "default", parts[0])
            do throws(ClusterError) {
                let forward = try await forwards.forward(cluster, target: "service/\(name)", namespace: namespace, remotePort: 16686, shared: true)
                let client = JaegerClient(port: forward.localPort)
                for box in graph.boxes where box.kind == .service {
                    spans += try await client.spans(service: box.id, from: start, to: now)
                }
            } catch {
                problem = error.description
            }
        } else {
            problem = "Environment “\(cluster.target.environment)” has no Jaeger."
        }
        let activity = ServiceActivity.analyze(spans, graph: graph, from: start, to: now, now: now)
        return ServiceMapRead(graph: graph, activity: activity, jaegerProblem: problem, readAt: now, readSeconds: Date().timeIntervalSince(began))
    }
}
