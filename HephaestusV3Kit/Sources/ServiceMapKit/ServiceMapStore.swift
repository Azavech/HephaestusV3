import BuildData
import ClusterData
import ExternalTools
import Foundation
import Observation
import ProjectData
import SwiftUI
import ToolsFoundation

/// How a map's last read went.
enum MapStatus: Hashable {
    /// The samples, or nothing to read.
    case none
    case reading
    /// Read; the problems of the sources and of Jaeger, each a sentence.
    case read(problems: [String])
    /// The read failed: kubectl's message.
    case failed(String)
}

/// Why a cluster action failed.
struct MapActionError: Error, Hashable {
    let message: String
}

/// Where the maps come from: `LiveServiceMapStore` in the app, on kubectl and Jaeger; the samples in previews.
protocol ServiceMapStore: AnyObject {
    func map(of project: Project, environment: String) -> ServiceMap
    func status(of project: Project, environment: String) -> MapStatus
    /// Reads the namespace and the window's traces again.
    func refresh(_ project: Project, environment: String, window: TimeWindow) async
    /// The project's own service in the environment: its Deployment.
    func ownService(of project: Project, environment: String) -> ServiceNode.ID?
    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod]
    /// Whether the store can act on the cluster: restart, scale, sync.
    var acts: Bool { get }
    func restart(_ project: Project, environment: String) async throws(MapActionError) -> String
    func scale(_ project: Project, environment: String, to replicas: Int) async throws(MapActionError) -> String
    func argoCD(_ project: Project, environment: String) async throws(MapActionError) -> ArgoCDStatus
    func sync(_ project: Project, environment: String) async throws(MapActionError) -> String
}

final class SampleServiceMapStore: ServiceMapStore {
    func map(of project: Project, environment: String) -> ServiceMap { ServiceMap.sample(environment: environment) }
    func map(environment: String) -> ServiceMap { ServiceMap.sample(environment: environment) }
    func status(of project: Project, environment: String) -> MapStatus { .none }
    func refresh(_ project: Project, environment: String, window: TimeWindow) async {}
    func ownService(of project: Project, environment: String) -> ServiceNode.ID? { ServiceMap.ownService(of: project.id) }
    func ownService(of projectID: Project.ID) -> ServiceNode.ID? { ServiceMap.ownService(of: projectID) }
    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod] { Pod.samples(of: service, environment: environment) }
    var acts: Bool { false }
    func restart(_ project: Project, environment: String) async throws(MapActionError) -> String { throw MapActionError(message: "") }
    func scale(_ project: Project, environment: String, to replicas: Int) async throws(MapActionError) -> String { throw MapActionError(message: "") }
    func argoCD(_ project: Project, environment: String) async throws(MapActionError) -> ArgoCDStatus { throw MapActionError(message: "") }
    func sync(_ project: Project, environment: String) async throws(MapActionError) -> String { throw MapActionError(message: "") }
}

/// The app's maps: each project's namespace in each environment, read with kubectl, the sources with gh, and the
/// traces from the environment's Jaeger (docs/ui/service-map.md, docs/data.md › Clusters).
@Observable
public final class LiveServiceMapStore: ServiceMapStore {
    private struct Entry: Hashable {
        var map: ServiceMap
        var status: MapStatus
    }

    private var entries: [String: Entry] = [:]
    private var pods: [String: [Pod]] = [:]
    @ObservationIgnored private let projects: ProjectSession
    @ObservationIgnored private let runner: any ProcessRunning
    @ObservationIgnored public let forwards = PortForwards()
    @ObservationIgnored private let sources = ServiceSources()
    @ObservationIgnored private var reading: Set<String> = []

    public init(projects: ProjectSession, runner: any ProcessRunning = SystemProcessRunner.shared) {
        self.projects = projects
        self.runner = runner
    }

    private func key(_ project: Project, _ environment: String) -> String { "\(project.id)|\(environment)" }

    func map(of project: Project, environment: String) -> ServiceMap {
        entries[key(project, environment)]?.map ?? ServiceMap(nodes: [], calls: [], requests: [], logs: [])
    }

    func status(of project: Project, environment: String) -> MapStatus {
        entries[key(project, environment)]?.status ?? .reading
    }

    /// The cluster calls of an environment of a project: its kubeconfig, namespace, Deployment, Argo CD and Jaeger.
    public func cluster(_ projectID: String, environment: String) throws(ClusterError) -> Cluster {
        guard let project = projects.snapshot.project(projectID) else { throw .invalid("Project \(projectID) not found.") }
        guard let entry = project.resolved.environments.first(where: { $0.name == environment }) else {
            throw .invalid("environment: \(projectID) has no environment named “\(environment)”.")
        }
        guard let kubectl = Kubectl(projects.tools, runner: runner) else { throw .invalid("kubectl was not found in the PATH of the login shell.") }
        return Cluster(kubectl: kubectl, target: ClusterTarget(
            environment: entry.name, kubeconfig: entry.kubeconfig, namespace: entry.namespace, deployment: entry.deployment,
            argoCDApplication: entry.argoCDApplication, jaeger: entry.jaeger, directory: project.root
        ))
    }

