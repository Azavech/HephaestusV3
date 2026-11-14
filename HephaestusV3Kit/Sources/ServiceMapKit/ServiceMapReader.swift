import Foundation
import ToolsFoundation

/// The Service Map's read function for other clients, the chat among them: a service or a request, in
/// a sentence, with the questions worth asking about it. In the real suite it answers from the tool's
/// API; here, from the sample map.
public enum ServiceMapReader {
    /// `focus` is `service:<name>` or `request:<id>`, as the Service Map's routes. `environment` is the
    /// name of the environment the user has on screen, which the chat panel's subject carries; without
    /// one, or with a name the project doesn't have, the first that isn't healthy is read.
    public static func read(_ focus: String, environment: String? = nil, project: Project) -> ToolReading? {
        read(focus, environment: environment, project: project, store: SampleServiceMapStore())
    }

    static func read(_ focus: String, environment environmentName: String?, project: Project, store: any ServiceMapStore) -> ToolReading? {
        let named = environmentName.flatMap { name in project.deploymentEnvironments.first { $0.name == name } }
        guard let environment = named ?? project.openingEnvironment else { return nil }
        let map = store.map(environment: environment.name)
        switch MapSelection(focus: focus) {
        case .service(let id)?:
            guard let node = map.node(id) else { return nil }
            return ToolReading(
                action: String(localized: "Read service \(id)", bundle: #bundle, comment: "What the chat did: it read a service of the Service Map"),
                detail: detail(of: node, in: environment.name),
                suggestions: suggestions(for: node)
            )
        case .request(let id)?:
            guard let request = map.request(id) else { return nil }
            return ToolReading(
                action: String(localized: "Read request \(id)", bundle: #bundle, comment: "What the chat did: it read a request of the Service Map"),
                detail: detail(of: request, services: map.serviceCount(of: request), in: environment.name),
                suggestions: suggestions(for: request)
            )
        case nil:
            return nil
        }
    }

    /// The service or request shown in `environment`, as the chat panel names it.
    static func reference(_ selection: MapSelection, in project: Project, environment: String) -> ChatReference {
        switch selection {
        case .service(let id), .request(let id):
            ChatReference(tool: .serviceMap, projectID: project.id, focus: selection.focus, title: id, environment: environment)
        }
    }

    // MARK: Details

    /// "payments-api is degraded in Staging: p95 latency 4.1 sec, error rate 6.8%, 1 of 2 pods ready."
    static func detail(of node: ServiceNode, in environment: String) -> String {
        // Data written as it is: these sentences are read as Markdown for their inflected counts.
        let id = ServiceMapFormat.literal(node.id)
        let environment = ServiceMapFormat.literal(environment)
        let latency = ServiceMapFormat.literal(ServiceMapFormat.duration(node.p95))
        let errors = ServiceMapFormat.literal(ServiceMapFormat.percent(node.errorRate))
        let ready = node.readyPods
        let pods = node.pods
        // One whole sentence per health, with and without pods: an external service runs none.
        let sentence: AttributedString = switch (node.health, node.hasPods) {
        case (.healthy, true):
            AttributedString(localized: "\(id) is healthy in \(environment): p95 latency \(latency), error rate \(errors), \(ready) of ^[\(pods) pod](inflect: true) ready.", bundle: #bundle, comment: "A service read by the chat")
        case (.degraded, true):
            AttributedString(localized: "\(id) is degraded in \(environment): p95 latency \(latency), error rate \(errors), \(ready) of ^[\(pods) pod](inflect: true) ready.", bundle: #bundle, comment: "A service read by the chat")
        case (.down, true):
            AttributedString(localized: "\(id) is down in \(environment): p95 latency \(latency), error rate \(errors), \(ready) of ^[\(pods) pod](inflect: true) ready.", bundle: #bundle, comment: "A service read by the chat")
        case (.healthy, false):
            AttributedString(localized: "\(id) is healthy in \(environment): p95 latency \(latency), error rate \(errors).", bundle: #bundle, comment: "An external service read by the chat")
        case (.degraded, false):
            AttributedString(localized: "\(id) is degraded in \(environment): p95 latency \(latency), error rate \(errors).", bundle: #bundle, comment: "An external service read by the chat")
        case (.down, false):
            AttributedString(localized: "\(id) is down in \(environment): p95 latency \(latency), error rate \(errors).", bundle: #bundle, comment: "An external service read by the chat")
        }
        return String(sentence.characters)
    }

    /// "In Staging, POST /orders/8812/checkout answered 504 after 4.2 sec, through 3 services."
    static func detail(of request: ServiceRequest, services: Int, in environment: String) -> String {
        // Data written as it is: the sentence is read as Markdown for its inflected count.
        let environment = ServiceMapFormat.literal(environment)
        let method = ServiceMapFormat.literal(request.method)
        let path = ServiceMapFormat.literal(request.path)
        let status = String(request.status)
        let duration = ServiceMapFormat.literal(ServiceMapFormat.duration(request.duration))
        let sentence = AttributedString(localized: "In \(environment), \(method) \(path) answered \(status) after \(duration), through ^[\(services) service](inflect: true).", bundle: #bundle, comment: "A request read by the chat: its method and path, its HTTP status, its duration and the services it went through")
        return String(sentence.characters)
    }

    // MARK: Suggestions

    /// The questions worth asking about a node in its state, the most pressing first, at most three.
    static func suggestions(for node: ServiceNode) -> [String] {
        let id = node.id
        var questions: [String] = []
        switch node.health {
        case .degraded: questions.append(String(localized: "Why is \(id) degraded?", bundle: #bundle, comment: "A question the chat suggests about a service"))
        case .down: questions.append(String(localized: "Why is \(id) down?", bundle: #bundle, comment: "A question the chat suggests about a service"))
        case .healthy: break
        }
        if node.p95 >= 1_000 {
            questions.append(String(localized: "Why is \(id) slow?", bundle: #bundle, comment: "A question the chat suggests about a slow service"))
        }
        if node.errorRate >= 0.01 {
            questions.append(String(localized: "What are \(id)'s errors?", bundle: #bundle, comment: "A question the chat suggests about a service with errors"))
        }
        if node.hasPods, node.readyPods < node.pods {
            questions.append(String(localized: "Why aren't all pods of \(id) ready?", bundle: #bundle, comment: "A question the chat suggests about a service with pods not ready"))
        }
        questions.append(String(localized: "What calls \(id)?", bundle: #bundle, comment: "A question the chat suggests about a service"))
        if node.kind.isService, questions.count < 3 {
            questions.append(String(localized: "What does \(id) call?", bundle: #bundle, comment: "A question the chat suggests about a healthy service"))
        }
        return Array(questions.prefix(3))
    }

    /// The questions worth asking about a request in its state, at most three.
    static func suggestions(for request: ServiceRequest) -> [String] {
        let id = request.id
        var questions: [String] = []
        if request.failed {
            questions.append(String(localized: "Why did \(id) fail?", bundle: #bundle, comment: "A question the chat suggests about a failed request"))
        }
        if request.isSlow {
            questions.append(String(localized: "Which service made \(id) slow?", bundle: #bundle, comment: "A question the chat suggests about a slow request"))
        }
        questions.append(String(localized: "Which services handled \(id)?", bundle: #bundle, comment: "A question the chat suggests about a request"))
        return questions
    }
}
