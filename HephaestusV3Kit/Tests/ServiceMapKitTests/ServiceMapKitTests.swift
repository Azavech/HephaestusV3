import ClusterData
import Foundation
import Testing
import ToolsFoundation
@testable import ServiceMapKit

// MARK: - Mock store

/// A small namespace: a gateway, a degraded service, a worker, a database and an external service.
/// Production adds a service of its own, `extra`.
final class MockServiceMapStore: ServiceMapStore {
    func map(of project: Project, environment: String) -> ServiceMap { map(environment: environment) }
    func status(of project: Project, environment: String) -> MapStatus { .none }
    func refresh(_ project: Project, environment: String, window: TimeWindow) async {}
    func ownService(of project: Project, environment: String) -> ServiceNode.ID? { ownService(of: project.id) }
    var acts: Bool { false }
    func restart(_ project: Project, environment: String) async throws(MapActionError) -> String { "" }
    func scale(_ project: Project, environment: String, to replicas: Int) async throws(MapActionError) -> String { "" }
    func argoCD(_ project: Project, environment: String) async throws(MapActionError) -> ArgoCDStatus { throw MapActionError(message: "") }
    func sync(_ project: Project, environment: String) async throws(MapActionError) -> String { "" }

    func map(environment: String) -> ServiceMap {
        let production = environment == "Production"
        func node(
            _ id: String, _ kind: ServiceNode.Kind, p95: Int = 20, errors: Double = 0,
            ready: Int = 2, pods: Int = 2, health: DeploymentEnvironment.Health = .healthy
        ) -> ServiceNode {
            ServiceNode(
                id: id, kind: kind, requestsPerSecond: 10, p95: p95, errorRate: errors,
                readyPods: ready, pods: pods, health: health, throughput: []
            )
        }
        let nodes = [
            node("gw", .gateway),
            node("api", .service, p95: 2_400, errors: 0.05, ready: 1, health: production ? .healthy : .degraded),
            node("worker", .worker),
            node("db", .database, ready: 1, pods: 1),
            node("ext", .external, ready: 0, pods: 0, health: .degraded),
        ] + (production ? [node("extra", .service)] : [])
        let calls = [
            ServiceCall(from: "gw", to: "api", requestsPerSecond: 100, errorRate: 0.05),
            ServiceCall(from: "api", to: "db", requestsPerSecond: 50, errorRate: 0),
            ServiceCall(from: "api", to: "ext", requestsPerSecond: 10, errorRate: 0.02),
            ServiceCall(from: "worker", to: "db", requestsPerSecond: 50, errorRate: 0),
        ] + (production ? [ServiceCall(from: "gw", to: "extra", requestsPerSecond: 20, errorRate: 0)] : [])
        let requests = [
            ServiceRequest(
                id: "r1", method: "POST", path: "/orders/_draft_/*x*", status: 504, duration: 3_000,
                startedAt: SampleClock.date(minutes: -2),
                spans: [
                    Span(id: 1, service: "gw", operation: "POST /orders", start: 0, duration: 3_000, isError: true),
                    Span(id: 2, service: "api", operation: "checkout", start: 5, duration: 2_990, isError: true),
                    Span(id: 3, service: "db", operation: "SELECT", start: 10, duration: 5, isError: false),
                    Span(id: 4, service: "ext", operation: "charge", start: 20, duration: 2_900, isError: true),
                ]
            ),
            ServiceRequest(
                id: "r2", method: "GET", path: "/orders", status: 200, duration: 50, startedAt: SampleClock.date(minutes: -1),
                spans: [
                    Span(id: 1, service: "gw", operation: "GET /orders", start: 0, duration: 50, isError: false),
                    Span(id: 2, service: "api", operation: "list", start: 2, duration: 45, isError: false),
                ]
            ),
            ServiceRequest(
                id: "r3", method: "GET", path: "/missing", status: 404, duration: 20, startedAt: SampleClock.date(minutes: -10),
                spans: [Span(id: 1, service: "gw", operation: "GET /missing", start: 0, duration: 20, isError: false)]
            ),
        ]
        let logs = [
            LogLine(id: 1, date: SampleClock.date(minutes: -2), service: "api", level: .error, message: "timeout", requestID: "r1"),
            LogLine(id: 2, date: SampleClock.date(minutes: -5), service: "worker", level: .info, message: "idle", requestID: nil),
        ]
        return ServiceMap(nodes: nodes, calls: calls, requests: requests, logs: logs)
    }

