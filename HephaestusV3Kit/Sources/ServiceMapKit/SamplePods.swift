import Foundation
import ToolsFoundation

/// A pod of a deployment, as `kubectl get pods -o wide` lists it (V2's PodStatus).
struct Pod: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let readyContainers: Int
    let containers: Int
    /// kubectl's STATUS, e.g. `Running` or `CrashLoopBackOff`.
    let status: String
    let restarts: Int
    /// kubectl's AGE, e.g. `5m12s`.
    let age: String
    /// Nil while the pod is not scheduled.
    let node: String?
}

extension Pod {
    /// The pods of `service`'s deployment in an environment, from its ready and total pods. In the
    /// real suite kubectl lists them; here they follow the sample map, so the pod that is not ready in
    /// Staging is the one payments-api is missing.
    static func samples(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod] {
        // A fixed hash of the name, as a ReplicaSet's template hash: the same at every launch.
        let hash = service.id.unicodeScalars.reduce(5_381) { ($0 &* 33 &+ Int($1.value)) & 0xF_FFFF_FFFF }
        let template = String(hash | 0x1_0000_0000, radix: 16)
        let age = switch environment.name {
        case "Production": "6d4h"
        case "Local": "42m"
        default: "19h"
        }
        return (0..<service.pods).map { index in
            let ready = index < service.readyPods
            let suffix = String((0..<5).map { offset in
                let letters = Array("bcdfghjklmnpqrstvwxz2456789")
                return letters[(index * 7 + offset * 13 + service.id.count * 3) % letters.count]
            })
            return Pod(
                name: "\(service.id)-\(template)-\(suffix)",
                readyContainers: ready ? 2 : 1, containers: 2,
                status: ready ? "Running" : "CrashLoopBackOff",
                restarts: ready ? index % 2 : 14,
                age: ready ? age : "11m",
                node: environment.cluster == "docker-desktop" ? "docker-desktop" : "\(environment.cluster)-node-\(index % 3 + 1)"
            )
        }
    }
}

extension ServiceMap {
    /// The requests that entered the namespace in each minute of `window`, the oldest first: the
    /// gateways' traffic, in a gentle wave.
    func requestsPerMinute(in window: TimeWindow) -> [Int] {
        let entry = nodes.filter { $0.kind == .gateway }.map(\.requestsPerSecond).reduce(0, +)
        let rate = entry > 0 ? entry : (nodes.map(\.requestsPerSecond).max() ?? 0)
        return (0..<window.minutes).map { minute in
            let phase = Double(minute) / 6
            return Int((rate * 60 * (1 + 0.16 * sin(phase) + 0.06 * cos(phase * 3.1))).rounded())
        }
    }
}
