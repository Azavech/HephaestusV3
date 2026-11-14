import AZDesign
import SwiftUI
import ToolsFoundation

/// The Service Map window for one project: the services of its namespace and how they call each
/// other, the recent requests under them, and an inspector for a service or a request.
///
/// The graph is V2's, after AWS X-Ray's service map: round nodes placed by their calls, databases and
/// queues on a ring around their service, groups of services apart. A click on a service focuses on it
/// and its neighbours, a request shows only its path from a Client node, and a right-click, the Back
/// button or ⌘[ goes back. `ServiceMapModel` holds what the window shows.
public struct ServiceMapRootView: View {
    @State private var model: ServiceMapModel

    @Environment(\.openRoute) private var openRoute
    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.windowLayout) private var layout
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// A short window: the graph and the requests share less height.
    private var isShort: Bool { verticalSizeClass == .compact }
    /// In an iPhone's layout, whether the details show as a page over the map.
    @State private var showsDetailsPage = false
    /// The width of the requests' strip under the map, which picks the table or the two-line list.
    @State private var requestsWidth: CGFloat = .infinity
    /// The table needs this much for its fixed columns and a readable Path; narrower, as in most of an
    /// iPad's widths beside the details, the requests become the two-line list.
    private static let requestsTableWidth: CGFloat = 600

    /// The map of `project`, with `focus` selected: `service:<name>` or `request:<id>`.
    public init(project: Project, focus: String? = nil) {
        self.init(model: ServiceMapModel(project: project, focus: focus, store: SampleServiceMapStore()))
    }

    init(model: ServiceMapModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if model.project.deploymentEnvironments.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Environments", bundle: #bundle), systemImage: ToolKind.serviceMap.symbol)
                } description: {
                    Text("A service map shows a project that runs in a cluster.", bundle: #bundle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityIdentifier("serviceMap.noEnvironments")
            } else if layout == .phone {
                // An iPhone's: the map over its requests, and the details as a page with Back.
                NavigationStack {
                    mapAndRequests
                        .navigationDestination(isPresented: $showsDetailsPage) {
                            inspector
                        }
                }
            } else {
                mapAndRequests
                    // The details of the service or request are always open beside the map.
                    .inspector(isPresented: .constant(true)) {
                        inspector
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                    }
            }
        }
        // The chat panel beside the window asks about the service or the request the details show,
        // in the environment shown.
        .onChange(of: model.chatSubject, initial: true) { _, subject in
            reportChatSubject(subject)
        }
        // A later route to this window shows its focus without starting the map afresh.
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        .toolbar {
            if !model.project.deploymentEnvironments.isEmpty {
                switch layout {
                case .mac:
                    ToolbarItemGroup(placement: .primaryAction) {
                        environmentMenu
                        timeWindowPicker
                            .pickerStyle(.segmented)
                        liveToggle
                    }
                case .pad:
                    // Less room: the time window as a menu.
                    ToolbarItemGroup(placement: .primaryAction) {
                        environmentMenu
                        timeWindowPicker
                            .pickerStyle(.menu)
                        liveToggle
                    }
                case .phone:
                    // An iPhone's: the map's settings in one menu, and the details' page.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu(String(localized: "Map Settings", bundle: #bundle), systemImage: "ellipsis.circle") {
                            Picker(String(localized: "Environment", bundle: #bundle), selection: $model.environment) {
                                environmentOptions
                            }
                            timeWindowPicker
                            Toggle(String(localized: "Live", bundle: #bundle), isOn: $model.isLive)
                        }
                        .help(String(localized: "Environment, time window and Live", bundle: #bundle))
                        .accessibilityIdentifier("serviceMap.settingsMenu")
                        Button(String(localized: "Details", bundle: #bundle), systemImage: "info.circle") {
                            showsDetailsPage = true
                        }
                        .help(String(localized: "Details of the service or request", bundle: #bundle))
                        .accessibilityIdentifier("serviceMap.details")
                    }
                }
            }
            ChatPanelToolbarItem()
        }
    }

    /// The map over the strip of recent requests.
    private var mapAndRequests: some View {
        VSplitView {
            GraphCanvasView(content: model.graphContent, tap: model.tap, back: model.back, showAll: model.showAll) {
                NamespaceSummary(
                    environment: model.currentEnvironment,
                    services: model.serviceCount, needingAttention: model.servicesNeedingAttention
                )
            }
                .overlay(alignment: .bottomLeading) {
                    GraphLegend(isRequest: model.showsRequest)
                        .padding(14)
                }
                // A short window (compact height, as an iPhone held sideways) gives both less room.
                .frame(minHeight: isShort ? 160 : 320, maxHeight: .infinity)
            // The map takes the height a window gains; the requests keep a strip under it.
            Group {
                if layout == .phone || requestsWidth < Self.requestsTableWidth {
                    CompactRequestsList(rows: model.requestRows, selection: $model.requestSelection)
                } else {
                    RequestsTable(rows: model.requestRows, selection: $model.requestSelection, sortOrder: $model.sortOrder)
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                requestsWidth = width
            }
            .frame(minHeight: isShort ? 100 : 140, idealHeight: isShort ? 140 : 240, maxHeight: isShort ? 200 : 320)
        }
    }

    private var environmentOptions: some View {
        ForEach(model.project.deploymentEnvironments) { environment in
            Text(verbatim: environment.name)
                .tag(environment.name)
        }
    }

    private var environmentMenu: some View {
        Menu {
            Picker(String(localized: "Environment", bundle: #bundle), selection: $model.environment) {
                environmentOptions
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: model.environment)
                .toolbarLabelPadding()
        }
        .help(String(localized: "Environment", bundle: #bundle))
        .accessibilityLabel(String(localized: "Environment", bundle: #bundle))
        .accessibilityValue(model.environment)
        .accessibilityIdentifier("serviceMap.environment")
    }

    private var timeWindowPicker: some View {
        Picker(String(localized: "Time Window", bundle: #bundle), selection: $model.timeWindow) {
            ForEach(TimeWindow.allCases) { window in
                Text(verbatim: window.title).tag(window)
            }
        }
        .help(String(localized: "Time Window", bundle: #bundle))
        .accessibilityIdentifier("serviceMap.timeWindow")
    }

    private var liveToggle: some View {
        Toggle(isOn: $model.isLive) {
            Label(String(localized: "Live", bundle: #bundle), systemImage: "dot.radiowaves.left.and.right")
        }
        .toggleStyle(.button)
        .help(String(localized: "Follow new requests as they arrive", bundle: #bundle))
        .accessibilityIdentifier("serviceMap.live")
    }

    @ViewBuilder private var inspector: some View {
        switch model.inspected {
        case .service(let node):
            ServiceInspector(
                node: node,
                calls: model.map.calls(of: node.id),
                logs: model.logs(ofService: node.id),
                isOwnService: model.isOwnService(node.id),
                onSelectService: { model.show(.service($0)) },
                onOpenContract: { openRoute(.tool(.contracts, project: model.project.id)) }
            )
        case .request(let request):
            RequestInspector(request: request, logs: model.logs(ofRequest: request.id), onSelectService: { model.show(.service($0)) })
        case .missingService(let id):
            MissingItemView(selection: .service(id), environment: model.environment, onShowAll: model.showAll)
        case .missingRequest(let id):
            MissingItemView(selection: .request(id), environment: model.environment, onShowAll: model.showAll)
        case .nothing:
            ContentUnavailableView {
                Label(String(localized: "Nothing Selected", bundle: #bundle), systemImage: "cursorarrow.click")
            } description: {
                Text("Pick a service on the map or a request in the list.", bundle: #bundle)
            }
            .accessibilityIdentifier("serviceMap.inspector.nothing")
        }
    }
}

/// The environment's cluster and namespace, and how many of its services need attention.
private struct NamespaceSummary: View {
    let environment: DeploymentEnvironment?
    /// The services of the namespace, without the databases, queues and external services.
    let services: Int
    /// The services whose health isn't Healthy.
    let needingAttention: Int

    var body: some View {
        if let environment {
            // On one line always: a narrow map drops the counts, then the cluster.
            ViewThatFits(in: .horizontal) {
                line(environment, place: "\(environment.cluster) / \(environment.namespace)", counts: true)
                line(environment, place: "\(environment.cluster) / \(environment.namespace)", counts: false)
                line(environment, place: environment.namespace, counts: false)
            }
            .accessibilityElement(children: .combine)
            // The dot's color says the environment's health on screen; VoiceOver says it in words.
            .accessibilityValue(environment.health.title)
            .accessibilityIdentifier("serviceMap.summary")
        }
    }

    private func line(_ environment: DeploymentEnvironment, place: String, counts: Bool) -> some View {
        HStack(spacing: 10) {
            StatusDot(environment.health.color)
            Text(verbatim: place)
                .monospaced()
                .foregroundStyle(.textPrimary)
            if counts {
                countsText
                    .foregroundStyle(.textSecondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .fixedSize()
        .glassEffect()
        .help(Text("\(environment.cluster) / \(environment.namespace), \(environment.health.title)", bundle: #bundle, comment: "The tooltip of the namespace summary: cluster, namespace and the environment's health"))
    }

    private var countsText: Text {
        if needingAttention == 0 {
            Text("^[\(services) service](inflect: true), all healthy", bundle: #bundle, comment: "The namespace summary: how many services, none needing attention")
        } else {
            Text("^[\(services) service](inflect: true), \(needingAttention) needing attention", bundle: #bundle, comment: "The namespace summary: how many services, and how many of them aren't healthy")
        }
    }
}

/// The recent requests of the namespace, sortable by each column. Selecting one shows its path on
/// the map.
private struct RequestsTable: View {
    let rows: [RequestRow]
    @Binding var selection: ServiceRequest.ID?
    @Binding var sortOrder: [KeyPathComparator<RequestRow>]

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Text("Status", bundle: #bundle, comment: "A column: a request's HTTP status, or a pod's kubectl status"), value: \.status) { row in
                Text(verbatim: String(row.status))
                    .monospacedDigit()
                    .foreground(statusColor(row.status), onSelection: .primary)
            }
            .width(56)
            TableColumn(Text("Method", bundle: #bundle, comment: "A column of the requests table: the HTTP method"), value: \.method) { row in
                Text(verbatim: row.method)
                    .monospaced()
            }
            .width(64)
            TableColumn(Text("Path", bundle: #bundle, comment: "A column of the requests table: the HTTP path"), value: \.path) { row in
                Text(verbatim: row.path)
                    .monospaced()
                    .accessibilityIdentifier("serviceMap.request.\(row.id)")
            }
            .width(min: 160, ideal: 280)
            TableColumn(Text("Services", bundle: #bundle, comment: "A column of the requests table: how many services a request went through"), value: \.serviceCount) { row in
                Text(row.serviceCount, format: .number)
                    .monospacedDigit()
            }
            .width(64)
            TableColumn(Text("Duration", bundle: #bundle, comment: "A column of the requests table"), value: \.duration) { row in
                durationText(row.duration)
                    .foreground(row.duration >= 1_000 ? .warning : .textPrimary, onSelection: .primary)
            }
            .width(80)
            TableColumn(Text("Started", bundle: #bundle, comment: "A column of the requests table: when a request started"), value: \.startedAt) { row in
                Text(row.startedAt, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
            }
            .width(90)
        }
        .accessibilityIdentifier("serviceMap.requests")
    }
}

/// The recent requests in an iPhone's layout: one row each, on two lines, so nothing runs off the
/// window's edge. They keep the order the table was last sorted in, newest first by default.
private struct CompactRequestsList: View {
    let rows: [RequestRow]
    @Binding var selection: ServiceRequest.ID?

    var body: some View {
        List(rows, selection: $selection) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(row.method) \(row.path)")
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(verbatim: String(row.status))
                        .monospacedDigit()
                        .foreground(statusColor(row.status), onSelection: .primary)
                    durationText(row.duration)
                        .foreground(row.duration >= 1_000 ? .warning : .textSecondary, onSelection: .secondary)
                    Text("^[\(row.serviceCount) service](inflect: true)", bundle: #bundle, comment: "How many services a request went through, in the requests list of an iPhone's layout")
                    Spacer(minLength: 8)
                    Text(row.startedAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serviceMap.request.\(row.id)")
        }
        .accessibilityIdentifier("serviceMap.requests")
    }
}

// MARK: - Previews

private func previewModel(_ projectID: Project.ID, focus: String? = nil, environment: String? = nil) -> ServiceMapModel {
    ServiceMapModel(
        project: Project.sample(projectID) ?? Project.samples[0], focus: focus, environment: environment,
        store: SampleServiceMapStore()
    )
}

#Preview("Staging", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("ORD"))
}

#Preview("Staging, Dark", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("ORD"))
        .preferredColorScheme(.dark)
}

#Preview("Request Selected", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("ORD", focus: "request:req-8f3a"))
}

#Preview("Whole Namespace", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("SHOP"))
}

#Preview("Production", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("SHOP", environment: "Production"))
}

#Preview("Service Not Found", traits: .appChrome, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("SHOP", focus: "service:auth-api"))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("ORD", focus: "request:req-8f3a"))
}

#Preview("Largest Text, Service", traits: .largestText, .fixedLayout(width: 1280, height: 820)) {
    ServiceMapRootView(model: previewModel("PAY"))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 820)) {
    ServiceMapRootView(model: previewModel("ORD"))
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ServiceMapRootView(model: previewModel("ORD"))
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ServiceMapRootView(model: previewModel("ORD", focus: "request:req-8f3a"))
        .preferredColorScheme(.dark)
}

#Preview("No Environments", traits: .appChrome, .fixedLayout(width: 1000, height: 600)) {
    ServiceMapRootView(model: previewModel("TLS"))
}