    func ownService(of project: Project.ID) -> ServiceNode.ID? {
        project == "SUB" ? "api" : nil
    }

    func pods(of service: ServiceNode, environment: DeploymentEnvironment) -> [Pod] {
        []
    }
}

private let environments = [
    DeploymentEnvironment(name: "Local", cluster: "local", namespace: "ns", url: "http://localhost", health: .healthy),
    DeploymentEnvironment(name: "Staging", cluster: "staging", namespace: "ns", url: "https://staging", health: .degraded),
    DeploymentEnvironment(name: "Production", cluster: "prod", namespace: "ns", url: "https://prod", health: .healthy),
]

private let activity = ProjectActivity(
    openTickets: 0, ticketsInReview: 0, draftTickets: 0, lastBuild: .passed, lastBuildAt: SampleClock.date(),
    contractVersion: "1.0.0", operationCount: 1, serviceCount: 3
)

/// A top-level project without a service of its own.
private let top = Project(
    id: "TOP", name: "Top", kind: .service, tint: .accent, symbol: "storefront", path: "~/top", repository: "top",
    environments: environments, activity: activity
)

/// A sub project whose own service is `api`.
private let sub = Project(
    id: "SUB", name: "Sub", kind: .service, tint: .accent, symbol: "cart", path: "~/top/sub", repository: "sub",
    environments: environments, activity: activity, parentID: "TOP"
)

private func makeModel(_ project: Project = top, focus: String? = nil, environment: String? = nil) -> ServiceMapModel {
    ServiceMapModel(project: project, focus: focus, environment: environment, store: MockServiceMapStore())
}

// MARK: - Focus

@Suite("Focus formats")
struct FocusTests {
    @Test("A service focus and a request focus")
    func parsesFocus() {
        #expect(MapSelection(focus: "service:api") == .service("api"))
        #expect(MapSelection(focus: "request:r1") == .request("r1"))
        #expect(MapSelection(focus: "request:r1")?.focus == "request:r1")
    }

    @Test("Anything else is no focus", arguments: [nil, "", "api", "service:", "build:12", "service"])
    func rejectsOtherFocus(_ focus: String?) {
        #expect(MapSelection(focus: focus) == nil)
    }
}

// MARK: - Model

@Suite("Service Map model")
struct ServiceMapModelTests {
    @Test("The first environment that isn't healthy opens")
    func opensOnTheFirstEnvironmentNeedingAttention() {
        #expect(makeModel().environment == "Staging")
        #expect(makeModel(environment: "Production").environment == "Production")
        #expect(makeModel(environment: "Mars").environment == "Staging")
    }

    @Test("A sub project opens on its own service, with the whole namespace behind it")
    func subProjectOpensOnItsOwnService() {
        let model = makeModel(sub)
        #expect(model.scope == .service("api"))
        #expect(model.canGoBack)
        model.back()
        #expect(model.scope == nil)
        #expect(!model.canGoBack)
        #expect(model.inspected == .service(model.map.node("api")!))
    }

    @Test("A top-level project opens on the whole namespace, with nothing selected")
    func topLevelOpensOnTheWholeNamespace() {
        let model = makeModel()
        #expect(model.scope == nil)
        #expect(model.inspected == .nothing)
        #expect(model.chatSubject == nil)
        #expect(model.graphContent.focusID == nil)
        #expect(!model.graphContent.isScoped)
    }

    @Test("A focus opens its view")
    func opensOnTheFocus() {
        let model = makeModel(sub, focus: "request:r1")
        #expect(model.scope == .request("r1"))
        #expect(model.requestSelection == "r1")
        #expect(model.showsRequest)
        #expect(model.history.isEmpty)
    }

    @Test("Going back walks the views in reverse order")
    func backWalksTheViews() {
        let model = makeModel()
        model.tap(model.map.node("gw")!)
        model.tap(model.map.node("api")!)
        #expect(model.scope == .service("api"))
        model.back()
        #expect(model.scope == .service("gw"))
        model.back()
        #expect(model.scope == nil)
        model.back()
        #expect(model.scope == nil)
    }

