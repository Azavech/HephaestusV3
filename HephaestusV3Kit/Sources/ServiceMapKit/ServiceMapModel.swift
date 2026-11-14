import Foundation
import Observation
import ToolsFoundation

/// The Service Map window of one project: the environment shown, the view of the graph and the views
/// before it, what the details show, the requests and their order, and what the chat panel asks about.
///
/// The graph shows the whole namespace, a service in focus or a request. Each new view keeps the one it
/// replaced, so that going back walks them in reverse order; a request replaces the request shown
/// instead, so that going back from it returns to the view it was opened from.
@Observable
final class ServiceMapModel {
    let project: Project
    @ObservationIgnored private let store: any ServiceMapStore

    /// The name of the environment shown, one of the project's.
    var environment: String {
        didSet {
            guard environment != oldValue else { return }
            load()
        }
    }

    /// Not wired yet: every window shows the same sample map.
    var timeWindow: TimeWindow = .hour
    /// Not wired yet.
    var isLive = true

    /// What the graph shows: nil for the whole namespace, a service in focus, or a request.
    private(set) var scope: MapSelection?
    /// The views before this one, which going back returns to.
    private(set) var history: [MapSelection?] = []

    /// The map of the environment shown.
    private(set) var map: ServiceMap
    /// The requests of the map, in its order.
    private var rows: [RequestRow] = []
    /// The order of the requests table: newest first until the user sorts by a column.
    var sortOrder: [KeyPathComparator<RequestRow>] = [KeyPathComparator(\.startedAt, order: .reverse)]

    /// The service the project deploys, if any: shown on the whole namespace.
    let ownService: ServiceNode.ID?

    /// The map of `project` on `environment` (or the first that isn't healthy), with `focus` shown:
    /// `service:<name>` or `request:<id>`. A sub project opened without a focus shows its own service
    /// in focus, with the whole namespace behind it.
    init(project: Project, focus: String?, environment: String? = nil, store: any ServiceMapStore) {
        self.project = project
        self.store = store
        let named = environment.flatMap { name in project.deploymentEnvironments.first { $0.name == name } }
        let shown = (named ?? project.openingEnvironment)?.name ?? ""
        let map = store.map(environment: shown)
        let own = store.ownService(of: project.id)
        self.environment = shown
        self.map = map
        ownService = own
        rows = Self.rows(of: map)
        if focus == nil, project.parentID != nil, let own {
            scope = .service(own)
            history = [nil]
        } else {
            scope = MapSelection(focus: focus)
        }
    }

    private func load() {
        map = store.map(environment: environment)
        rows = Self.rows(of: map)
    }

    var currentEnvironment: DeploymentEnvironment? {
        project.deploymentEnvironments.first { $0.name == environment }
    }

    // MARK: Views of the graph

    /// Shows a route's focus: `service:<name>` or `request:<id>`, keeping the view shown to come
    /// back to. Any other focus goes to the whole namespace.
    func select(focus: String) {
        if let selection = MapSelection(focus: focus) {
            show(selection)
        } else {
            showAll()
        }
    }

    /// Goes to a view, keeping the one shown to come back to. A request replaces the request shown.
    func show(_ next: MapSelection) {
        guard next != scope else { return }
        if scope?.isRequest == true, next.isRequest {
            scope = next
            return
        }
        history.append(scope)
        scope = next
    }

    /// Whether there is a view to go back to: anything but the whole namespace.
    var canGoBack: Bool {
        scope != nil
    }

    /// Back to the view before: from a request to the view it was opened from, from a focus to the
    /// one before it, and to the whole namespace at last.
    func back() {
        scope = history.popLast() ?? nil
    }

    /// Straight to the whole namespace, forgetting the views before it.
    func showAll() {
        history = []
        scope = nil
    }

    /// A click on a node: a service goes into focus; any other node does nothing.
    func tap(_ node: ServiceNode) {
        if node.kind.isService {
            show(.service(node.id))
        }
    }

    /// The request shown, as the requests table selects it. Selecting a row shows its request;
    /// deselecting the row goes back.
    var requestSelection: ServiceRequest.ID? {
        get {
            if case .request(let id)? = scope { id } else { nil }
        }
        set {
            if let newValue {
                show(.request(newValue))
            } else if scope?.isRequest == true {
                back()
            }
        }
    }

    // MARK: What the window shows

    /// Whether the graph shows a request's path, whose arrows weigh durations rather than calls.
    var showsRequest: Bool {
        if case .request(let id)? = scope { map.request(id) != nil } else { false }
    }

    /// The nodes and arrows of the view shown. A focus or a request that isn't in the map shows the
    /// whole namespace, with the way back.
    var graphContent: GraphContent {
        switch scope {
        case .service(let id)?:
            guard map.node(id) != nil else { return wholeNamespace(focus: nil, isScoped: true) }
            // The service, the boxes it calls and the services that call it, with the arrows to and from it.
            let calls = map.calls(of: id)
            let kept = Set(calls.flatMap { [$0.from, $0.to] } + [id])
            return GraphContent(
                nodes: map.nodes.filter { kept.contains($0.id) }, arrows: calls.map(\.graphArrow),
                focusID: id, isScoped: true, showsAllLabels: true
            )
        case .request(let id)?:
            return requestContent(id) ?? wholeNamespace(focus: nil, isScoped: true)
        case nil:
            return wholeNamespace(focus: ownService.flatMap { map.node($0)?.id }, isScoped: false)
        }
    }

