import AZDesign
import AZDesignCode
import Charts
import SwiftUI
import ToolsFoundation

/// The inspector of a service: health, figures, traffic, calls and recent logs.
struct ServiceInspector: View {
    let node: ServiceNode
    /// The calls to and from the node.
    let calls: [ServiceCall]
    let logs: [LogLine]
    /// The project's own service offers its contract.
    let isOwnService: Bool
    let onSelectService: (ServiceNode.ID) -> Void
    let onOpenContract: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: node.kind.symbol)
                        .font(.title2)
                        .foregroundStyle(.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: node.id)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("serviceMap.inspector.name")
                        Text(verbatim: node.kind.title)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Label(node.health.title, systemImage: node.health.symbol)
                        .labelStyle(.badge(node.health.color))
                        .accessibilityIdentifier("serviceMap.inspector.health")
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow {
                        // VoiceOver reads the caption, then the value in words.
                        Figure(rateText(node.requestsPerSecond), caption: requestsCaption)
                            .accessibilityLabel(requestsCaption)
                            .accessibilityValue(ServiceMapFormat.spokenRate(node.requestsPerSecond))
                            .accessibilityIdentifier("serviceMap.inspector.requests")
                        Figure(durationText(node.p95), caption: latencyCaption)
                            .accessibilityLabel(latencyCaption)
                            .accessibilityValue(ServiceMapFormat.duration(node.p95, width: .wide))
                            .accessibilityIdentifier("serviceMap.inspector.latency")
                    }
                    GridRow {
                        Figure(Text(verbatim: ServiceMapFormat.percent(node.errorRate)), caption: Text("Errors", bundle: #bundle, comment: "A figure of a service: its error rate"))
                            .accessibilityIdentifier("serviceMap.inspector.errors")
                        if node.hasPods {
                            Figure(Text("\(node.readyPods) of \(node.pods)", bundle: #bundle, comment: "Pods ready out of the deployment's pods"), caption: Text("Pods ready", bundle: #bundle))
                                .accessibilityIdentifier("serviceMap.inspector.pods")
                        }
                    }
                }

                InspectorSection(String(localized: "Requests, last 30 minutes", bundle: #bundle)) {
                    Chart(Array(node.throughput.enumerated()), id: \.offset) { minute in
                        AreaMark(
                            x: .value(String(localized: "Minute", bundle: #bundle), minute.offset),
                            y: .value(String(localized: "Requests per second", bundle: #bundle), minute.element)
                        )
                        .foregroundStyle(.accent.opacity(0.18))
                        LineMark(
                            x: .value(String(localized: "Minute", bundle: #bundle), minute.offset),
                            y: .value(String(localized: "Requests per second", bundle: #bundle), minute.element)
                        )
                        .foregroundStyle(.accent)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 64)
                    .accessibilityIdentifier("serviceMap.inspector.chart")
                }

                InspectorSection(String(localized: "Calls", bundle: #bundle, comment: "A section of a service's details: the calls it makes and receives")) {
                    VStack(spacing: 0) {
                        ForEach(calls) { call in
                            callRow(call)
                        }
                    }
                }

                InspectorSection(String(localized: "Logs", bundle: #bundle)) {
                    LogList(lines: logs)
                }

                if isOwnService {
                    Button(String(localized: "Open Contract", bundle: #bundle), systemImage: ToolKind.contracts.symbol, action: onOpenContract)
                        .help(String(localized: "Open the service's contract in Contracts", bundle: #bundle))
                        .accessibilityIdentifier("serviceMap.inspector.openContract")
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("serviceMap.inspector.service")
    }

    private var requestsCaption: Text {
        Text("Requests", bundle: #bundle, comment: "Requests: the caption of a service's requests per second, or a chart's axis")
    }

    private var latencyCaption: Text {
        Text("p95 latency", bundle: #bundle, comment: "A figure of a service: its 95th percentile latency")
    }

    /// A call the node makes or receives, with the node at the other end, its errors and its rate. A
    /// click focuses on the other node.
    private func callRow(_ call: ServiceCall) -> some View {
        let outgoing = call.from == node.id
        let other = outgoing ? call.to : call.from
        return Button {
            onSelectService(other)
        } label: {
            HStack {
                Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left")
                    .foregroundStyle(.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: other)
                    .foregroundStyle(.textPrimary)
                Spacer()
                if call.errorRate >= 0.01 {
                    Text(verbatim: ServiceMapFormat.percent(call.errorRate))
                        .foregroundStyle(call.color)
                }
                rateText(call.requestsPerSecond)
                    .foregroundStyle(.textSecondary)
            }
            .font(.callout)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(callLabel(call, outgoing: outgoing, other: other))
        .accessibilityIdentifier("serviceMap.inspector.call.\(other)")
    }

    /// "Calls payments-api, 38 calls per second, error rate 6.8%", for VoiceOver.
    private func callLabel(_ call: ServiceCall, outgoing: Bool, other: ServiceNode.ID) -> String {
        let rate = ServiceMapFormat.spokenRate(call.requestsPerSecond)
        let errors = ServiceMapFormat.percent(call.errorRate)
        switch (outgoing, call.errorRate >= 0.01) {
        case (true, false): return String(localized: "Calls \(other), \(rate)", bundle: #bundle, comment: "A call a service makes, for VoiceOver: the node called, then its calls per second")
        case (true, true): return String(localized: "Calls \(other), \(rate), error rate \(errors)", bundle: #bundle, comment: "A call a service makes, for VoiceOver: the node called, its calls per second and its error rate")
        case (false, false): return String(localized: "Called by \(other), \(rate)", bundle: #bundle, comment: "A call a service receives, for VoiceOver: the caller, then its calls per second")
        case (false, true): return String(localized: "Called by \(other), \(rate), error rate \(errors)", bundle: #bundle, comment: "A call a service receives, for VoiceOver: the caller, its calls per second and its error rate")
        }
    }
}

/// The inspector of a request: status, the timeline of the services it went through, its logs.
struct RequestInspector: View {
    let request: ServiceRequest
    let logs: [LogLine]
    let onSelectService: (ServiceNode.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(request.method) \(request.path)")
                        .font(.headline.monospaced())
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("serviceMap.inspector.route")
                    HStack(spacing: 8) {
                        Label {
                            Text(verbatim: String(request.status))
                        } icon: {
                            Image(systemName: request.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        }
                        .labelStyle(.badge(request.statusColor))
                        .accessibilityLabel(statusLabel)
                        .accessibilityIdentifier("serviceMap.inspector.status")
                        durationText(request.duration)
                            .font(.callout)
                            .foregroundStyle(.textPrimary)
                            .accessibilityLabel(ServiceMapFormat.duration(request.duration, width: .wide))
                        Text(request.startedAt, format: .dateTime.hour().minute().second())
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                    Text(verbatim: request.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("serviceMap.inspector.requestID")
                }

                InspectorSection(String(localized: "Timeline", bundle: #bundle, comment: "A section of a request's details: its spans")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(request.spans) { span in
                            Button {
                                onSelectService(span.service)
                            } label: {
                                SpanRow(span: span, total: request.duration)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("serviceMap.inspector.span.\(span.id)")
                        }
                    }
                }

                InspectorSection(String(localized: "Logs", bundle: #bundle)) {
                    LogList(lines: logs)
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("serviceMap.inspector.request")
    }

    /// "Status 504, failed": the status's color says it on screen, the word for VoiceOver.
    private var statusLabel: String {
        request.failed
            ? String(localized: "Status \(String(request.status)), failed", bundle: #bundle, comment: "A request's HTTP status, for VoiceOver")
            : String(localized: "Status \(String(request.status)), succeeded", bundle: #bundle, comment: "A request's HTTP status, for VoiceOver")
    }
}

/// One service's part of a request, as a bar on the request's duration. A failed span says so with a
/// symbol before its duration.
private struct SpanRow: View {
    let span: Span
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(verbatim: span.service)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                Spacer()
                if span.isError {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.danger)
                        .accessibilityLabel(Text("Failed", bundle: #bundle, comment: "A span of a request that failed"))
                }
                durationText(span.duration)
                    .font(.caption)
                    .foregroundStyle(span.isError ? .danger : .textSecondary)
                    .accessibilityLabel(ServiceMapFormat.duration(span.duration, width: .wide))
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let scale = width / CGFloat(max(total, 1))
                Capsule()
                    .fill(.surfaceSunken)
                    .frame(height: 6)
                Capsule()
                    .fill(span.isError ? Color.danger : .accent)
                    .frame(width: max(4, CGFloat(span.duration) * scale), height: 6)
                    .offset(x: min(CGFloat(span.start) * scale, width - 4))
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(verbatim: span.operation)
                .font(.caption2.monospaced())
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A service or request the environment's map doesn't have: a focus from a route, or one shown
/// before the environment changed.
struct MissingItemView: View {
    let selection: MapSelection
    let environment: String
    let onShowAll: () -> Void

    var body: some View {
        ContentUnavailableView {
            switch selection {
            case .service:
                Label(String(localized: "Service Not Found", bundle: #bundle), systemImage: "questionmark.circle")
            case .request:
                Label(String(localized: "Request Not Found", bundle: #bundle), systemImage: "questionmark.circle")
            }
        } description: {
            switch selection {
            case .service(let id):
                Text("\(environment) has no service named “\(id)”.", bundle: #bundle, comment: "The details of a focus on a service the environment's map doesn't have")
            case .request(let id):
                Text("\(environment) has no recent request “\(id)”.", bundle: #bundle, comment: "The details of a request id that isn't among the environment's recent requests")
            }
        } actions: {
            Button(String(localized: "Show All", bundle: #bundle, comment: "Shows the whole namespace on the graph"), action: onShowAll)
                .accessibilityIdentifier("serviceMap.inspector.showAll")
        }
        .accessibilityIdentifier("serviceMap.inspector.missing")
    }
}

/// Log lines: time, level, message, in the code font.
struct LogList: View {
    let lines: [LogLine]

    var body: some View {
        if lines.isEmpty {
            Text("No log lines in this time window.", bundle: #bundle)
                .font(.callout)
                .foregroundStyle(.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.textSecondary)
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(line.level.color)
                            .accessibilityLabel(Text(verbatim: line.level.title))
                        Text(verbatim: line.message)
                            .foregroundStyle(.textPrimary)
                    }
                    .codeFont(.caption)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("serviceMap.inspector.log.\(line.id)")
                }
            }
        }
    }
}