    @Test("Another request replaces the request shown: back returns to the view it was opened from")
    func anotherRequestReplacesTheRequestShown() {
        let model = makeModel(sub)
        model.requestSelection = "r1"
        model.requestSelection = "r2"
        model.select(focus: "request:r3")
        #expect(model.scope == .request("r3"))
        model.back()
        #expect(model.scope == .service("api"))
        model.back()
        #expect(model.scope == nil)
    }

    @Test("Deselecting the request goes back")
    func deselectingGoesBack() {
        let model = makeModel()
        model.tap(model.map.node("api")!)
        model.requestSelection = "r2"
        model.requestSelection = nil
        #expect(model.scope == .service("api"))
        // Deselecting with no request shown changes nothing.
        model.requestSelection = nil
        #expect(model.scope == .service("api"))
    }

    @Test("Show All forgets the views before it")
    func showAllForgetsTheHistory() {
        let model = makeModel(sub)
        model.requestSelection = "r1"
        model.showAll()
        #expect(model.scope == nil)
        #expect(model.history.isEmpty)
        #expect(model.inspected == .service(model.map.node("api")!))
    }

    @Test("A click on a database, an external service or the Client does nothing", arguments: ["db", "ext"])
    func tapOnOtherNodesDoesNothing(_ id: String) {
        let model = makeModel()
        model.tap(model.map.node(id)!)
        model.tap(.client)
        #expect(model.scope == nil)
    }

    @Test("A route selects its focus again after the user picked another")
    func routeSelectsAgain() {
        let model = makeModel()
        model.select(focus: "service:api")
        model.tap(model.map.node("gw")!)
        model.select(focus: "service:api")
        #expect(model.scope == .service("api"))
        model.back()
        #expect(model.scope == .service("gw"))
    }

    @Test("A route without a known focus format goes to the whole namespace")
    func unknownFocusShowsAll() {
        let model = makeModel(sub)
        model.select(focus: "operation:createOrder")
        #expect(model.scope == nil)
        #expect(model.history.isEmpty)
    }

    @Test("A service that isn't in the environment shows the whole namespace and says so")
    func missingService() {
        let model = makeModel(focus: "service:extra")
        #expect(model.inspected == .missingService("extra"))
        #expect(model.graphContent.nodes.map(\.id) == model.map.nodes.map(\.id))
        #expect(model.graphContent.isScoped)
        #expect(!model.graphContent.showsAllLabels)
        #expect(model.graphContent.focusID == nil)
        #expect(model.chatSubject == nil)
        model.environment = "Production"
        #expect(model.inspected == .service(model.map.node("extra")!))
        #expect(model.graphContent.focusID == "extra")
    }

    @Test("An unknown request shows the whole namespace and says so")
    func missingRequest() {
        let model = makeModel(focus: "request:nope")
        #expect(model.inspected == .missingRequest("nope"))
        #expect(!model.showsRequest)
        #expect(model.graphContent.isScoped)
        model.showAll()
        #expect(model.inspected == .nothing)
    }

    @Test("The chat subject is what the details show, in the environment shown")
    func chatSubject() {
        let model = makeModel(sub)
        model.showAll()
        #expect(model.chatSubject == ChatReference(tool: .serviceMap, projectID: "SUB", focus: "service:api", title: "api", environment: "Staging"))
        model.environment = "Production"
        #expect(model.chatSubject?.environment == "Production")
        model.requestSelection = "r1"
        #expect(model.chatSubject == ChatReference(tool: .serviceMap, projectID: "SUB", focus: "request:r1", title: "r1", environment: "Production"))
    }

    @Test("The summary counts services only")
    func summaryCountsServicesOnly() {
        let staging = makeModel()
        #expect(staging.serviceCount == 3)
        // `ext` is degraded too, but it isn't a service.
        #expect(staging.servicesNeedingAttention == 1)
        let production = makeModel(environment: "Production")
        #expect(production.serviceCount == 4)
        #expect(production.servicesNeedingAttention == 0)
    }

    @Test("Requests are newest first, and count the services they went through")
    func requestRows() {
        let model = makeModel()
        #expect(model.requestRows.map(\.id) == ["r2", "r1", "r3"])
        // gw and api; not the database or the external service.
        #expect(model.requestRows.first { $0.id == "r1" }?.serviceCount == 2)
    }