    private func wholeNamespace(focus: ServiceNode.ID?, isScoped: Bool) -> GraphContent {
        GraphContent(nodes: map.nodes, arrows: map.calls.map(\.graphArrow), focusID: focus, isScoped: isScoped, showsAllLabels: false)
    }

    /// Only what the request hit, from a Client node into its first service, its arrows weighing the
    /// calls' durations.
    private func requestContent(_ id: ServiceRequest.ID) -> GraphContent? {
        guard let request = map.request(id), let entry = request.spans.first else { return nil }
        var arrows = [GraphArrow(
            from: ServiceNode.client.id, to: entry.service, weight: Double(request.duration),
            label: ServiceMapFormat.duration(request.duration), spokenLabel: ServiceMapFormat.duration(request.duration, width: .wide)
        )]
        for (caller, span) in request.calledSpans where !arrows.contains(where: { $0.from == caller.service && $0.to == span.service }) {
            arrows.append(GraphArrow(
                from: caller.service, to: span.service, weight: Double(span.duration),
                label: ServiceMapFormat.duration(span.duration), spokenLabel: ServiceMapFormat.duration(span.duration, width: .wide)
            ))
        }
        let hit = Set(request.services)
        return GraphContent(
            nodes: [.client] + map.nodes.filter { hit.contains($0.id) },
            arrows: arrows, clientArrow: arrows.first?.id, clientRoute: ServiceMapFormat.route(of: request),
            isScoped: true, showsAllLabels: true
        )
    }

    /// What the details show.
    enum Inspected: Equatable {
        case service(ServiceNode)
        case request(ServiceRequest)
        /// A focus on a name the environment's map doesn't have.
        case missingService(ServiceNode.ID)
        /// A request id that isn't among the environment's recent requests.
        case missingRequest(ServiceRequest.ID)
        /// The whole namespace of a project without a service of its own.
        case nothing
    }

    /// The service in focus or the request shown; on the whole namespace, the project's own service.
    var inspected: Inspected {
        switch scope {
        case .service(let id)?: map.node(id).map(Inspected.service) ?? .missingService(id)
        case .request(let id)?: map.request(id).map(Inspected.request) ?? .missingRequest(id)
        case nil: ownService.flatMap(map.node).map(Inspected.service) ?? .nothing
        }
    }

    /// The service or request the details show, in the environment shown, for the chat panel beside
    /// the window. Nil when the details show neither.
    var chatSubject: ChatReference? {
        switch inspected {
        case .service(let node): ServiceMapReader.reference(.service(node.id), in: project, environment: environment)
        case .request(let request): ServiceMapReader.reference(.request(request.id), in: project, environment: environment)
        case .missingService, .missingRequest, .nothing: nil
        }
    }

    /// Whether `node` is the project's own service, whose details offer its contract.
    func isOwnService(_ node: ServiceNode.ID) -> Bool {
        node == ownService && project.tools.contains(.contracts)
    }

    func logs(ofService id: ServiceNode.ID) -> [LogLine] {
        map.logs.filter { $0.service == id }
    }

    func logs(ofRequest id: ServiceRequest.ID) -> [LogLine] {
        map.logs.filter { $0.requestID == id }
    }

    // MARK: Namespace summary

    /// The services of the namespace, without the databases, queues and external services they call.
    var serviceCount: Int {
        map.services.count
    }

    /// The services whose health isn't Healthy.
    var servicesNeedingAttention: Int {
        map.services.count { $0.health != .healthy }
    }

    // MARK: Requests

    /// The requests of the map in the table's order; ties keep the map's order.
    var requestRows: [RequestRow] {
        rows.sorted(using: sortOrder + [KeyPathComparator(\RequestRow.position)])
    }

    private static func rows(of map: ServiceMap) -> [RequestRow] {
        map.requests.enumerated().map { position, request in
            RequestRow(
                id: request.id, status: request.status, method: request.method, path: request.path,
                serviceCount: map.serviceCount(of: request), duration: request.duration, startedAt: request.startedAt,
                position: position
            )
        }
    }
}

/// A row of the requests table, with a value for each column to sort by. Nonisolated, so that the
/// table can sort it by key paths.
nonisolated struct RequestRow: Identifiable, Hashable, Sendable {
    let id: ServiceRequest.ID
    let status: Int
    let method: String
    let path: String
    /// The services the request went through, without databases, queues and external services.
    let serviceCount: Int
    /// In milliseconds.
    let duration: Int
    let startedAt: Date
    /// The request's place in the map's list, which breaks ties in any order.
    let position: Int
}
