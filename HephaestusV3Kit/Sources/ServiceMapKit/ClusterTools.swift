import ClusterData
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// The Kubernetes, Argo CD and map operations the MCP server offers Claude (docs/mcp.md › Cluster tools): the
/// Deployment, Argo CD Application and Jaeger an environment of a project names, as the Service Map reads them.
public enum ClusterTools {
    @MainActor
    public static func operations(maps: LiveServiceMapStore, projects: ProjectSession) -> [ToolOperation] {
        let set = ClusterToolSet(maps: maps, projects: projects)
        return [set.status, set.logs, set.events, set.restart, set.scale, set.portForward, set.stopPortForward, set.argoStatus, set.argoSync,
                set.serviceMap, set.request]
    }

    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")
    static let environment = ToolSchema.string("An environment of the project, such as Staging.")

    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in
            let project = (arguments["projectID"]?.stringValue ?? "").uppercased()
            let environment = arguments["environment"]?.stringValue ?? ""
            let map = ToolItem(tool: "serviceMap", projectID: project, focus: "", title: project)
            switch name {
            case "k8s_status": return ToolCallText(action: String(localized: "Read the deployment of \(project) in \(environment)", bundle: #bundle), item: map)
            case "k8s_logs": return ToolCallText(action: String(localized: "Read the logs of \(project) in \(environment)", bundle: #bundle), item: map)
            case "k8s_events": return ToolCallText(action: String(localized: "Read the events of \(project) in \(environment)", bundle: #bundle), item: map)
            case "k8s_restart":
                return ToolCallText(action: String(localized: "Restarted \(project) in \(environment)", bundle: #bundle),
                                    request: String(localized: "Claude wants to restart the pods of \(project) in \(environment)", bundle: #bundle), item: map)
            case "k8s_scale":
                let replicas = arguments["replicas"]?.intValue ?? 0
                return ToolCallText(action: String(localized: "Scaled \(project) in \(environment) to \(replicas)", bundle: #bundle),
                                    request: String(localized: "Claude wants to scale \(project) in \(environment) to \(replicas) pods", bundle: #bundle), item: map)
            case "k8s_port_forward":
                let port = arguments["remotePort"]?.intValue ?? 0
                return ToolCallText(action: String(localized: "Forwarded port \(port) of \(project) in \(environment)", bundle: #bundle),
                                    request: String(localized: "Claude wants to forward port \(port) of \(project) in \(environment) to this Mac", bundle: #bundle), item: map)
            case "k8s_stop_port_forward":
                return ToolCallText(action: String(localized: "Stopped a port forward", bundle: #bundle),
                                    request: String(localized: "Claude wants to stop a port forward", bundle: #bundle))
            case "argocd_status": return ToolCallText(action: String(localized: "Read Argo CD for \(project) in \(environment)", bundle: #bundle), item: map)
            case "argocd_sync":
                return ToolCallText(action: String(localized: "Synced \(project) in \(environment) with Argo CD", bundle: #bundle),
                                    request: String(localized: "Claude wants to sync \(project) in \(environment) with Argo CD", bundle: #bundle), item: map)
            case "get_service_map": return ToolCallText(action: String(localized: "Read the service map of \(project) in \(environment)", bundle: #bundle), item: map)
            case "get_request":
                let id = arguments["requestID"]?.stringValue ?? ""
                return ToolCallText(action: String(localized: "Read request \(id)", bundle: #bundle),
                                    item: ToolItem(tool: "serviceMap", projectID: project, focus: "request:\(id)", title: id))
            default: return ToolCallText(action: name)
            }
        }
    }
}

@MainActor
private struct ClusterToolSet {
    let maps: LiveServiceMapStore
    let projects: ProjectSession

    func cluster(_ arguments: JSONValue) throws(ToolError) -> Cluster {
        let id = try arguments.string("projectID").uppercased()
        let environment = try arguments.string("environment")
        do throws(ClusterError) {
            return try maps.cluster(id, environment: environment)
        } catch {
            throw Self.toolError(error)
        }
    }

    static func toolError(_ error: ClusterError) -> ToolError {
        switch error {
        case .invalid(let message): ToolError(.invalid, message)
        case .unavailable(let message): ToolError(.unavailable, message)
        case .unexpected(let message): ToolError(.internal, message)
        }
    }

    func call<T>(_ work: () async throws(ClusterError) -> T) async throws(ToolError) -> T {
        do { return try await work() } catch { throw Self.toolError(error) }
    }

    func operation(_ name: String, _ description: String, _ properties: [(String, ToolSchema)], required: [String] = ["projectID", "environment"],
                   permission: ToolPermission, run: @escaping @MainActor (JSONValue) async throws(ToolError) -> JSONValue) -> ToolOperation {
        ToolOperation(name: name, description: description,
                      inputSchema: .object(properties: [("projectID", ClusterTools.projectID), ("environment", ClusterTools.environment)] + properties,
                                           required: required),
                      permission: permission, describe: ClusterTools.describe(name)) { @MainActor arguments throws(ToolError) in
            try await run(arguments)
        }
    }

    static func date(_ date: Date?) -> JSONValue { date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }

    var status: ToolOperation {
        operation("k8s_status", "Returns the environment's Deployment: its replicas, ready, updated and available pods, its images, and each pod's phase, readiness, restarts and start.", [], permission: .read) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            let status = try await call { () throws(ClusterError) in try await cluster.status() }
            return ["deployment": .string(status.name), "replicas": .int(status.replicas), "ready": .int(status.ready), "updated": .int(status.updated),
                    "available": .int(status.available), "images": .array(status.images.map(JSONValue.string)),
                    "pods": .array(status.pods.map { ["name": .string($0.name), "phase": .string($0.phase), "ready": .bool($0.ready),
                                                      "restarts": .int($0.restarts), "started": Self.date($0.started)].removingNullMembers })]
        }
    }

    var logs: ToolOperation {
        operation("k8s_logs", "Returns log lines of the environment's Deployment, all its containers, or of one pod; the last 200 by default.", [
            ("pod", .string("A pod's name, as k8s_status gives it.")), ("container", .string("A container of the pod.")),
            ("tailLines", .integer("The last lines to return.", minimum: 1, maximum: 5000)),
            ("sinceSeconds", .integer("Only lines of the last seconds.", minimum: 1)),
            ("previous", .boolean("The previous container's lines, after a restart.")),
        ], permission: .read) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            return .string(try await call { () throws(ClusterError) in
                try await cluster.logs(pod: arguments["pod"]?.stringValue, container: arguments["container"]?.stringValue,
                                       tailLines: arguments["tailLines"]?.intValue, sinceSeconds: arguments["sinceSeconds"]?.intValue,
                                       previous: arguments["previous"]?.boolValue == true)
            })
        }
    }

    var events: ToolOperation {
        operation("k8s_events", "Returns the events of the environment's Deployment, its ReplicaSets and its pods, newest first.", [], permission: .read) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            return .array(try await call { () throws(ClusterError) in try await cluster.events() }.map { event in
                ["type": .string(event.type), "reason": .string(event.reason), "message": .string(event.message), "object": .string(event.object),
                 "count": .int(event.count), "lastSeen": Self.date(event.lastSeen)].removingNullMembers
            })
        }
    }

    var restart: ToolOperation {
        operation("k8s_restart", "Restarts the pods of the environment's Deployment (kubectl rollout restart).", [], permission: .operateClusters) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            return .string(try await call { () throws(ClusterError) in try await cluster.restart() })
        }
    }

    var scale: ToolOperation {
        operation("k8s_scale", "Sets the number of pods of the environment's Deployment.", [("replicas", .integer("0 to 100.", minimum: 0, maximum: 100))],
                  required: ["projectID", "environment", "replicas"], permission: .operateClusters) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            let replicas = arguments["replicas"]?.intValue ?? 0
            return .string(try await call { () throws(ClusterError) in try await cluster.scale(to: replicas) })
        }
    }

    var portForward: ToolOperation {
        operation("k8s_port_forward", "Forwards a port of the environment's Deployment to a port of this Mac on 127.0.0.1, until stopped or the app quits. Returns its id and local port.", [
            ("remotePort", .integer("The Deployment's port.", minimum: 1, maximum: 65535)),
            ("localPort", .integer("A port of this Mac; without it, a free one.", minimum: 1024, maximum: 65535)),
        ], required: ["projectID", "environment", "remotePort"], permission: .operateClusters) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            guard let deployment = cluster.target.deployment else { throw ToolError(.invalid, "Environment “\(cluster.target.environment)” has no deployment.") }
            let remote = arguments["remotePort"]?.intValue ?? 0
            let forward = try await call { () throws(ClusterError) in
                try await maps.forwards.forward(cluster, target: "deployment/\(deployment)", namespace: nil, remotePort: remote,
                                                localPort: arguments["localPort"]?.intValue, shared: false)
            }
            return ["portForwardID": .string(forward.id), "localPort": .int(forward.localPort), "remotePort": .int(forward.remotePort)]
        }
    }

    var stopPortForward: ToolOperation {
        ToolOperation(name: "k8s_stop_port_forward", description: "Stops a port forward that k8s_port_forward started.",
                      inputSchema: .object(properties: [("portForwardID", .string("The id k8s_port_forward returned."))], required: ["portForwardID"]),
                      permission: .operateClusters, describe: ClusterTools.describe("k8s_stop_port_forward")) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("portForwardID")
            guard await maps.forwards.stop(id) else { throw ToolError(.notFound, "Port forward \(id) not found.") }
            return [:]
        }
    }

    var argoStatus: ToolOperation {
        operation("argocd_status", "Returns the environment's Argo CD Application: its sync status, health, revision and running operation.", [], permission: .read) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            let status = try await call { () throws(ClusterError) in try await cluster.argoCDStatus() }
            return ["name": .string(status.name), "sync": .string(status.sync), "health": .string(status.health),
                    "revision": status.revision.map(JSONValue.string) ?? .null, "operation": status.operation.map(JSONValue.string) ?? .null].removingNullMembers
        }
    }

    var argoSync: ToolOperation {
        operation("argocd_sync", "Asks Argo CD to sync the environment's Application, as its own UI does.", [], permission: .operateClusters) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            return .string(try await call { () throws(ClusterError) in try await cluster.argoCDSync() })
        }
    }

    var serviceMap: ToolOperation {
        operation("get_service_map", "Returns the service map of the environment's namespace over the last hour: each service, database and bucket with its pods, health, requests per second, p95 latency and error rate, and each call with its calls per second and error rate.", [], permission: .read) { arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            let environment = try arguments.string("environment")
            _ = try cluster(arguments)
            let project = Project.sample(id) ?? Project(id: id, name: id, kind: .service, tint: .accent, symbol: "", path: "", repository: "", activity: nil)
            await maps.refresh(project, environment: environment, window: .hour)
            if case .failed(let message) = maps.status(of: project, environment: environment) { throw ToolError(.unavailable, message) }
            let map = maps.map(of: project, environment: environment)
            let nodes: [JSONValue] = map.nodes.map { node in
                var object: [String: JSONValue] = ["id": .string(node.id), "kind": .string("\(node.kind)")]
                object["pods"] = .int(node.pods)
                object["ready"] = .int(node.readyPods)
                object["health"] = .string("\(node.health)")
                object["requestsPerSecond"] = .double(node.requestsPerSecond)
                object["p95Ms"] = .int(node.p95)
                object["errorRate"] = .double(node.errorRate)
                return .object(object)
            }
            let calls: [JSONValue] = map.calls.map { call in
                var object: [String: JSONValue] = ["from": .string(call.from), "to": .string(call.to)]
                object["callsPerSecond"] = .double(call.requestsPerSecond)
                object["errorRate"] = .double(call.errorRate)
                return .object(object)
            }
            return ["nodes": .array(nodes), "calls": .array(calls), "requests": .int(map.requests.count)]
        }
    }

    var request: ToolOperation {
        operation("get_request", "Returns one request of the environment's traces by its id: its method, route, status, duration, spans and log lines.",
                  [("requestID", .string("The request's id: its trace id, 32 hexadecimal digits."))],
                  required: ["projectID", "environment", "requestID"], permission: .read) { arguments throws(ToolError) in
            let cluster = try cluster(arguments)
            let id = try arguments.string("requestID").lowercased()
            guard let jaeger = cluster.target.jaeger, !jaeger.isEmpty else { throw ToolError(.unavailable, "Environment “\(cluster.target.environment)” has no Jaeger.") }
            let parts = jaeger.split(separator: "/", maxSplits: 1).map(String.init)
            let (namespace, name) = parts.count == 2 ? (parts[0], parts[1]) : (cluster.target.namespace ?? "default", parts[0])
            let spans = try await call { () throws(ClusterError) in
                let forward = try await maps.forwards.forward(cluster, target: "service/\(name)", namespace: namespace, remotePort: 16686, shared: true)
                return try await JaegerClient(port: forward.localPort).trace(id)
            }
            guard let request = ServiceActivity.request(id, spans, services: Set(spans.map(\.service)), now: .distantFuture) else {
                throw ToolError(.notFound, "Request \(id) not found.")
            }
            return ["id": .string(request.id), "method": .string(request.method), "route": .string(request.route),
                    "status": request.status.map(JSONValue.int) ?? .null, "durationMs": .int(request.durationMs), "start": Self.date(request.start),
                    "spans": .array(request.spans.map { ["service": .string($0.service), "name": .string($0.name), "startMs": .int($0.startMs),
                                                         "durationMs": .int($0.durationMs), "failed": .bool($0.failed)] }),
                    "logs": .array(request.logs.map { ["time": Self.date($0.time), "service": .string($0.service), "level": .string($0.level),
                                                       "message": .string($0.message)] })].removingNullMembers
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The object, its `null` members left out.
    fileprivate var removingNullMembers: JSONValue { JSONValue.object(self).removingNullMembers }
}