    @Test("Requests sort by any column, ties in the map's order")
    func sortsRequests() {
        let model = makeModel()
        model.sortOrder = [KeyPathComparator(\.duration, order: .reverse)]
        #expect(model.requestRows.map(\.id) == ["r1", "r2", "r3"])
        model.sortOrder = [KeyPathComparator(\.method)]
        #expect(model.requestRows.map(\.id) == ["r2", "r3", "r1"])
        model.sortOrder = [KeyPathComparator(\.serviceCount)]
        #expect(model.requestRows.map(\.id) == ["r3", "r1", "r2"])
    }

    @Test("A focus shows the service, what it calls and what calls it")
    func focusContent() {
        let model = makeModel()
        model.show(.service("api"))
        let content = model.graphContent
        #expect(Set(content.nodes.map(\.id)) == ["gw", "api", "db", "ext"])
        #expect(content.arrows.map(\.id) == ["gw→api", "api→db", "api→ext"])
        #expect(content.focusID == "api")
        #expect(content.showsAllLabels)
        #expect(content.arrows.first?.label == ServiceMapFormat.rate(100))
    }

    @Test("A request's view starts at the Client, its arrows weighing durations")
    func requestContent() {
        let model = makeModel(focus: "request:r1")
        let content = model.graphContent
        #expect(content.nodes.first == ServiceNode.client)
        #expect(content.arrows.map(\.id) == ["client→gw", "gw→api", "api→db", "api→ext"])
        #expect(content.clientArrow == "client→gw")
        #expect(content.arrows.first?.label == ServiceMapFormat.duration(3_000))
        #expect(content.arrows.first?.weight == 3_000)
        #expect(content.clientRoute?.contains("/orders/_draft_/*x*") == true)
    }

    @Test("Only the project's own service offers its contract")
    func ownServiceOffersItsContract() {
        let model = makeModel(sub)
        #expect(model.isOwnService("api"))
        #expect(!model.isOwnService("gw"))
    }

    @Test("Logs of a service and of a request")
    func logs() {
        let model = makeModel()
        #expect(model.logs(ofService: "api").map(\.id) == [1])
        #expect(model.logs(ofRequest: "r1").map(\.id) == [1])
        #expect(model.logs(ofRequest: "r2").isEmpty)
    }
}

// MARK: - Reader

@Suite("Service Map reader")
struct ServiceMapReaderTests {
    private func read(_ focus: String, environment: String? = nil) -> ToolReading? {
        ServiceMapReader.read(focus, environment: environment, project: sub, store: MockServiceMapStore())
    }

    @Test("It reads the environment the user has on screen")
    func readsTheEnvironmentShown() throws {
        let production = try #require(read("service:extra", environment: "Production"))
        #expect(production.detail.contains("Production"))
        #expect(production.detail.contains("extra"))
        // Staging has no `extra`.
        #expect(read("service:extra", environment: "Staging") == nil)
        // Without an environment, or with an unknown one, the first that isn't healthy.
        #expect(read("service:api")?.detail.contains("Staging") == true)
        #expect(read("service:api", environment: "Mars")?.detail.contains("Staging") == true)
    }

    @Test("Unknown items and focus formats read nothing")
    func readsNothingUnknown() {
        #expect(read("service:nope") == nil)
        #expect(read("request:nope") == nil)
        #expect(read("api") == nil)
    }

    @Test("A request's detail counts its services only and keeps its path as it is")
    func requestDetail() throws {
        let reading = try #require(read("request:r1"))
        #expect(reading.detail.contains("/orders/_draft_/*x*"))
        #expect(reading.detail.contains("504"))
        #expect(reading.detail.contains("2 services"))
        #expect(reading.detail.contains(ServiceMapFormat.duration(3_000)))
    }

    @Test("A service's detail says its health, latency, errors and pods")
    func serviceDetail() throws {
        let reading = try #require(read("service:api"))
        #expect(reading.detail.contains("degraded"))
        #expect(reading.detail.contains(ServiceMapFormat.duration(2_400)))
        #expect(reading.detail.contains(ServiceMapFormat.percent(0.05)))
        #expect(reading.detail.contains("1 of 2 pods"))
        // An external service has no pods.
        let external = try #require(read("service:ext"))
        #expect(!external.detail.contains("pod"))
    }

