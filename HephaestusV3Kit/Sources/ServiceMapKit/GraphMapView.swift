import AZDesign
import SwiftUI
import ToolsFoundation

// Ported from HephaestusV2 (Sources/HephaestusUI/Graph/GraphMapView.swift, Sources/HephaestusCore/Graph/
// GraphColorScale.swift, docs/graph.md › Layout of the graph, › Colour of an arrow): round nodes and curved
// arrows. The geometry is V2's. What changed: the colours are AZDesign's semantic colours, a node's border
// shows its health as in X-Ray, and an arrow says calls per second (or a call's duration in a request)
// where V2 counted calls.

/// What the graph draws, whatever the view: the nodes and arrows, where they go, and what each arrow says.
struct GraphMapModel {
    var nodes: [ServiceNode]
    var arrows: [GraphArrow]
    var layout: GraphLayout
    /// The arrow of the Client in the view of a request, with the route written under the Client.
    var clientArrow: GraphArrow.ID?
    var clientRoute: String?
    var focusID: ServiceNode.ID?
    /// True in a view narrower than the whole graph: every label is written.
    var showsAllLabels: Bool

    var busiest: Double { arrows.map(\.weight).max() ?? 0 }

    func color(of arrow: GraphArrow) -> Color {
        GraphColorScale.color(weight: arrow.weight, busiest: busiest)
    }

    func label(of arrow: GraphArrow) -> String {
        if arrow.id == clientArrow, let clientRoute {
            return clientRoute
        }
        return arrow.label
    }

    /// The label of an arrow in words, for VoiceOver.
    func spokenLabel(of arrow: GraphArrow) -> String {
        arrow.spokenLabel
    }
}

/// The colour of an arrow: grey without any call; otherwise from green to red in proportion of its weight to
/// the heaviest arrow shown, which is red. V2 turned the hue from 120° to 0°; here the scale goes through
/// AZDesign's success, warning and danger, so it follows the app's palette and High Contrast.
enum GraphColorScale {
    static func color(weight: Double, busiest: Double) -> Color {
        guard weight > 0, busiest > 0 else { return grey }
        let ratio = min(weight / busiest, 1)
        return ratio < 0.5
            ? Color.success.mix(with: .warning, by: ratio * 2)
            : Color.warning.mix(with: .danger, by: (ratio - 0.5) * 2)
    }

    /// The grey of an arrow without calls: opaque, so two crossing arrows show no darker spot.
    static let grey = Color.textSecondary.mix(with: .canvas, by: 0.45)
}

/// The geometry of the graph's drawing.
enum GraphGeometry {
    static let nodeDiameter: CGFloat = 54
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 3
    /// The most a fit zooms in.
    static let fitScale: CGFloat = 1.5
    /// The zoom below which the names are hidden: hovering a node shows its name.
    static let nameScale: CGFloat = 0.3
    /// The zoom from which every arrow has its label written.
    static let labelScale: CGFloat = 0.5

    /// The zoom and the place that show every node of `layout` with its name in a view of `size`,
    /// at 150% at most.
    static func fit(_ layout: GraphLayout, nodes: [ServiceNode], in size: CGSize) -> (scale: CGFloat, offset: CGSize)? {
        let points = nodes.compactMap { layout.positions[$0.id] }
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let room = GraphLayout.margin
        let minX = (points.map(\.x).min() ?? 0) - room
        let maxX = (points.map(\.x).max() ?? 0) + room
        let minY = (points.map(\.y).min() ?? 0) - room
        let maxY = (points.map(\.y).max() ?? 0) + room
        let fitted = min(size.width / (maxX - minX), size.height / (maxY - minY), fitScale)
        let scale = min(max(fitted, minScale), maxScale)
        let offset = CGSize(width: (size.width - (maxX - minX) * scale) / 2 - minX * scale,
                            height: (size.height - (maxY - minY) * scale) / 2 - minY * scale)
        return (scale, offset)
    }

    /// An arrow on the screen: the curve between the centres of two nodes, bent to its left, from
    /// where it leaves the circle of one to where it meets the circle of the other, with its head,
    /// whose tip touches that circle.
    struct Arrow {
        /// On the circle of the node the arrow leaves.
        var start: CGPoint
        /// On the circle of the node the arrow goes into.
        var tip: CGPoint
        /// The middle of the head's base: the point of the curve one head length before the tip,
        /// where the line stops.
        var base: CGPoint
        /// The control point of the part of the curve from `start` to `base`.
        var lineControl: CGPoint
        /// The unit vector of the head's axis, from `base` to `tip`.
        var axis: CGVector
        /// Half the width of the head's base.
        var halfWidth: CGFloat
        var lineWidth: CGFloat
        /// The middle of the curve, where the label is written.
        var middle: CGPoint

