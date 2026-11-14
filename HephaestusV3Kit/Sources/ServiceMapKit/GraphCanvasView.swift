import AppKit
import AZDesign
import SwiftUI
import ToolsFoundation

// Zoom, pan, fit, focus and the right-click that goes back. The zoom controls sit on glass here, with a
// Back button whose ⌘[ goes back from the keyboard too.

/// What the graph shows: its nodes and arrows, and what the view is about.
struct GraphContent: Equatable {
    var nodes: [ServiceNode]
    var arrows: [GraphArrow]
    /// In the view of a request: the Client's arrow, and the route written under the Client.
    var clientArrow: GraphArrow.ID?
    var clientRoute: String?
    /// The node with the accent border: the service in focus or inspected.
    var focusID: ServiceNode.ID?
    /// A view other than the whole namespace: a service in focus or a request, even one the map
    /// doesn't have. Back and Show All show.
    var isScoped: Bool
    /// True in a view narrower than the whole graph: every arrow's label is written, at any zoom.
    var showsAllLabels: Bool

    /// What the layout depends on: which nodes and arrows, not their numbers.
    var topology: [String] { nodes.map(\.id) + ["|"] + arrows.map(\.id) }
}

/// The nodes and arrows of the view shown. Pinching zooms around the pointer, dragging the
/// background pans, a click on a node goes to `tap`, and a right-click anywhere on the graph, the Back
/// button or ⌘[ to `back`.
///
/// `accessory` shares the top row with the zoom controls, at its left: the two never overlap, and
/// each drops its less useful parts when the row is narrow.
struct GraphCanvasView<Accessory: View>: View {
    let content: GraphContent
    var tap: (ServiceNode) -> Void = { _ in }
    var back: () -> Void = {}
    var showAll: () -> Void = {}
    @ViewBuilder var accessory: Accessory
    /// The room the window's overlays take at the edges, which a fit keeps the nodes out of.
    var fitInsets = EdgeInsets(top: 58, leading: 0, bottom: 54, trailing: 0)

