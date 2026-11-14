import ExternalTools
import Foundation
import MCPKit
import Synchronization
import Testing
@testable import ClusterData

/// Answers kubectl's calls from a script and records them; nothing reaches a cluster.
final class FakeKubectl: ProcessRunning {
    private let calls = Mutex<[[String]]>([])
    let answer: @Sendable ([String]) -> ProcessResult

    init(_ answer: @escaping @Sendable ([String]) -> ProcessResult) { self.answer = answer }
    var arguments: [[String]] { calls.withLock { $0 } }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        calls.withLock { $0.append(request.arguments) }
        return answer(request.arguments)
    }
}

private func ok(_ text: String) -> ProcessResult { ProcessResult(termination: .exited(0), standardOutput: Data(text.utf8)) }

private func cluster(_ runner: FakeKubectl, target: ClusterTarget = ClusterTarget(environment: "Staging", kubeconfig: "~/.kube/staging",
                                                                                 namespace: "shop", deployment: "orders-api", argoCDApplication: "argo/orders")) -> Cluster {
    Cluster(kubectl: Kubectl(executable: "/usr/local/bin/kubectl", environment: [:], runner: runner, homeDirectory: "/Users/you"), target: target)
}

private func deployment(_ name: String, image: String, replicas: Int = 2, ready: Int = 2) -> JSONValue {
    ["metadata": ["name": .string(name)], "spec": ["replicas": .int(replicas), "template": ["spec": ["containers": [["image": .string(image)]]]]],
     "status": ["readyReplicas": .int(ready)]]
}

