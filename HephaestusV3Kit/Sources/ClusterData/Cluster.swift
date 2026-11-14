import ExternalTools
import Foundation
import MCPKit

/// Where an environment runs, as its project names it: the kubeconfig file, the namespace, the Deployment, the
/// Argo CD Application and Jaeger's Service (docs/data.md › Clusters).
public struct ClusterTarget: Sendable, Hashable {
    public var environment: String
    public var kubeconfig: String?
    public var namespace: String?
    public var deployment: String?
    /// `<name>` or `<namespace>/<name>`.
    public var argoCDApplication: String?
    /// Jaeger's Service, `<namespace>/<name>`.
    public var jaeger: String?
    /// The project's folder, where kubectl runs.
    public var directory: String?

    public init(environment: String, kubeconfig: String? = nil, namespace: String? = nil, deployment: String? = nil,
                argoCDApplication: String? = nil, jaeger: String? = nil, directory: String? = nil) {
        self.environment = environment
        self.kubeconfig = kubeconfig
        self.namespace = namespace
        self.deployment = deployment
        self.argoCDApplication = argoCDApplication
        self.jaeger = jaeger
        self.directory = directory
    }

    /// The Argo CD Application's namespace and name: `argocd` without a namespace; nil for another form.
    public var argoCD: (namespace: String, name: String)? {
        guard let value = argoCDApplication, !value.isEmpty else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return ("argocd", parts[0])
        case 2 where !parts[0].isEmpty && !parts[1].isEmpty: return (parts[0], parts[1])
        default: return nil
        }
    }
}

/// Why a cluster call failed, with its messages.
public enum ClusterError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalid(String)
    case unavailable(String)
    case unexpected(String)

    public var description: String {
        switch self {
        case .invalid(let message), .unavailable(let message), .unexpected(let message): message
        }
    }

    static func from(_ error: KubectlError) -> ClusterError {
        switch error {
        case .unexpectedOutput: .unexpected(error.description)
        default: .unavailable(error.description)
        }
    }
}

/// A Deployment and its pods.
public struct DeploymentStatus: Sendable, Hashable {
    public var name: String
    public var replicas: Int
    public var ready: Int
    public var updated: Int
    public var available: Int
    public var images: [String]
    public var pods: [PodStatus]
}

public struct PodStatus: Sendable, Hashable {
    public var name: String
    public var phase: String
    public var ready: Bool
    public var restarts: Int
    public var started: Date?
}

/// An event of the Deployment, its ReplicaSets or its pods.
public struct ClusterEvent: Sendable, Hashable {
    public var type: String
    public var reason: String
    public var message: String
    public var object: String
    public var count: Int
    public var lastSeen: Date?
}

/// An Argo CD Application's state.
public struct ArgoCDStatus: Sendable, Hashable {
    public var name: String
    public var sync: String
    public var health: String
    public var revision: String?
    public var operation: String?
}

/// The cluster calls of an environment (docs/data.md › Clusters › kubectl calls). Each command starts with
/// `--kubeconfig=` and `--namespace=` when the environment sets them, and runs at most 60 s.
public struct Cluster: Sendable {
    public let kubectl: Kubectl
    public let target: ClusterTarget

    public static let timeout: Duration = .seconds(60)

    public init(kubectl: Kubectl, target: ClusterTarget) {
        self.kubectl = kubectl
        self.target = target
    }

    func prefix(namespace: String? = nil) -> [String] {
        Kubectl.prefix(kubeconfig: target.kubeconfig, namespace: namespace ?? target.namespace, homeDirectory: kubectl.homeDirectory)
    }

    func run(_ arguments: [String], namespace: String? = nil) async throws(ClusterError) -> Data {
        do {
            return try await kubectl.run(prefix(namespace: namespace) + arguments, timeout: Self.timeout, directory: target.directory)
        } catch {
            throw .from(error)
        }
    }

    func json(_ arguments: [String], namespace: String? = nil) async throws(ClusterError) -> JSONValue {
        let output = try await run(arguments, namespace: namespace)
        guard let value = try? JSONValue.parse(output), value.objectValue != nil else {
            throw .unexpected("Unexpected output from \(Kubectl.command(prefix(namespace: namespace) + arguments)).")
        }
        return value
    }

    func deploymentName() throws(ClusterError) -> String {
        guard let name = target.deployment, !name.isEmpty else { throw .invalid("Environment “\(target.environment)” has no deployment.") }
        return name
    }