    @State private var layout: GraphLayout?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStart: (scale: CGFloat, offset: CGSize)?
    @State private var dragStart: CGSize?
    @State private var viewSize: CGSize = .zero
    /// True until the zoom or the place is changed by hand: the view fits again when its size changes.
    @State private var fitted = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // A click on the background does nothing.
                Rectangle()
                    .fill(.canvas)
                    .contentShape(.rect)
                if let layout {
                    GraphMapView(
                        model: GraphMapModel(
                            nodes: content.nodes, arrows: content.arrows, layout: layout,
                            clientArrow: content.clientArrow, clientRoute: content.clientRoute,
                            focusID: content.focusID, showsAllLabels: content.showsAllLabels
                        ),
                        scale: scale, offset: offset, tap: tap
                    )
                }
            }
            .clipped()
            .gesture(pan)
            .simultaneousGesture(pinch)
            .overlay {
                RightClickCatcher { back() }
            }
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 8) {
                    accessory
                    Spacer(minLength: 0)
                    controls
                        .layoutPriority(1)
                }
                .padding(14)
            }
            .onAppear {
                viewSize = geometry.size
                relayout()
            }
            .onChange(of: geometry.size) { _, size in
                viewSize = size
                if fitted {
                    fit()
                }
            }
            .onChange(of: content.topology) {
                relayout()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ToolKind.serviceMap.title)
        .accessibilityIdentifier("serviceMap.graph")
    }

    /// The zoom controls, which drop the zoom level, then the Back button's title, when the row is narrow.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlBar(backTitle: true, level: true)
            controlBar(backTitle: true, level: false)
            controlBar(backTitle: false, level: false)
        }
    }

    private func controlBar(backTitle: Bool, level: Bool) -> some View {
        HStack(spacing: 10) {
            if content.isScoped {
                Button(action: back) {
                    Label(String(localized: "Back", bundle: #bundle, comment: "Goes back to the graph's view before"), systemImage: "chevron.backward")
                        .labelStyle(BackLabelStyle(showsTitle: backTitle))
                }
                .keyboardShortcut("[", modifiers: .command)
                .help(String(localized: "Back to the view before (⌘[ or a right-click on the graph)", bundle: #bundle))
                .accessibilityIdentifier("serviceMap.back")
                Button(String(localized: "Show All", bundle: #bundle, comment: "Shows the whole namespace on the graph"), action: showAll)
                    .help(String(localized: "Show the whole namespace", bundle: #bundle))
                    .accessibilityIdentifier("serviceMap.showAll")
            }
            Button(String(localized: "Zoom Out", bundle: #bundle), systemImage: "minus.magnifyingglass") { zoom(by: 1 / 1.25) }
                .labelStyle(.iconOnly)
                .help(String(localized: "Zoom Out", bundle: #bundle))
                .accessibilityIdentifier("serviceMap.zoomOut")
            Button(String(localized: "Zoom In", bundle: #bundle), systemImage: "plus.magnifyingglass") { zoom(by: 1.25) }
                .labelStyle(.iconOnly)
                .help(String(localized: "Zoom In", bundle: #bundle))
                .accessibilityIdentifier("serviceMap.zoomIn")
            Button(String(localized: "Fit", bundle: #bundle, comment: "Zooms the graph so that every node shows")) { fit() }
                .help(String(localized: "Show every node", bundle: #bundle))
                .accessibilityIdentifier("serviceMap.fit")
            if level {
                Text(scale, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.textSecondary)
                    .frame(minWidth: 36)
                    .accessibilityLabel(Text("Zoom", bundle: #bundle, comment: "The graph's zoom level, for VoiceOver"))
                    .accessibilityValue(Text(scale, format: .percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("serviceMap.zoomLevel")
            }
        }
        .lineLimit(1)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect()
    }

    // MARK: Layout, zoom and pan

    /// Lays the graph out again, then fits it: each change of view (a focus, a request, back, Show All).
    private func relayout() {
        layout = GraphLayout(nodes: content.nodes, arrows: content.arrows)
        fit()
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                fitted = false
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Zooms around the point the pinch started on: that point of the graph stays under the pointer.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (scale, offset)
                pinchStart = start
                fitted = false
                zoom(to: start.scale * value.magnification, around: value.startLocation, from: start)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func zoom(by factor: CGFloat) {
        fitted = false
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        zoom(to: scale * factor, around: center, from: (scale, offset))
    }

    private func zoom(to newScale: CGFloat, around point: CGPoint, from start: (scale: CGFloat, offset: CGSize)) {
        let clamped = min(max(newScale, GraphGeometry.minScale), GraphGeometry.maxScale)
        let ratio = clamped / start.scale
        scale = clamped
        offset = CGSize(width: point.x - (point.x - start.offset.width) * ratio,
                        height: point.y - (point.y - start.offset.height) * ratio)
    }

    /// Shows every node, with its name, in the view, at 150% at most, clear of the overlays.
    private func fit() {
        let room = CGSize(
            width: viewSize.width - fitInsets.leading - fitInsets.trailing,
            height: viewSize.height - fitInsets.top - fitInsets.bottom
        )
        guard let layout, let fit = GraphGeometry.fit(layout, nodes: content.nodes, in: room) else { return }
        scale = fit.scale
        offset = CGSize(width: fit.offset.width + fitInsets.leading, height: fit.offset.height + fitInsets.top)
        fitted = true
    }
}

/// Catches the right clicks on the view it covers, and only them: the other events go to the
/// views under it.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            nil
        }
    }
}

/// The Back button's label: its symbol and title, or its symbol alone when the row is narrow.
private struct BackLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            HStack(spacing: 3) {
                configuration.icon
                configuration.title
            }
        } else {
            configuration.icon
        }
    }
}

/// What the colours of the graph mean.
struct GraphLegend: View {
    /// In the view of a request the scale weighs durations, not calls.
    let isRequest: Bool

    var body: some View {
        // On one line always: a narrow map drops the grey arrows' entry, then the states.
        ViewThatFits(in: .horizontal) {
            bar(noCalls: true, states: true)
            bar(noCalls: false, states: true)
            bar(noCalls: false, states: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serviceMap.legend")
    }

    private func bar(noCalls: Bool, states: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                if isRequest {
                    Text("Faster", bundle: #bundle, comment: "The low end of the graph's color scale in a request's view")
                } else {
                    Text("Fewer calls", bundle: #bundle, comment: "The low end of the graph's color scale")
                }
                Capsule()
                    .fill(LinearGradient(colors: [.success, .warning, .danger], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 56, height: 5)
                    .accessibilityHidden(true)
                if isRequest {
                    Text("Slowest", bundle: #bundle, comment: "The high end of the graph's color scale in a request's view")
                } else {
                    Text("Busiest", bundle: #bundle, comment: "The high end of the graph's color scale")
                }
            }
            if noCalls && !isRequest {
                item(String(localized: "No calls", bundle: #bundle, comment: "The legend of a grey arrow")) {
                    Capsule().fill(GraphColorScale.grey).frame(width: 14, height: 3)
                }
            }
            if states {
                item(DeploymentEnvironment.Health.degraded.title) {
                    Circle().strokeBorder(.warning, lineWidth: 2).frame(width: 10, height: 10)
                }
                item(DeploymentEnvironment.Health.down.title) {
                    Circle().strokeBorder(.danger, lineWidth: 2).frame(width: 10, height: 10)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize()
        .glassEffect()
    }

    private func item(_ title: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 5) {
            mark()
                .accessibilityHidden(true)
            Text(verbatim: title)
        }
    }
}

extension GraphCanvasView where Accessory == EmptyView {
    init(content: GraphContent, tap: @escaping (ServiceNode) -> Void = { _ in }, back: @escaping () -> Void = {}, showAll: @escaping () -> Void = {}) {
        self.init(content: content, tap: tap, back: back, showAll: showAll) { EmptyView() }
    }
}