        /// The line, stopping at the middle of the head's base.
        var line: Path {
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: base, control: lineControl)
            return path
        }

        var head: Path {
            var path = Path()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - axis.dy * halfWidth, y: base.y + axis.dx * halfWidth))
            path.addLine(to: CGPoint(x: base.x + axis.dy * halfWidth, y: base.y - axis.dx * halfWidth))
            path.closeSubpath()
            return path
        }
    }

    /// The arrow between two nodes centred at `from` and `to` at `scale`; nil when their circles
    /// leave no room between them. A call each way gives two curves that meet each circle at two
    /// different points, so neither line runs into the other's head.
    static func arrow(from: CGPoint, to: CGPoint, scale: CGFloat) -> Arrow? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        let radius = nodeDiameter / 2 * scale
        guard length > 2 * radius + 0.5 else { return nil }
        let bend = length * 0.12
        let control = CGPoint(x: (from.x + to.x) / 2 + dy / length * bend, y: (from.y + to.y) / 2 - dx / length * bend)

        func point(_ t: CGFloat) -> CGPoint {
            let a = (1 - t) * (1 - t)
            let b = 2 * t * (1 - t)
            let c = t * t
            return CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        /// The parameter between `low`, where `far` is true, and `high`, where it is false, at which it turns false.
        func search(_ low: CGFloat, _ high: CGFloat, far: (CGFloat) -> Bool) -> CGFloat {
            var low = low
            var high = high
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if far(middle) {
                    low = middle
                } else {
                    high = middle
                }
            }
            return (low + high) / 2
        }

        // The gently bent curve moves away from each centre all along it.
        let first = search(0.5, 0, far: { distance(point($0), from) > radius })
        let last = search(0.5, 1, far: { distance(point($0), to) > radius })
        let start = point(first)
        let tip = point(last)
        let side = 10 * max(scale, 0.5)
        let headLength = side * cos(.pi / 7)
        var halfWidth = side * sin(.pi / 7)
        // The point of the curve one head length before the tip. A curve shorter than a head is all head.
        var stop = first
        let whole = distance(start, tip)
        if whole <= headLength {
            halfWidth *= whole / headLength
        } else {
            stop = search(first, last, far: { distance(point($0), tip) > headLength })
        }
        let base = point(stop)
        let reach = distance(base, tip)
        // The control point of the part of the curve from `first` to `stop`.
        let a = (1 - first) * (1 - stop)
        let b = (1 - first) * stop + first * (1 - stop)
        let c = first * stop
        let lineControl = CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
        return Arrow(start: start, tip: tip, base: base, lineControl: lineControl,
                     axis: CGVector(dx: (tip.x - base.x) / reach, dy: (tip.y - base.y) / reach),
                     halfWidth: halfWidth, lineWidth: 1.6 * max(scale, 0.5), middle: point(0.5))
    }
}