    /// The text of a command's output, without its final line break.
    static func text(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: Reads

    /// The Deployments of the namespace, as `get deployments -o json` gives them.
    public func deployments() async throws(ClusterError) -> [JSONValue] {
        try await json(["get", "deployments", "-o", "json"])["items"]?.arrayValue ?? []
    }

    /// The environment's Deployment and the pods its selector picks.
    public func status() async throws(ClusterError) -> DeploymentStatus {
        let name = try deploymentName()
        let deployment = try await json(["get", "deployment/\(name)", "-o", "json"])
        let labels = deployment["spec"]?["selector"]?["matchLabels"]?.objectValue ?? [:]
        let selector = labels.keys.sorted().compactMap { key in labels[key]?.stringValue.map { "\(key)=\($0)" } }.joined(separator: ",")
        let pods = selector.isEmpty ? [] : (try await json(["get", "pods", "--selector=\(selector)", "-o", "json"])["items"]?.arrayValue ?? [])
        let status = deployment["status"]
        return DeploymentStatus(
            name: name, replicas: deployment["spec"]?["replicas"]?.intValue ?? 0, ready: status?["readyReplicas"]?.intValue ?? 0,
            updated: status?["updatedReplicas"]?.intValue ?? 0, available: status?["availableReplicas"]?.intValue ?? 0,
            images: (deployment["spec"]?["template"]?["spec"]?["containers"]?.arrayValue ?? []).compactMap { $0["image"]?.stringValue },
            pods: pods.map { pod in
                let containers = pod["status"]?["containerStatuses"]?.arrayValue ?? []
                return PodStatus(name: pod["metadata"]?["name"]?.stringValue ?? "", phase: pod["status"]?["phase"]?.stringValue ?? "",
                                 ready: !containers.isEmpty && containers.allSatisfy { $0["ready"]?.boolValue == true },
                                 restarts: containers.reduce(0) { $0 + ($1["restartCount"]?.intValue ?? 0) },
                                 started: pod["status"]?["startTime"]?.stringValue.flatMap(ClusterDates.parse))
            }
        )
    }

    /// Log lines: of a pod, else of the Deployment; the last `tailLines` (200 by default), since `sinceSeconds`.
    public func logs(pod: String? = nil, container: String? = nil, tailLines: Int? = nil, sinceSeconds: Int? = nil,
                     previous: Bool = false) async throws(ClusterError) -> String {
        let source: String
        if let pod { source = pod } else { source = "deployment/\(try deploymentName())" }
        var arguments = ["logs", source, "--tail=\(tailLines ?? 200)", "--timestamps"]
        if pod == nil { arguments.append("--all-containers") }
        if let container { arguments.append("--container=\(container)") }
        if let sinceSeconds { arguments.append("--since=\(sinceSeconds)s") }
        if previous { arguments.append("--previous") }
        return Self.text(try await run(arguments))
    }

    /// The events of the Deployment, its ReplicaSets and its pods, newest first.
    public func events() async throws(ClusterError) -> [ClusterEvent] {
        let name = try deploymentName()
        let items = try await json(["get", "events", "-o", "json"])["items"]?.arrayValue ?? []
        return items.compactMap { event -> ClusterEvent? in
            guard let kind = event["involvedObject"]?["kind"]?.stringValue, let object = event["involvedObject"]?["name"]?.stringValue,
                  object == name || object.hasPrefix(name + "-") else { return nil }
            return ClusterEvent(type: event["type"]?.stringValue ?? "", reason: event["reason"]?.stringValue ?? "",
                                message: event["message"]?.stringValue ?? "", object: "\(kind)/\(object)",
                                count: event["count"]?.intValue ?? 1,
                                lastSeen: (event["lastTimestamp"]?.stringValue ?? event["eventTime"]?.stringValue).flatMap(ClusterDates.parse))
        }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    // MARK: Changes

    /// `rollout restart deployment/<name>`.
    public func restart() async throws(ClusterError) -> String {
        Self.text(try await run(["rollout", "restart", "deployment/\(try deploymentName())"]))
    }

    /// `scale deployment/<name> --replicas=<n>`, 0 to 100.
    public func scale(to replicas: Int) async throws(ClusterError) -> String {
        guard (0...100).contains(replicas) else { throw .invalid("replicas: use 0 to 100.") }
        return Self.text(try await run(["scale", "deployment/\(try deploymentName())", "--replicas=\(replicas)"]))
    }

    // MARK: Argo CD

    func application() throws(ClusterError) -> (namespace: String, name: String) {
        guard let application = target.argoCD else { throw .invalid("Environment “\(target.environment)” has no Argo CD application.") }
        return application
    }

    /// The Application's sync and health, its revision and its last operation.
    public func argoCDStatus() async throws(ClusterError) -> ArgoCDStatus {
        let application = try application()
        let value = try await json(["get", "applications.argoproj.io/\(application.name)", "-o", "json"], namespace: application.namespace)
        let status = value["status"]
        let operation = status?["operationState"]?["phase"]?.stringValue
        return ArgoCDStatus(name: application.name, sync: status?["sync"]?["status"]?.stringValue ?? "Unknown",
                            health: status?["health"]?["status"]?.stringValue ?? "Unknown",
                            revision: status?["sync"]?["revision"]?.stringValue ?? status?["sync"]?["revisions"]?.arrayValue?.first?.stringValue,
                            operation: operation)
    }

    /// Asks Argo CD to sync the Application, as its own UI does: an `operation` patched on it.
    public func argoCDSync() async throws(ClusterError) -> String {
        let application = try application()
        let current = try await argoCDStatus()
        if current.operation == "Running" { throw .unavailable("Argo CD is already syncing \(application.name).") }
        return Self.text(try await run(["patch", "applications.argoproj.io/\(application.name)", "--type=merge", "--patch=\(Self.syncPatch)"],
                                       namespace: application.namespace))
    }

    static let syncPatch = #"{"operation":{"initiatedBy":{"username":"Hephaestus"},"sync":{"syncStrategy":{"hook":{}}}}}"#
}

enum ClusterDates {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