    @Test("Suggestions follow the service's state")
    func serviceSuggestions() throws {
        let degraded = try #require(read("service:api"))
        #expect(degraded.suggestions.count == 3)
        #expect(degraded.suggestions.first?.contains("degraded") == true)
        let healthy = try #require(read("service:gw"))
        #expect(healthy.suggestions.count == 2)
        #expect(healthy.suggestions.allSatisfy { $0.contains("gw") })
        // A database calls nothing.
        let database = try #require(read("service:db"))
        #expect(database.suggestions.count == 1)
    }

    @Test("Suggestions follow the request's state")
    func requestSuggestions() throws {
        let failedAndSlow = try #require(read("request:r1"))
        #expect(failedAndSlow.suggestions.count == 3)
        #expect(failedAndSlow.suggestions[0].contains("fail"))
        #expect(failedAndSlow.suggestions[1].contains("slow"))
        let fine = try #require(read("request:r2"))
        #expect(fine.suggestions.count == 1)
        let failedFast = try #require(read("request:r3"))
        #expect(failedFast.suggestions.count == 2)
    }

    @Test("The reference names the item and the environment")
    func reference() {
        let reference = ServiceMapReader.reference(.request("r1"), in: sub, environment: "Production")
        #expect(reference.focus == "request:r1")
        #expect(reference.title == "r1")
        #expect(reference.environment == "Production")
        #expect(reference.route == .tool(.serviceMap, project: "SUB", focus: "request:r1"))
    }
}

// MARK: - Dashboard widgets

@Suite("Service widgets")
struct ServiceWidgetTests {
    private func reading(_ window: TimeWindow, environment: String = "Staging") -> ServiceWidgetReading {
        ServiceWidgetReading(map: MockServiceMapStore().map(environment: environment), window: window)
    }

    @Test("Busiest Calls: the most calls first, ties in the graph's order, at most Number")
    func busiestCalls() {
        let rows = reading(.hour).busiestCalls(limit: 3)
        #expect(rows.map(\.call.id) == ["gw→api", "api→db", "worker→db"])
        #expect(rows.first?.count == 100 * 3_600)
        #expect(reading(.fiveMinutes).busiestCalls(limit: 1).first?.count == 100 * 300)
    }

    @Test("Failed Requests: the window's requests from 400, newest first")
    func failedRequests() {
        #expect(reading(.hour).failedRequests(limit: 5).map(\.id) == ["r1", "r3"])
        #expect(reading(.fiveMinutes).failedRequests(limit: 5).map(\.id) == ["r1"])
        #expect(reading(.hour).failedRequests(limit: 1).map(\.id) == ["r1"])
    }

    @Test("Service Graph: its arrows count the calls of the time window")
    func graphReadsTheWindow() {
        let hour = reading(.hour).graphArrows
        let day = reading(.day).graphArrows
        #expect(hour.map(\.id) == day.map(\.id))
        #expect(hour.first?.weight == Double(100 * 3_600))
        #expect(day.first?.weight == Double(100 * 86_400))
        #expect(hour.first?.label == ServiceMapFormat.compactCount(360_000))
        #expect(hour.first?.label != day.first?.label)
    }
}

// MARK: - Formats and layout

@Suite("Formats")
struct FormatTests {
    @Test("Durations: milliseconds below one second, seconds from one second")
    func durations() {
        let milliseconds = Measurement(value: 84, unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated, usage: .asProvided))
        #expect(ServiceMapFormat.duration(84) == milliseconds)
        let seconds = Measurement(value: 4.2, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        #expect(ServiceMapFormat.duration(4_210) == seconds)
    }

    @Test("Data stays as it is inside an inflected string")
    func literal() {
        let path = "/orders/*x*?a=_b_&c=[d](e)"
        let sentence = AttributedString(localized: "\(ServiceMapFormat.literal(path)) went through ^[\(2) service](inflect: true)")
        #expect(String(sentence.characters) == "\(path) went through 2 services")
    }

    @Test("The layout is the same for the same nodes and arrows")
    func stableLayout() {
        let map = MockServiceMapStore().map(environment: "Staging")
        let arrows = map.calls.map(\.graphArrow)
        let first = GraphLayout(nodes: map.nodes, arrows: arrows)
        let second = GraphLayout(nodes: map.nodes, arrows: arrows)
        #expect(first == second)
        // The database and the external service sit on the ring of the first service that calls them.
        #expect(first.rings["db"] == "api")
        #expect(first.rings["ext"] == "api")
    }
}
