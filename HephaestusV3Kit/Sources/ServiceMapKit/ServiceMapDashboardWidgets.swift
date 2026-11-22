import AZDesign
import Charts
import SwiftUI
import ToolsFoundation

// The Dashboard's widgets of the Service Map (docs/ui/dashboard.md): they read the map of the Dashboard's
// environment and count over the Dashboard's time window.

/// What a widget of the Service Map shows under its title row: the pods of the project's service, or
/// the whole graph, its busiest calls, its failed requests or its requests per minute.
public struct ServiceMapDashboardWidget: View {
    let widget: DashboardWidget
    let context: DashboardContext
    /// The store of previews and tests; nil reads the app's.
    private let fixedStore: (any ServiceMapStore)?
    @Environment(\.serviceMapStore) private var appStore

    public init(widget: DashboardWidget, context: DashboardContext) {
        self.init(widget: widget, context: context, store: nil)
    }

    init(widget: DashboardWidget, context: DashboardContext, store: (any ServiceMapStore)?) {
        self.widget = widget
        self.context = context
        fixedStore = store
    }

    private var store: any ServiceMapStore {
        fixedStore ?? appStore ?? SampleServiceMapStore()
    }

    public var body: some View {
        content
            // The map is read when the widget shows, then every 5 s while it does; another project starts again,
            // as the Projects overview shows one project after another in the same widget.
            .task(id: "\(context.project.id)|\(context.environment?.name ?? "")|\(context.window)") {
                guard let environment = context.environment else { return }
                while !Task.isCancelled {
                    await store.refresh(context.project, environment: environment.name, window: context.window)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let environment = context.environment {
            let reading = ServiceWidgetReading(map: store.map(of: context.project, environment: environment.name), window: context.window)
            switch widget.kind {
            case .instances:
                InstancesContent(
                    environment: environment,
                    pods: store.ownService(of: context.project, environment: environment.name).flatMap(reading.map.node).map { store.pods(of: $0, environment: environment) }
                )
            case .serviceGraph:
                ServiceGraphContent(
                    project: context.project, reading: reading, focusID: store.ownService(of: context.project, environment: environment.name), editing: context.editing,
                    status: store.status(of: context.project, environment: environment.name), environment: environment
                )
            case .busiestCalls:
                BusiestCallsContent(reading: reading, limit: rowLimit)
            case .failedRequests:
                FailedRequestsContent(project: context.project, requests: reading.failedRequests(limit: rowLimit), editing: context.editing)
            case .requestsPerMinute:
                RequestsPerMinuteContent(counts: reading.map.requestsPerMinute(in: context.window))
            case .project, .tickets, .recentBuilds, .recentChats, .cost:
                EmptyView()
            }
        } else {
            Text("This project has no environments.", bundle: #bundle)
                .foregroundStyle(.textSecondary)
        }
    }

    /// The `Number` setting within 1–20.
    private var rowLimit: Int {
        min(max(widget.count, DashboardWidget.countRange.lowerBound), DashboardWidget.countRange.upperBound)
    }
}

/// What the service widgets read from the map of the Dashboard's environment, over its time window.
struct ServiceWidgetReading {
    let map: ServiceMap
    let window: TimeWindow

    /// The whole graph's arrows as the Service Graph widget draws them: each coloured by, and labelled
    /// with, its calls in the window.
    var graphArrows: [GraphArrow] {
        map.calls.map { $0.windowArrow(window) }
    }

    /// The arrows with at least one call in the window, the busiest first, arrows with the same
    /// number in the graph's order; at most `limit`.
    func busiestCalls(limit: Int) -> [(call: ServiceCall, count: Int)] {
        let calls = map.calls.enumerated().compactMap { index, call -> (index: Int, call: ServiceCall, count: Int)? in
            let count = call.count(in: window)
            return count > 0 ? (index, call, count) : nil
        }
        return calls
            .sorted { ($1.count, $0.index) < ($0.count, $1.index) }
            .prefix(limit)
            .map { ($0.call, $0.count) }
    }

    /// The requests of the window answered 400 or above, the newest first; at most `limit`.
    func failedRequests(limit: Int) -> [ServiceRequest] {
        let start = SampleClock.date(minutes: -window.minutes)
        return Array(
            map.requests
                .filter { $0.failed && $0.startedAt >= start }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(limit)
        )
    }
}

// MARK: Instances

/// The pods of the project's service in the environment, in a table with the columns of
/// `kubectl get pods -o wide` (docs/ui/dashboard.md › Instances widget). A click on a row does nothing.
private struct InstancesContent: View {
    let environment: DeploymentEnvironment
    /// Nil when the environment has no deployment of the project's service.
    let pods: [Pod]?

    /// The column headers of `kubectl get pods -o wide`, in their order.
    private static var headers: [String] {
        [
            String(localized: "Name", bundle: #bundle, comment: "A column of the Instances widget: the pod's name"),
            String(localized: "Ready", bundle: #bundle, comment: "A column of the Instances widget: ready containers"),
            String(localized: "Status", bundle: #bundle, comment: "A column: a request's HTTP status, or a pod's kubectl status"),
            String(localized: "Restarts", bundle: #bundle, comment: "A column of the Instances widget"),
            String(localized: "Age", bundle: #bundle, comment: "A column of the Instances widget: the pod's age"),
            String(localized: "Node", bundle: #bundle, comment: "A column of the Instances widget: the cluster node"),
        ]
    }

    var body: some View {
        if let pods {
            table(pods)
        } else {
            Text("Environment “\(environment.name)” has no deployment.", bundle: #bundle)
                .foregroundStyle(.textSecondary)
        }
    }

    private func table(_ pods: [Pod]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Self.headers, id: \.self) { header in
                    Text(verbatim: header)
                }
            }
            .foregroundStyle(.textSecondary)
            .accessibilityHidden(true)
            ForEach(pods) { pod in
                GridRow {
                    // The row reads as one element, carried by its first cell: a grid row is no view
                    // of its own.
                    Text(verbatim: pod.name)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: pod.name))
                        .accessibilityValue(Self.spokenRow(of: pod))
                        .accessibilityIdentifier("dashboard.instance.\(pod.name)")
                    Group {
                        Text(verbatim: "\(pod.readyContainers)/\(pod.containers)")
                            .monospacedDigit()
                        HStack(spacing: 5) {
                            StatusDot(Self.color(of: pod))
                            Text(verbatim: pod.status)
                        }
                        Text(pod.restarts, format: .number)
                            .monospacedDigit()
                        Text(verbatim: pod.age)
                            .monospacedDigit()
                        Text(verbatim: pod.node ?? "")
                    }
                    .accessibilityHidden(true)
                }
                .foregroundStyle(.textPrimary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.instances")
    }

    /// A pod's row in words, after its name: "2 of 2 containers ready, Running, 1 restart, age 19h,
    /// on staging-eu-node-1".
    private static func spokenRow(of pod: Pod) -> String {
        // Data written as it is: the sentence is read as Markdown for its inflected counts.
        let status = ServiceMapFormat.literal(pod.status)
        let age = ServiceMapFormat.literal(pod.age)
        let ready = pod.readyContainers
        let containers = pod.containers
        let restarts = pod.restarts
        let sentence = if let node = pod.node.map(ServiceMapFormat.literal) {
            AttributedString(localized: "\(ready) of ^[\(containers) container](inflect: true) ready, \(status), ^[\(restarts) restart](inflect: true), age \(age), on \(node)", bundle: #bundle, comment: "A pod of the Instances widget, for VoiceOver, after its name")
        } else {
            AttributedString(localized: "\(ready) of ^[\(containers) container](inflect: true) ready, \(status), ^[\(restarts) restart](inflect: true), age \(age), not scheduled", bundle: #bundle, comment: "A pod of the Instances widget that is on no node, for VoiceOver, after its name")
        }
        return String(sentence.characters)
    }

    /// The STATUS texts of a pod that starts or stops; `Init:<n>/<m>` and `Running` with a container
    /// not ready are too.
    private static let changingStatuses: Set<String> = ["Pending", "ContainerCreating", "PodInitializing", "Terminating"]
    /// The STATUS texts of a pod that fails, also after `Init:`.
    private static let failedStatuses: Set<String> = [
        "Failed", "Error", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "OOMKilled", "Evicted",
    ]

    /// The dot: green for a pod running with every container ready, orange while it starts or stops,
    /// red when it fails, grey otherwise; here AZDesign's success, warning and danger.
    static func color(of pod: Pod) -> Color {
        let status = pod.status
        if status == "Running" {
            return pod.readyContainers == pod.containers ? .success : .warning
        }
        if changingStatuses.contains(status) || isInitProgress(status) {
            return .warning
        }
        if failedStatuses.contains(status) || (status.hasPrefix("Init:") && failedStatuses.contains(String(status.dropFirst(5)))) {
            return .danger
        }
        return .textSecondary
    }

    /// `Init:<n>/<m>`, the init containers still running.
    private static func isInitProgress(_ status: String) -> Bool {
        guard status.hasPrefix("Init:") else { return false }
        let parts = status.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

// MARK: Service graph

/// The layouts of the graphs the Dashboards show, by their nodes and arrows: a layout is worked out
/// once, not each time a widget is drawn.
enum DashboardGraphLayouts {
    private static var layouts: [[String]: GraphLayout] = [:]

    static func layout(nodes: [ServiceNode], arrows: [GraphArrow]) -> GraphLayout {
        let key = nodes.map(\.id) + ["|"] + arrows.map(\.id)
        if let layout = layouts[key] {
            return layout
        }
        let layout = GraphLayout(nodes: nodes, arrows: arrows)
        layouts[key] = layout
        return layout
    }
}

/// The whole graph, laid out as the Service Map lays it out and fitted to the widget at 150% at most;
/// it cannot be zoomed or panned. Its arrows count the calls of the Dashboard's time window, as the
/// did. A click opens the Service Map.
private struct ServiceGraphContent: View {
    let project: Project
    let reading: ServiceWidgetReading
    /// The project's own service, with the accent border.
    let focusID: ServiceNode.ID?
    let editing: Bool
    /// How the map's last read went, said in place of an empty map.
    let status: MapStatus
    let environment: DeploymentEnvironment

    /// The height the map counts for the rows of a widget without position and of an added widget;
    /// the map itself fills its widget.
    static let mapHeight: CGFloat = 260

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if reading.map.nodes.isEmpty {
            empty
        } else {
            map
        }
    }

    /// Why there is no map yet: reading it, kubectl's message, or a namespace without services.
    @ViewBuilder private var empty: some View {
        Group {
            switch status {
            case .reading, .none:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the map of \(environment.name)…", bundle: #bundle)
                }
                .foregroundStyle(.textSecondary)
            case .failed(let message):
                Text(verbatim: message)
                    .foregroundStyle(.danger)
                    .lineLimit(4)
            case .read:
                Text("No services in \(environment.namespace ?? environment.name).", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("dashboard.serviceGraph.empty")
    }

    @ViewBuilder private var map: some View {
        let nodes = reading.map.nodes
        let arrows = reading.graphArrows
        let layout = DashboardGraphLayouts.layout(nodes: nodes, arrows: arrows)
        Button {
            guard !editing else { return }
            openRoute(.tool(.serviceMap, project: project.id))
        } label: {
            GeometryReader { geometry in
                if let fit = GraphGeometry.fit(layout, nodes: nodes, in: geometry.size) {
                    GraphMapView(
                        model: GraphMapModel(
                            nodes: nodes, arrows: arrows, layout: layout,
                            focusID: focusID.flatMap { reading.map.node($0)?.id }, showsAllLabels: false
                        ),
                        scale: fit.scale, offset: fit.offset
                    )
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, idealHeight: Self.mapHeight, maxHeight: .infinity, alignment: .topLeading)
        .help(String(localized: "Open the Service Map", bundle: #bundle))
        .accessibilityLabel(String(localized: "Open the Service Map", bundle: #bundle))
        .accessibilityIdentifier("dashboard.serviceGraph")
    }
}

// MARK: Busiest calls

/// The arrows that have at least one call in the window, the busiest first, arrows with the same
/// number by their order in the graph: `<from> → <to>`, the kind of the target after it when it is not
/// a service, and the number of calls in the colour of the arrow.
private struct BusiestCallsContent: View {
    let reading: ServiceWidgetReading
    let limit: Int

    var body: some View {
        let rows = reading.busiestCalls(limit: limit)
        let heaviest = reading.map.calls.map(\.requestsPerSecond).max() ?? 0
        if rows.isEmpty {
            Text("No calls in the window.", bundle: #bundle)
                .foregroundStyle(.textSecondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.call.id) { row in
                    let kind = reading.map.node(row.call.to).flatMap { $0.kind.isService ? nil : $0.kind }
                    GridRow {
                        // The row reads as one element, carried by its first cell: a grid row is no
                        // view of its own.
                        label(of: row.call, kind: kind)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel(spokenLabel(of: row.call, kind: kind))
                            .accessibilityValue(ServiceMapFormat.spokenCalls(row.count))
                            .accessibilityIdentifier("dashboard.busiestCall.\(row.call.from).\(row.call.to)")
                        Text(row.count, format: .number.notation(.compactName))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(GraphColorScale.color(weight: row.call.requestsPerSecond, busiest: heaviest))
                            // The number is never truncated or wrapped: a narrower widget scrolls it.
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard.busiestCalls")
        }
    }

    /// `orders-api → orders-db Database`: the call in one localized string, the target's kind in the
    /// secondary color when it is not a service.
    private func label(of call: ServiceCall, kind: ServiceNode.Kind?) -> Text {
        let from = call.from
        let to = call.to
        guard let kind else {
            return Text("\(from) → \(to)", bundle: #bundle, comment: "A row of the Busiest Calls widget: the caller, then the service called")
                .foregroundStyle(.textPrimary)
        }
        let kindText = Text(verbatim: kind.title)
            .foregroundStyle(.textSecondary)
        return Text("\(from) → \(to) \(kindText)", bundle: #bundle, comment: "A row of the Busiest Calls widget: the caller, the node called, then its kind (Database, Queue, External)")
            .foregroundStyle(.textPrimary)
    }

    /// "orders-api to orders-db, Database", for VoiceOver.
    private func spokenLabel(of call: ServiceCall, kind: ServiceNode.Kind?) -> String {
        let from = call.from
        let to = call.to
        guard let kind else {
            return String(localized: "\(from) to \(to)", bundle: #bundle, comment: "An arrow of the graph, for VoiceOver: the node that calls, then the node called")
        }
        return String(localized: "\(from) to \(to), \(kind.title)", bundle: #bundle, comment: "A call, for VoiceOver: the caller, the node called and its kind")
    }
}

// MARK: Failed requests

/// The newest requests of the window answered 400 or above: each with its id, its first service and
/// route, its status and its start time. A click opens the Service Map with the view of that request.
private struct FailedRequestsContent: View {
    let project: Project
    let requests: [ServiceRequest]
    let editing: Bool

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if requests.isEmpty {
            Text("No failed requests in the window.", bundle: #bundle)
                .foregroundStyle(.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(requests) { request in
                    Button {
                        guard !editing else { return }
                        openRoute(.tool(.serviceMap, project: project.id, focus: MapSelection.request(request.id).focus))
                    } label: {
                        HStack(spacing: 10) {
                            // The map's ids are short.
                            Text(verbatim: request.id)
                                .monospaced()
                                .fixedSize()
                            Text("\(request.services.first ?? "") \(request.method) \(request.path)", bundle: #bundle, comment: "A row of the Failed Requests widget: the request's first service, then its method and path")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            // The status and the start time are never truncated or wrapped: a
                            // narrower widget scrolls them.
                            Text(verbatim: String(request.status))
                                .monospacedDigit()
                                .foregroundStyle(request.statusColor)
                                .fixedSize()
                            Text(request.startedAt, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.textSecondary)
                                .fixedSize()
                        }
                        .font(.callout)
                        .foregroundStyle(.textPrimary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open the request in the Service Map", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.failedRequest.\(request.id)")
                }
            }
        }
    }
}

// MARK: Requests per minute

/// The requests of the last minute in a large font with its caption and, filling the widget under
/// them, a line chart of the window, one point a minute, its vertical axis starting at 0.
private struct RequestsPerMinuteContent: View {
    /// The requests of each minute of the window, the oldest first.
    let counts: [Int]

    /// The height the chart counts for the rows of a widget without position and of an added widget.
    static let chartHeight: CGFloat = 120
    /// The room under the chart for the lower half of the label of its axis at 0.
    static let chartLabelRoom: CGFloat = 6

    var body: some View {
        let points = counts.enumerated().map { MinutePoint(minute: $0.offset - counts.count + 1, count: $0.element) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(counts.last ?? 0, format: .number)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.textPrimary)
                    // The number is never truncated or wrapped: a narrower widget scrolls it.
                    .fixedSize()
                Text("in the last minute", bundle: #bundle, comment: "Under the Requests per Minute widget's number: the requests of the last minute")
                    .foregroundStyle(.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dashboard.requestsPerMinute.lastMinute")
            Chart(points) { point in
                LineMark(
                    x: .value(String(localized: "Minute", bundle: #bundle), point.minute),
                    y: .value(String(localized: "Requests", bundle: #bundle, comment: "Requests: the caption of a service's requests per second, or a chart's axis"), point.count)
                )
                .foregroundStyle(.accent)
            }
            .chartYScale(domain: 0...max(1, counts.max() ?? 1))
            .chartXAxis(.hidden)
            // The label of the axis at 0 is drawn half under the chart: it stays inside the content,
            // which is cut at its edge.
            .padding(.bottom, Self.chartLabelRoom)
            .frame(minHeight: 0, idealHeight: Self.chartHeight, maxHeight: .infinity)
            .accessibilityLabel(String(localized: "Requests per minute over the window", bundle: #bundle))
            .accessibilityIdentifier("dashboard.requestsPerMinute.chart")
        }
    }
}

/// A minute of the Requests per Minute chart: 0 for the last one, negative before.
private struct MinutePoint: Identifiable {
    var minute: Int
    var count: Int
    var id: Int { minute }
}

// MARK: - Previews

/// A service widget of Orders in Staging over the last hour, in a card of the size the Dashboard gives it.
private func previewWidget(_ kind: DashboardWidgetKind, project: Project.ID = "ORD", environment: String? = "Staging", window: TimeWindow = .hour, count: Int = 5) -> some View {
    let project = Project.sample(project) ?? Project.samples[0]
    let context = DashboardContext(
        project: project, environment: project.deploymentEnvironments.first { $0.name == environment }, window: window, editing: false
    )
    return ServiceMapDashboardWidget(widget: DashboardWidget(kind: kind, count: count), context: context, store: SampleServiceMapStore())
        .padding(16)
        .frame(width: 520, height: 300, alignment: .topLeading)
        .background(.surface)
}

#Preview("Service Graph", traits: .appChrome) {
    previewWidget(.serviceGraph)
}

#Preview("Service Graph, 24 Hours, Dark", traits: .appChrome) {
    previewWidget(.serviceGraph, window: .day)
        .preferredColorScheme(.dark)
}

#Preview("Busiest Calls", traits: .appChrome) {
    previewWidget(.busiestCalls, count: 8)
}

#Preview("Failed Requests", traits: .appChrome) {
    previewWidget(.failedRequests)
}

#Preview("No Failed Requests", traits: .appChrome) {
    previewWidget(.failedRequests, environment: "Production", window: .fiveMinutes)
}

#Preview("Requests per Minute", traits: .appChrome) {
    previewWidget(.requestsPerMinute)
}

#Preview("Instances", traits: .appChrome) {
    previewWidget(.instances, project: "PAY")
}

#Preview("Instances, Largest Text", traits: .largestText) {
    previewWidget(.instances, project: "PAY")
}

#Preview("No Deployment", traits: .appChrome) {
    previewWidget(.instances, project: "SHOP")
}

#Preview("No Environments", traits: .appChrome) {
    previewWidget(.busiestCalls, project: "TLS", environment: nil)
}