    func refresh(_ project: Project, environment: String, window: TimeWindow) async {
        let key = key(project, environment)
        guard reading.insert(key).inserted else { return }
        defer { reading.remove(key) }
        // A map read as the app opens waits for the first lookup of the tools rather than finding kubectl missing.
        await projects.waitForTools()
        let tools = projects.tools
        do throws(ClusterError) {
            let cluster = try cluster(project.id, environment: environment)
            let read = try await ServiceMapRead.read(cluster, gh: GitHubCLI(gh: tools.gh, environment: tools.environment, runner: runner),
                                                     sources: sources, forwards: forwards, window: TimeInterval(window.minutes * 60))
            let problems = read.graph.problems + (read.jaegerProblem.map { ["Jaeger cannot be reached: \($0)"] } ?? [])
            let entry = Entry(map: Self.map(read, window: window), status: .read(problems: problems))
            if entries[key] != entry { entries[key] = entry }
            if let own = cluster.target.deployment, let status = try? await cluster.status(), status.name == own {
                pods[key] = status.pods.map(Self.pod)
            }
        } catch {
            var entry = entries[key] ?? Entry(map: ServiceMap(nodes: [], calls: [], requests: [], logs: []), status: .reading)
            entry.status = .failed(error.description)
            entries[key] = entry
        }
    }

    func ownService(of project: Project, environment: String) -> ServiceNode.ID? {
        projects.snapshot.project(project.id)?.resolved.environments.first { $0.name == environment }?.deployment
    }

    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod] {
        pods.first { $0.key.hasSuffix("|\(environment.name)") }?.value ?? []
    }

    var acts: Bool { true }

    private func act<T>(_ project: Project, _ environment: String, _ work: (Cluster) async throws(ClusterError) -> T) async throws(MapActionError) -> T {
        do throws(ClusterError) {
            return try await work(try cluster(project.id, environment: environment))
        } catch {
            throw MapActionError(message: error.description)
        }
    }

    func restart(_ project: Project, environment: String) async throws(MapActionError) -> String {
        try await act(project, environment) { cluster throws(ClusterError) in try await cluster.restart() }
    }

    func scale(_ project: Project, environment: String, to replicas: Int) async throws(MapActionError) -> String {
        try await act(project, environment) { cluster throws(ClusterError) in try await cluster.scale(to: replicas) }
    }

    func argoCD(_ project: Project, environment: String) async throws(MapActionError) -> ArgoCDStatus {
        try await act(project, environment) { cluster throws(ClusterError) in try await cluster.argoCDStatus() }
    }

    func sync(_ project: Project, environment: String) async throws(MapActionError) -> String {
        try await act(project, environment) { cluster throws(ClusterError) in try await cluster.argoCDSync() }
    }

    // MARK: Mapping

    static func pod(_ pod: PodStatus) -> Pod {
        let age = pod.started.map { Duration.seconds(Date().timeIntervalSince($0)).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)) } ?? ""
        return Pod(name: pod.name, readyContainers: pod.ready ? 1 : 0, containers: 1, status: pod.phase, restarts: pod.restarts, age: age, node: nil)
    }

    /// A read as the window shows it: services, Clusters as databases and buckets as external services; arrows with
    /// their calls per second; the requests with their spans; the requests' log lines.
    static func map(_ read: ServiceMapRead, window: TimeWindow) -> ServiceMap {
        let seconds = Double(window.minutes * 60)
        let nodes = read.graph.boxes.map { box -> ServiceNode in
            let figures = read.activity.figures[box.id] ?? ServiceActivity.Figures()
            let health: DeploymentEnvironment.Health = box.kind != .service ? .healthy
                : box.ready == 0 && box.replicas > 0 ? .down : box.ready < box.replicas ? .degraded : .healthy
            let kind: ServiceNode.Kind = switch box.kind {
            case .service: .service
            case .database: .database
            case .bucket: .external
            }
            return ServiceNode(id: box.id, kind: kind, requestsPerSecond: Double(figures.requests) / seconds, p95: figures.p95Ms,
                               errorRate: figures.requests == 0 ? 0 : Double(figures.errors) / Double(figures.requests),
                               readyPods: box.ready, pods: box.replicas, health: health,
                               throughput: figures.series.map { Double($0) / (seconds / 30) })
        }
        let calls = read.graph.arrows.map { arrow -> ServiceCall in
            let counted = read.activity.calls["\(arrow.from)→\(arrow.to)"] ?? ServiceActivity.Calls()
            return ServiceCall(from: arrow.from, to: arrow.to, requestsPerSecond: Double(counted.count) / seconds,
                               errorRate: counted.count == 0 ? 0 : Double(counted.errors) / Double(counted.count))
        }
        let requests = read.activity.requests.map { request in
            ServiceRequest(id: request.id, method: request.method, path: request.route, status: request.status ?? 0, duration: request.durationMs,
                           startedAt: request.start, spans: request.spans.enumerated().map { index, span in
                               Span(id: index, service: span.service, operation: span.name, start: span.startMs, duration: span.durationMs, isError: span.failed)
                           })
        }
        var logID = 0
        let logs = read.activity.requests.flatMap(\.logs).map { log -> LogLine in
            logID += 1
            let level: LogLine.Level = switch log.level.lowercased() {
            case "error", "fatal", "panic": .error
            case "warning", "warn": .warning
            default: .info
            }
            return LogLine(id: logID, date: log.time, service: log.service, level: level, message: log.message, requestID: log.request)
        }
        return ServiceMap(nodes: nodes, calls: calls, requests: requests, logs: logs)
    }
}

extension EnvironmentValues {
    /// The app's maps; nil in previews.
    @Entry public var serviceMapStore: LiveServiceMapStore?
}
