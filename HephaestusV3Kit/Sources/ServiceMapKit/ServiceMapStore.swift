import Foundation
import ToolsFoundation

/// Where the Service Map's data comes from: the map of an environment's namespace, each project's own
/// service, and the pods of a deployment. The app and the previews use `SampleServiceMapStore`.
protocol ServiceMapStore {
    /// The services, calls, recent requests and logs of `environment`'s namespace.
    func map(environment: String) -> ServiceMap
    /// The service the project deploys, which its map opens on; nil for a project that deploys none
    /// of its own, such as a parent project.
    func ownService(of project: Project.ID) -> ServiceNode.ID?
    /// The pods of `service`'s deployment in `environment`.
    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod]
}

/// The sample `shop` namespace (`SampleServiceMap.swift`) and its pods (`SamplePods.swift`).
struct SampleServiceMapStore: ServiceMapStore {
    func map(environment: String) -> ServiceMap {
        ServiceMap.sample(environment: environment)
    }

    func ownService(of project: Project.ID) -> ServiceNode.ID? {
        ServiceMap.ownService(of: project)
    }

    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod] {
        Pod.samples(of: service, environment: environment)
    }
}