/// The nodes and arrows of a graph at a zoom and a place; `tap` receives a click on a service. Other
/// nodes take no click.
///
/// VoiceOver reads each node (its name, kind, health and focus) and then each arrow (what calls what,
/// and its label in words), whatever the zoom: the drawing stays V2's, the accessibility sits on top.
struct GraphMapView: View {
    let model: GraphMapModel
    let scale: CGFloat
    let offset: CGSize
    var tap: ((ServiceNode) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Every head over every line, and the labels over both.
                let arrows = model.arrows.compactMap { arrow in shape(of: arrow).map { (arrow, $0) } }
                for (arrow, shape) in arrows {
                    drawLine(shape, color: model.color(of: arrow), in: &context)
                }
                for (arrow, shape) in arrows {
                    context.fill(shape.head, with: .color(model.color(of: arrow)))
                }
                for (arrow, shape) in arrows {
                    drawLabel(arrow, at: shape.middle, in: &context)
                }
            }
            .allowsHitTesting(false)
            // The arrows for VoiceOver: one element at the middle of each, after the nodes.
            .accessibilityChildren {
                ZStack(alignment: .topLeading) {
                    ForEach(model.arrows) { arrow in
                        Rectangle()
                            .frame(width: 24, height: 16)
                            .accessibilityLabel(arrowLabel(arrow))
                            .accessibilityValue(model.spokenLabel(of: arrow))
                            .accessibilityIdentifier("serviceMap.arrow.\(arrow.from).\(arrow.to)")
                            .position(middle(of: arrow))
                    }
                }
            }
            ForEach(model.nodes) { node in
                nodeView(node)
                    .accessibilityLabel(Text(verbatim: node.id))
                    .accessibilityValue(nodeValue(node))
                    .accessibilityAddTraits(model.focusID == node.id ? .isSelected : [])
                    .accessibilitySortPriority(1)
                    .accessibilityIdentifier("serviceMap.node.\(node.id)")
                    .position(screen(model.layout.positions[node.id]))
            }
        }
    }

    /// A service is a button when the graph takes clicks; any other node is drawn alone.
    @ViewBuilder
    private func nodeView(_ node: ServiceNode) -> some View {
        let drawing = GraphNodeView(
            node: node, scale: scale, ringLabel: ringLabel(of: node),
            route: node.kind == .client ? clientRoute : nil,
            side: side(of: node), focused: model.focusID == node.id
        )
        if let tap, node.kind.isService {
            Button {
                tap(node)
            } label: {
                drawing
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Focuses the map on this service.", bundle: #bundle))
        } else {
            // One element, as a button would be: its name, kind and health.
            drawing
                .accessibilityElement(children: .ignore)
        }
    }

    /// What VoiceOver says after a node's name: its kind and health, and the Client's route.
    private func nodeValue(_ node: ServiceNode) -> String {
        if node.kind == .client, let route = clientRoute {
            return String(localized: "\(node.kind.title), \(route.text)", bundle: #bundle, comment: "Two parts of a description, such as a name and a kind, or a kind and a health")
        }
        return String(localized: "\(node.kind.title), \(node.health.title)", bundle: #bundle, comment: "Two parts of a description, such as a name and a kind, or a kind and a health")
    }

    /// "orders-api to payments-api", for VoiceOver.
    private func arrowLabel(_ arrow: GraphArrow) -> String {
        String(localized: "\(arrow.from) to \(arrow.to)", bundle: #bundle, comment: "An arrow of the graph, for VoiceOver: the node that calls, then the node called")
    }

    /// The middle of an arrow on the screen, or of the line between its nodes when they touch.
    private func middle(of arrow: GraphArrow) -> CGPoint {
        if let shape = shape(of: arrow) {
            return shape.middle
        }
        let from = screen(model.layout.positions[arrow.from])
        let to = screen(model.layout.positions[arrow.to])
        return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    }

    /// A point of the layout on the screen.
    private func screen(_ point: GraphLayout.Point?) -> CGPoint {
        let point = point ?? GraphLayout.Point(x: 0, y: 0)
        return CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    /// Whether the labels of the arrows are written.
    private var writesLabels: Bool {
        scale >= GraphGeometry.labelScale || model.showsAllLabels
    }

    private var clientRoute: (text: String, color: Color)? {
        guard let id = model.clientArrow, let arrow = model.arrows.first(where: { $0.id == id }) else { return nil }
        return (model.label(of: arrow), model.color(of: arrow))
    }

    /// The label of the arrow from its service to a box of a ring, and its colour, when labels are written.
    private func ringLabel(of node: ServiceNode) -> (text: String, color: Color)? {
        guard writesLabels, let owner = model.layout.rings[node.id],
              let arrow = model.arrows.first(where: { $0.from == owner && $0.to == node.id }) else { return nil }
        return (arrow.label, model.color(of: arrow))
    }

    /// The side the name of a node goes on: below a service; on the outer side of a box of a ring,
    /// away from its service.
    private func side(of node: ServiceNode) -> GraphNodeView.Side {
        guard let owner = model.layout.rings[node.id], let center = model.layout.positions[owner],
              let point = model.layout.positions[node.id] else { return .below }
        let angle = atan2(point.y - center.y, point.x - center.x)
        if cos(angle) > 0.5 {
            return .right
        }
        if cos(angle) < -0.5 {
            return .left
        }
        return sin(angle) < 0 ? .above : .below
    }

    /// A curve from the edge of a node to the edge of the other, bent to its left, so a call each
    /// way gives two curves apart, and its head, whose tip touches the circle it goes into.
    private func shape(of arrow: GraphArrow) -> GraphGeometry.Arrow? {
        GraphGeometry.arrow(from: screen(model.layout.positions[arrow.from]), to: screen(model.layout.positions[arrow.to]),
                            scale: scale)
    }

    /// The line of an arrow, stopping at the middle of its head's base.
    private func drawLine(_ shape: GraphGeometry.Arrow, color: Color, in context: inout GraphicsContext) {
        guard shape.base != shape.start else { return }
        context.stroke(shape.line, with: .color(color), style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .butt))
        // The round start goes under the node the arrow leaves, so the line meets its circle all
        // across its width.
        let dot = shape.lineWidth
        context.fill(Path(ellipseIn: CGRect(x: shape.start.x - dot / 2, y: shape.start.y - dot / 2, width: dot, height: dot)),
                     with: .color(color))
    }

    /// The label of an arrow at its middle, in a capsule of its colour.
    private func drawLabel(_ arrow: GraphArrow, at middle: CGPoint, in context: inout GraphicsContext) {
        // The label of a box of a ring is written after its kind, and the route under the Client:
        // their arrows are too short.
        guard writesLabels, model.layout.rings[arrow.to] != arrow.from, arrow.id != model.clientArrow else { return }
        let color = model.color(of: arrow)
        let label = context.resolve(Text(verbatim: model.label(of: arrow)).font(.caption2.monospacedDigit().bold()).foregroundStyle(.textPrimary))
        let size = label.measure(in: CGSize(width: 200, height: 40))
        let capsule = CGRect(x: middle.x - size.width / 2 - 5, y: middle.y - size.height / 2 - 1, width: size.width + 10,
                             height: size.height + 2)
        context.fill(Capsule().path(in: capsule), with: .color(.canvas))
        context.stroke(Capsule().path(in: capsule), with: .color(color), lineWidth: 1)
        context.draw(label, at: middle)
    }
}

/// A round node with the icon of its kind, its name next to it, and its kind under the name for
/// what is not a service.
struct GraphNodeView: View {
    /// Where the name goes: below the node, or on the outer side of a box of a ring.
    enum Side {
        case below, above, left, right
    }

    let node: ServiceNode
    let scale: CGFloat
    /// For a box of a ring, the label of its arrow and its colour, written after its kind.
    let ringLabel: (text: String, color: Color)?
    /// For the Client, the route of the request and the colour of its arrow, written under its name.
    let route: (text: String, color: Color)?
    let side: Side
    let focused: Bool

    var body: some View {
        let diameter = GraphGeometry.nodeDiameter * scale
        let gap = 3 * scale
        Group {
            switch side {
            case .below:
                VStack(spacing: gap) { circle(diameter); names(alignment: .center) }
            case .above:
                VStack(spacing: gap) { names(alignment: .center); circle(diameter) }
            case .right:
                HStack(spacing: gap * 2) { circle(diameter); names(alignment: .leading) }
            case .left:
                HStack(spacing: gap * 2) { names(alignment: .trailing); circle(diameter) }
            }
        }
        // Centred on the circle: the names hang on their side of it.
        .frame(width: diameter, height: diameter, alignment: frameAlignment)
        .contentShape(Circle().size(width: diameter, height: diameter))
        .help(node.kind.isService || node.kind == .client ? node.id : String(localized: "\(node.id), \(node.kind.title)", bundle: #bundle, comment: "Two parts of a description, such as a name and a kind, or a kind and a health"))
    }

    private var frameAlignment: Alignment {
        switch side {
        case .below: .top
        case .above: .bottom
        case .right: .leading
        case .left: .trailing
        }
    }

    private func circle(_ diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.surface)
            Circle()
                .strokeBorder(border, lineWidth: borderWidth * max(scale, 0.5))
            Image(systemName: node.kind.symbol)
                .font(.system(size: 20 * scale))
                .foregroundStyle(node.kind.isService ? Color.textPrimary : Color.textSecondary)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Never smaller than can be read; hidden when the nodes are too close for it.
    @ViewBuilder
    private func names(alignment: HorizontalAlignment) -> some View {
        if scale >= GraphGeometry.nameScale {
            VStack(alignment: alignment, spacing: 1) {
                Text(verbatim: node.id)
                    .font(.system(size: max(12 * scale, 9), weight: node.kind.isService || node.kind == .client ? .semibold : .regular))
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                if let route {
                    Text(verbatim: route.text)
                        .font(.system(size: max(10 * scale, 8), design: .monospaced))
                        .foregroundStyle(route.color)
                }
                if !node.kind.isService, node.kind != .client {
                    kindLine
                        .font(.system(size: max(10 * scale, 8)))
                }
            }
            .fixedSize()
        }
    }

    /// The kind of a box of a ring, followed by its arrow's label in that arrow's colour when labels are
    /// written: "Database · 210/s".
    private var kindLine: Text {
        let kind = Text(verbatim: node.kind.title)
            .foregroundStyle(.textSecondary)
        guard let ringLabel else { return kind }
        let label = Text(verbatim: ringLabel.text)
            .foregroundStyle(ringLabel.color)
        return Text("\(kind) · \(label)", bundle: #bundle, comment: "Under a database, queue or external service on the graph: its kind, then the label of the arrow into it")
    }

    /// The accent for the node in focus; otherwise its health, as X-Ray rings a node: orange when
    /// degraded, red when down.
    private var border: Color {
        if focused {
            return .accent
        }
        switch node.health {
        case .degraded: return .warning
        case .down: return .danger
        case .healthy: return node.kind.isService ? Color.textSecondary.opacity(0.8) : Color.textSecondary.opacity(0.4)
        }
    }

    private var borderWidth: CGFloat {
        if focused { return 3 }
        return node.health == .healthy ? 1.5 : 2.5
    }
}