@Suite("Clusters")
struct ClusterTests {
    @Test("Every command starts with the kubeconfig and the namespace; status reads the Deployment and its pods")
    func status() async throws {
        let runner = FakeKubectl { arguments in
            if arguments.contains("deployment/orders-api") {
                return ok(#"{"spec":{"replicas":3,"selector":{"matchLabels":{"app":"orders"}},"template":{"spec":{"containers":[{"image":"ghcr.io/a/orders:sha-abcdef1"}]}}},"status":{"readyReplicas":2,"updatedReplicas":3,"availableReplicas":2}}"#)
            }
            return ok(#"{"items":[{"metadata":{"name":"orders-api-7d-x1"},"status":{"phase":"Running","startTime":"2026-11-14T09:00:00Z","containerStatuses":[{"ready":true,"restartCount":2}]}}]}"#)
        }
        let status = try await cluster(runner).status()
        #expect(runner.arguments[0] == ["--kubeconfig=/Users/you/.kube/staging", "--namespace=shop", "get", "deployment/orders-api", "-o", "json"])
        #expect(runner.arguments[1].suffix(5) == ["get", "pods", "--selector=app=orders", "-o", "json"])
        #expect(status.replicas == 3 && status.ready == 2 && status.pods.first?.restarts == 2 && status.pods.first?.ready == true)
    }

    @Test("Restart, scale and logs; Argo CD in the Application's namespace; V2's failure messages")
    func changes() async throws {
        let runner = FakeKubectl { arguments in
            if arguments.contains("applications.argoproj.io/orders") { return ok(#"{"status":{"sync":{"status":"OutOfSync","revision":"abc"},"health":{"status":"Healthy"}}}"#) }
            if arguments.contains("scale") { return ProcessResult(termination: .exited(1), standardError: Data(" forbidden \n".utf8)) }
            return ok("deployment.apps/orders-api restarted\n")
        }
        let cluster = cluster(runner)
        #expect(try await cluster.restart() == "deployment.apps/orders-api restarted")
        #expect(runner.arguments.last?.suffix(3) == ["rollout", "restart", "deployment/orders-api"])
        await #expect(throws: ClusterError.unavailable("kubectl --kubeconfig=/Users/you/.kube/staging --namespace=shop scale deployment/orders-api --replicas=1 exited with code 1: forbidden")) {
            try await cluster.scale(to: 1)
        }
        await #expect(throws: ClusterError.invalid("replicas: use 0 to 100.")) { try await cluster.scale(to: 101) }
        _ = try await cluster.logs(tailLines: 50)
        #expect(runner.arguments.last?.suffix(5) == ["logs", "deployment/orders-api", "--tail=50", "--timestamps", "--all-containers"])
        let argo = try await cluster.argoCDStatus()
        #expect(argo.sync == "OutOfSync" && argo.health == "Healthy" && argo.revision == "abc")
        #expect(runner.arguments.last?.contains("--namespace=argo") == true)
        _ = try await cluster.argoCDSync()
        #expect(runner.arguments.last?.contains("--type=merge") == true)
        let none = Cluster(kubectl: cluster.kubectl, target: ClusterTarget(environment: "Local"))
        await #expect(throws: ClusterError.invalid("Environment “Local” has no deployment.")) { try await none.restart() }
        await #expect(throws: ClusterError.invalid("Environment “Local” has no Argo CD application.")) { try await none.argoCDSync() }
    }

    @Test("Port forwards read kubectl's forwarding line")
    func forwardingLine() {
        #expect(PortForwards.forwardingPort("Forwarding from 127.0.0.1:54321 -> 16686", remotePort: 16686) == 54321)
        #expect(PortForwards.forwardingPort("Forwarding from [::1]:54321 -> 16686", remotePort: 16686) == nil)
        #expect(PortForwards.forwardingPort("Forwarding from 127.0.0.1:54321 -> 8080", remotePort: 16686) == nil)
    }
}

@Suite("Service graph")
struct ServiceGraphTests {
    @Test("Boxes from ghcr images, Clusters and buckets from the sources, arrows from the modules of other services")
    func build() async {
        let deployments = [
            deployment("orders-api", image: "ghcr.io/azavech/orders:sha-1234567"),
            deployment("payments-api", image: "ghcr.io/azavech/payments:sha-89abcde", replicas: 2, ready: 1),
            deployment("redis", image: "redis:7"),
            deployment("shared", image: "ghcr.io/azavech/yc-shared:sha-1234567"),
        ]
        let graph = await ServiceGraph.build(deployments: deployments) { _, repository, _ in
            switch repository {
            case "orders":
                ("module github.com/azavech/orders\n\nrequire (\n\tgithub.com/azavech/payments/client v1.2.0\n\tgithub.com/azavech/yc-shared/gormpg/v2 v2.0.0 // db\n)\n",
                 "s3:\n  enabled: \"Yes\" # files\n", nil)
            default:
                ("module github.com/azavech/payments\n", "", "timeout")
            }
        }
        #expect(graph.boxes.map(\.id) == ["orders-api", "payments-api", "orders-api-postgres", "orders-api-bucket"])
        #expect(graph.arrows.map { "\($0.from)→\($0.to)" } == ["orders-api→payments-api", "orders-api→orders-api-postgres", "orders-api→orders-api-bucket"])
        #expect(graph.boxes[1].ready == 1 && graph.boxes[1].replicas == 2)
        #expect(graph.problems == ["The sources of payments-api cannot be read: timeout."])
    }

    @Test("go.mod's required modules and the values file's dotted paths")
    func sources() {
        #expect(ServiceGraph.requiredModules("require github.com/a/b v1\nreplace github.com/x/y => ../y\n") == ["github.com/a/b"])
        #expect(ServiceGraph.values("postgres:\n  enabled: 'true'\n  # off\nname: x # comment\n") == ["postgres.enabled": "true", "name": "x"])
        #expect(ServiceGraph.image("ghcr.io/a/b:latest") == nil)
    }
}

@Suite("Traces")
struct TraceTests {
    private static let otlp = """
        {"result":{"resourceSpans":[
         {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"orders-api"}}]},"scopeSpans":[{"spans":[
          {"traceId":"AB12","spanId":"1","name":"POST /orders/{id}/checkout","kind":2,"startTimeUnixNano":"1763110800000000000","endTimeUnixNano":"1763110804200000000",
           "attributes":[{"key":"http.route","value":{"stringValue":"/orders/{id}/checkout"}},{"key":"http.request.method","value":{"stringValue":"POST"}},
                         {"key":"http.response.status_code","value":{"intValue":"504"}}],"status":{"code":2},
           "events":[{"timeUnixNano":"1763110804000000000","name":"payment timed out","attributes":[{"key":"log.level","value":{"stringValue":"error"}}]}]},
          {"traceId":"AB12","spanId":"2","parentSpanId":"1","name":"POST /charges","kind":"SPAN_KIND_CLIENT","startTimeUnixNano":"1763110800100000000",
           "endTimeUnixNano":"1763110804100000000","attributes":[{"key":"server.address","value":{"stringValue":"payments-api.shop.svc"}}]},
          {"traceId":"AB12","spanId":"3","parentSpanId":"1","name":"SELECT","kind":3,"startTimeUnixNano":"1763110800050000000",
           "endTimeUnixNano":"1763110800060000000","attributes":[{"key":"db.system.name","value":{"stringValue":"postgresql"}}]}]}]},
         {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"payments-api"}}]},"scopeSpans":[{"spans":[
          {"traceId":"AB12","spanId":"4","parentSpanId":"2","name":"POST /charges","kind":2,"startTimeUnixNano":"1763110800200000000",
           "endTimeUnixNano":"1763110804000000000","attributes":[{"key":"http.status_code","value":{"intValue":"502"}}]}]}]}]}}
        """

    @Test("OTLP spans: services, kinds, attributes, failures and log events")
    func spans() throws {
        let spans = TraceSpan.spans(try JSONValue.parse(Data(Self.otlp.utf8)))
        #expect(spans.map(\.service) == ["orders-api", "orders-api", "orders-api", "payments-api"])
        #expect(spans[0].kind == .server && spans[1].kind == .client && spans[0].failed && spans[0].status == 504 && spans[0].durationMs == 4200)
        #expect(spans[0].events.first?.attributes["log.level"] == "error" && spans[0].traceID == "ab12")
    }

    @Test("A window's calls per arrow, the services' figures and the requests with their spans and logs")
    func analyze() throws {
        let spans = TraceSpan.spans(try JSONValue.parse(Data(Self.otlp.utf8)))
        let graph = ServiceGraph(boxes: [
            .init(id: "orders-api", kind: .service), .init(id: "payments-api", kind: .service), .init(id: "orders-api-postgres", kind: .database),
        ], arrows: [.init(from: "orders-api", to: "payments-api"), .init(from: "orders-api", to: "orders-api-postgres")], problems: [])
        let start = Date(timeIntervalSince1970: 1_763_110_700)
        let activity = ServiceActivity.analyze(spans, graph: graph, from: start, to: start.addingTimeInterval(300), now: start.addingTimeInterval(400))
        #expect(activity.calls["orders-api→payments-api"]?.count == 1 && activity.calls["orders-api→orders-api-postgres"]?.count == 1)
        #expect(activity.figures["payments-api"]?.errors == 1 && activity.figures["orders-api"]?.p95Ms == 4200)
        let request = try #require(activity.requests.first)
        #expect(request.method == "POST" && request.route == "/orders/{id}/checkout" && request.status == 504 && request.durationMs == 4200)
        #expect(request.spans.map(\.service) == ["orders-api", "orders-api", "orders-api", "payments-api"] && request.spans[3].startMs == 200)
        #expect(request.logs.map(\.message) == ["payment timed out"])
        let young = ServiceActivity.analyze(spans, graph: graph, from: start, to: start.addingTimeInterval(300), now: start.addingTimeInterval(101))
        #expect(young.requests.isEmpty, "A request is listed once 3 s old")
    }
}
