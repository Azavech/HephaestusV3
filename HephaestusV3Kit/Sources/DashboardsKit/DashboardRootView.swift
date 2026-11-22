import AppKit
import AZDesign
import SwiftUI
import ToolsFoundation

// The Dashboard as a tool window (docs/ui/dashboard.md): its grid, its placement, the move and the resize of
// a widget with the others making room live, the scrolling near the edges, the smallest size and the content
// that scrolls inside a widget. The list is kept by a `DashboardLayoutStore`, so a change applies at
// once; edit mode and the changes live in `DashboardModel`; the bar is the window's toolbar; each tool
// draws its own widgets, through `widgetContent`; and the keyboard and VoiceOver move and resize a
// widget one cell at a time.

/// Values of the Dashboard view that a generic type cannot hold.
enum DashboardSpace {
    /// The coordinate space of the visible part of the widget area.
    static let visibleArea = "dashboardVisibleArea"
    /// The margin around the widget area.
    static let margin: CGFloat = 20
    /// Below this width the widgets are listed one a row instead of placed on the grid.
    static let listWidth: CGFloat = 900
    /// The margin around the list of widgets.
    static let listMargin: CGFloat = 16

    /// The width macOS keeps for the scroll bar of the widget area when it always shows scroll
    /// bars; 0 when the scroll bars show over the content.
    static var scrollBarWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// The Dashboard window of a project: its widgets on an invisible grid of 24 columns of square cells,
/// as in Grafana. `Edit` lets the user add, remove, move, resize and set up the widgets.
///
/// `widgetContent` draws what a widget shows under its title row; each tool provides the widgets of
/// its own data, and ToolsScenes puts them together.
/// What a tab keeps of the Dashboard while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class DashboardTabState {
    let model: DashboardModel

    public init(project: Project, store: LiveDashboardStore) {
        model = DashboardModel(project: project, store: store)
    }
}

public struct DashboardRootView<WidgetContent: View>: View {
    @State private var model: DashboardModel
    /// The project as loaded now, passed on to the model.
    private let project: Project
    let widgetContent: (DashboardWidget, DashboardContext) -> WidgetContent

    @Environment(\.windowLayout) private var layout
    @Environment(\.availableTools) private var availableTools
    /// The Dashboard's own width, which picks the grid or the list. Wide until measured.
    @State private var viewWidth: CGFloat = 10_000
    /// The list's width, which sets its cards' width.
    @State private var scrollPosition = ScrollPosition()
    /// How far the widget area is scrolled; read when a drag starts and while the Dashboard
    /// scrolls under one, so it is kept outside the view's state.
    @State private var scroll = DashboardScroll()
    @State private var scrollBarWidth = DashboardSpace.scrollBarWidth

    /// The Dashboard of `project`, kept in its project file by `store`; `widgetContent` draws each widget's
    /// content.
    public init(
        project: Project,
        store: LiveDashboardStore,
        @ViewBuilder widgetContent: @escaping (DashboardWidget, DashboardContext) -> WidgetContent
    ) {
        self.init(model: DashboardModel(project: project, store: store), widgetContent: widgetContent)
    }

    /// The Dashboard a tab keeps, given `project` as it is loaded now, which its kept model takes: an
    /// environment chosen, Project Settings' changes. `widgetContent` draws each widget's content.
    public init(state: DashboardTabState, project: Project,
                @ViewBuilder widgetContent: @escaping (DashboardWidget, DashboardContext) -> WidgetContent) {
        self.init(model: state.model, project: project, widgetContent: widgetContent)
    }

    /// The Dashboard of a model, on `project` or the model's own: for previews and tests.
    init(model: DashboardModel, project: Project? = nil,
         @ViewBuilder widgetContent: @escaping (DashboardWidget, DashboardContext) -> WidgetContent) {
        _model = State(initialValue: model)
        self.project = project ?? model.project
        self.widgetContent = widgetContent
    }

    public var body: some View {
        Group {
            if showsList {
                widgetList
            } else {
                gridArea
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            viewWidth = width
        }
        .background(.canvas)
        .overlay {
            if model.showsNoWidgets {
                ContentUnavailableView {
                    Label(String(localized: "No Widgets", bundle: #bundle), systemImage: ToolKind.dashboard.symbol)
                } description: {
                    emptyDescription
                }
                .accessibilityIdentifier("dashboard.empty")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure = model.failure {
                failureBanner(failure)
            }
        }
        .toolbar { toolbar }
        .onChange(of: project, initial: true) {
            if model.project != project {
                model.project = project
            }
        }
        .onChange(of: availableTools, initial: true) {
            if model.tools != availableTools {
                model.tools = availableTools
            }
        }
        .onChange(of: showsList) {
            // The widgets are placed and sized on the grid only: the list has no edit mode.
            if showsList {
                model.endEditing()
            }
        }
    }

    /// Why the last change failed, under the toolbar until the next change.
    private func failureBanner(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DashboardSpace.margin)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("The change failed: \(message)", bundle: #bundle))
        .accessibilityIdentifier("dashboard.failure")
    }

    private var emptyDescription: Text {
        if showsList {
            Text("Widen the window to edit the Dashboard.", bundle: #bundle)
        } else if model.editing {
            Text("Add a widget from the toolbar.", bundle: #bundle)
        } else {
            Text("Click Edit to add widgets.", bundle: #bundle)
        }
    }

    /// Below 900 points, where the 24 columns would cramp the widgets, and at an iPhone's width, the
    /// Dashboard lists its widgets one a row (the user's choice).
    private var showsList: Bool {
        layout == .phone || viewWidth < DashboardSpace.listWidth
    }

    /// One widget a row, full width and as tall as its content, in the grid's order, top to bottom
    /// and left to right. The grid itself, and its edit mode, need a wider window.
    private var widgetList: some View {
        let list = model.widgets
        let slots = DashboardSlot.slots(of: list)
        let rows = model.listOrder.map { DashboardListRow(slot: slots[$0], widget: list[$0]) }
        let context = model.context
        // The cards' width comes from the room the list is given, never from their content: content
        // that can't be as narrow scrolls inside its card. A geometry reader takes the room it is
        // offered whatever its content, so the cards follow the window as it narrows.
        return GeometryReader { area in
            let cardWidth = max(area.size.width - 2 * DashboardSpace.listMargin, 0)
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(rows, id: \.slot) { row in
                        VStack(alignment: .leading, spacing: DashboardWidgetCard<WidgetContent>.spacing) {
                            DashboardWidgetTitleRow(widget: row.widget, editing: false)
                            ListCardContent(available: max(cardWidth - 2 * DashboardGridMetrics.padding, 0)) {
                                DashboardWidgetCard<WidgetContent>.sized(widgetContent(row.widget, context), kind: row.widget.kind)
                            }
                        }
                        .padding(DashboardGridMetrics.padding)
                        .frame(width: cardWidth, alignment: .topLeading)
                        .background(.surface, in: CardShape.card)
                        .clipShape(CardShape.card)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(DashboardContent.title(of: row.widget))
                        .accessibilityIdentifier("dashboard.widget.\(row.slot.identifier)")
                    }
                }
                .padding(DashboardSpace.listMargin)
            }
        }
    }

    /// The Mac's and an iPad's: the grid.
    private var gridArea: some View {
        GeometryReader { area in
            // The widget area is as wide with its scroll bar as without it: the cells follow its
            // width, so a bar that took room from it would make the widgets lower, and come and go
            // without end.
            let width = max(area.size.width - 2 * DashboardSpace.margin - scrollBarWidth, 0)
            ScrollView {
                grid(metrics: DashboardGridMetrics(width: width))
                    .frame(width: width)
                    .padding(DashboardSpace.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: width, initial: true) {
                model.areaWidth = width
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: DashboardScroll.Metrics.self) { geometry in
                DashboardScroll.Metrics(offset: geometry.contentOffset.y, visibleHeight: geometry.containerSize.height,
                                        contentHeight: geometry.contentSize.height)
            } action: { _, metrics in
                scroll.metrics = metrics
                // The widget stays under the pointer while the Dashboard scrolls under it.
                model.scrolled(to: metrics.offset)
            }
            .coordinateSpace(.named(DashboardSpace.visibleArea))
            .pointerStyle(model.drag?.kind == .resize ? .frameResize(position: .bottomTrailing) : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollBarWidth = DashboardSpace.scrollBarWidth
        }
        .onChange(of: DashboardSlot.slots(of: model.widgets)) { _, slots in
            model.keep(slots)
        }
        .task(id: model.drag != nil) {
            await scrollWhileDragging()
        }
    }

    // MARK: Toolbar

    /// The bar: the time window of the service widgets, `Add Widget` in edit mode, and `Edit` or
    /// `Done`, and the environment.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if layout == .phone {
            // An iPhone's: the environment and the time window in one menu.
            if model.showsEnvironment || model.showsTimeWindow {
                ToolbarItem(placement: .primaryAction) {
                    Menu(String(localized: "Dashboard Settings", bundle: #bundle), systemImage: "ellipsis.circle") {
                        if model.showsEnvironment {
                            environmentPicker
                        }
                        if model.showsTimeWindow {
                            timeWindowPicker
                        }
                    }
                    .help(Text("Environment and time window", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.settingsMenu")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.showsEnvironment {
                    Menu {
                        environmentPicker
                            .pickerStyle(.inline)
                            .labelsHidden()
                    } label: {
                        Text(verbatim: model.environment?.name ?? "")
                            .toolbarLabelPadding()
                    }
                    .help(Text("Environment the Instances and service widgets read", bundle: #bundle))
                    .accessibilityLabel(Text("Environment", bundle: #bundle))
                    .accessibilityValue(model.environment?.name ?? "")
                    .accessibilityIdentifier("dashboard.environment")
                }
                if model.showsTimeWindow {
                    if layout == .mac {
                        timeWindowPicker
                            .pickerStyle(.segmented)
                    } else {
                        // Less room on an iPad's: the time window as a menu.
                        timeWindowPicker
                            .pickerStyle(.menu)
                    }
                }
            }
        }
        // Editing happens on the grid: the list offers none, and a wider window brings it back.
        if !showsList {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.editing {
                    Menu {
                        ForEach(model.addableKinds) { kind in
                            Button(kind.title, systemImage: kind.symbol) {
                                add(kind)
                            }
                            .accessibilityIdentifier("dashboard.add.\(kind.rawValue)")
                        }
                    } label: {
                        Label(String(localized: "Add Widget", bundle: #bundle), systemImage: "plus")
                    }
                    .help(Text("Add Widget", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.addWidget")
                    Button {
                        model.endEditing()
                    } label: {
                        Text("Done", bundle: #bundle, comment: "The button that ends the Dashboard's edit mode.")
                            .toolbarLabelPadding()
                    }
                    .buttonStyle(.glassProminent)
                    .help(Text("Finish editing the widgets", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.done")
                } else {
                    Button {
                        model.startEditing()
                    } label: {
                        Text("Edit", bundle: #bundle, comment: "The button that starts the Dashboard's edit mode.")
                            .toolbarLabelPadding()
                    }
                    .help(Text("Add, remove, move, resize and set up the widgets", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.edit")
                }
            }
        }
        ChatPanelToolbarItem()
    }

    private var environmentPicker: some View {
        Picker(String(localized: "Environment", bundle: #bundle), selection: environmentBinding) {
            ForEach(model.project.deploymentEnvironments) { environment in
                Text(verbatim: environment.name)
                    .tag(environment.name)
            }
        }
    }

    private var timeWindowPicker: some View {
        Picker(String(localized: "Time Window", bundle: #bundle), selection: windowBinding) {
            ForEach(TimeWindow.allCases) { window in
                Text(window.title).tag(window)
            }
        }
        .help(Text("Time window of the service widgets", bundle: #bundle))
        .accessibilityIdentifier("dashboard.timeWindow")
    }

    private var environmentBinding: Binding<String> {
        Binding {
            model.environment?.name ?? ""
        } set: { name in
            model.setEnvironment(name)
        }
    }

    private var windowBinding: Binding<TimeWindow> {
        Binding {
            model.window
        } set: { window in
            model.setWindow(window)
        }
    }

    // MARK: Grid

    private func grid(metrics: DashboardGridMetrics) -> some View {
        let state = model.grid(metrics: metrics)
        let context = model.context
        return DashboardGridLayout {
            if let placeholder = state.placeholder {
                // The cells where the moved or resized widget will land.
                CardShape.card
                    .stroke(.accent, lineWidth: 2)
                    .dashboardFrame(.cells(placeholder))
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
            ForEach(state.items, id: \.slot) { item in
                let floats = state.floating?.slot == item.slot
                card(item, context: context)
                    // The widget that follows the pointer hides the widgets under it.
                    .background {
                        if floats {
                            CardShape.card
                                .fill(.canvas)
                        }
                    }
                    .dashboardFrame(floats ? .floating(state.floating?.frame ?? .zero) : .cells(item.cells))
                    .zIndex(floats ? 2 : 0)
                    // A widget without position shows once the rows it needs are known.
                    .opacity(item.isMeasured ? 1 : 0)
            }
        }
    }

    private func card(_ item: DashboardItem, context: DashboardContext) -> some View {
        let slot = item.slot
        let editing = model.editing
        // The steps that change something, offered to VoiceOver; none while a drag is in progress.
        let steps = editing ? model.steps(of: slot) : []
        return DashboardWidgetCard(
            widget: item.widget, editing: editing, identifier: slot.identifier,
            settingsShown: settingsBinding(slot),
            remove: { model.remove(slot) },
            measured: { model.measured(slot, height: $0) },
            measuredSmallest: { model.measuredSmallest(slot, size: $0) },
            settings: { DashboardWidgetSettings(model: model, slot: slot) }
        ) {
            widgetContent(item.widget, context)
        }
        .overlay(alignment: .bottomTrailing) {
            if editing {
                DashboardResizeHandle()
                    .gesture(dragGesture(slot, .resize))
                    .accessibilityActions {
                        ForEach(steps.filter { DashboardStep.sizes.contains($0) }) { step in
                            Button(step.title) { perform(step, on: slot) }
                        }
                    }
                    .accessibilityIdentifier("dashboard.widget.resize.\(slot.identifier)")
            }
        }
        .gesture(dragGesture(slot, .move), isEnabled: editing)
        .contextMenu {
            if editing {
                DashboardWidgetMenu(model: model, slot: slot)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DashboardContent.title(of: item.widget))
        .accessibilityValue(editing ? Self.position(item.cells) : Text(verbatim: ""))
        .accessibilityActions {
            if editing {
                ForEach(steps) { step in
                    Button(step.title) { perform(step, on: slot) }
                }
                Button(String(localized: "Widget Settings", bundle: #bundle)) {
                    model.settingsSlot = slot
                }
                Button(String(localized: "Remove Widget", bundle: #bundle)) {
                    model.remove(slot)
                }
            }
        }
        .accessibilityIdentifier("dashboard.widget.\(slot.identifier)")
    }

    /// Where a widget is and how large, for VoiceOver in edit mode, counted from 1.
    private static func position(_ cells: DashboardCells) -> Text {
        let (column, row, width, height) = (cells.column + 1, cells.row + 1, cells.width, cells.height)
        return Text("Column \(column), row \(row), ^[\(width) column](inflect: true) wide, ^[\(height) row](inflect: true) tall", bundle: #bundle)
    }

    private func settingsBinding(_ slot: DashboardSlot) -> Binding<Bool> {
        Binding {
            model.settingsSlot == slot
        } set: { shown in
            if shown {
                model.settingsSlot = slot
            } else if model.settingsSlot == slot {
                model.settingsSlot = nil
            }
        }
    }

    /// A step of the keyboard or VoiceOver: there is no pointer to follow, so the widgets move to
    /// their new places with AZDesign's `layout` motion.
    private func perform(_ step: DashboardStep, on slot: DashboardSlot) {
        withMotion(.layout) {
            model.step(slot, step)
        }
    }

    // MARK: Edits

    /// The drag that moves a widget, or resizes it by its handle: the widget follows the pointer
    /// from the place it had, and releasing it applies the arrangement.
    private func dragGesture(_ slot: DashboardSlot, _ kind: DashboardDrag.Kind) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DashboardSpace.visibleArea))
            .onChanged { value in
                model.dragChanged(slot, kind, start: value.startLocation, location: value.location,
                                  scrollOffset: scroll.metrics.offset)
            }
            .onEnded { value in
                model.dragEnded(slot, kind, location: value.location)
            }
    }

    /// `Add Widget`: the widget gets the rows its content needs at the cell size of this window.
    private func add(_ kind: DashboardWidgetKind) {
        let metrics = model.metrics
        let widget = DashboardWidget(kind: kind)
        let height = DashboardWidgetCard<WidgetContent>.neededHeight(
            of: widget, width: metrics.length(DashboardGrid.halfWidth), content: widgetContent(widget, model.context)
        )
        model.add(kind, rows: metrics.cells(holding: height))
    }

    /// Scrolls the Dashboard while a widget is moved or resized with the pointer near the top or
    /// the bottom edge of the visible area, until the drag ends.
    private func scrollWhileDragging() async {
        guard model.drag != nil else { return }
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            let elapsed = now - last
            last = now
            guard let drag = model.drag else { return }
            let metrics = scroll.metrics
            let velocity = DashboardAutoScroll.velocity(pointer: drag.location.y, visibleHeight: metrics.visibleHeight)
            guard velocity != 0 else { continue }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let target = min(max(metrics.offset + velocity * seconds, 0), max(metrics.contentHeight - metrics.visibleHeight, 0))
            if abs(target - metrics.offset) >= 0.5 {
                scrollPosition.scrollTo(y: target)
            }
        }
    }
}

/// How far the widget area of a Dashboard is scrolled. A reference, so that reading it during a
/// drag does not make the Dashboard draw again at each scroll.
final class DashboardScroll {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var visibleHeight: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    var metrics = Metrics()
}

/// A widget of the one-per-row list.
private struct DashboardListRow {
    var slot: DashboardSlot
    var widget: DashboardWidget
}

/// A widget's content in the one-per-row list, laid out at the card's width. Only content that can't
/// be that narrow, such as the Tickets counts, which never truncate, scrolls sideways inside the card,
/// as the grid decides it (docs/ui/dashboard.md › Content): text that can truncate doesn't scroll.
private struct ListCardContent<Content: View>: View {
    /// The room the card gives its content.
    let available: CGFloat
    @ViewBuilder let content: Content

    /// The narrowest the content can be.
    @State private var smallest: CGFloat = 0

    var body: some View {
        Group {
            if smallest > available + 0.5 {
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                }
            } else {
                content
            }
        }
        .frame(width: available, alignment: .leading)
        .background {
            SmallestWidth {
                content
            }
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                smallest = width
            }
        }
    }
}

/// Sizes its view at the narrowest it can be.
nonisolated private struct SmallestWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: 0, height: nil)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: 0, height: nil))
    }
}

// MARK: Steps

extension DashboardStep {
    /// The name of the step in the widget's menu, its settings and VoiceOver's actions.
    var title: String {
        switch self {
        case .moveLeft: String(localized: "Move Left", bundle: #bundle)
        case .moveRight: String(localized: "Move Right", bundle: #bundle)
        case .moveUp: String(localized: "Move Up", bundle: #bundle)
        case .moveDown: String(localized: "Move Down", bundle: #bundle)
        case .wider: String(localized: "Make Wider", bundle: #bundle)
        case .narrower: String(localized: "Make Narrower", bundle: #bundle)
        case .taller: String(localized: "Make Taller", bundle: #bundle)
        case .shorter: String(localized: "Make Shorter", bundle: #bundle)
        }
    }

    var symbol: String {
        switch self {
        case .moveLeft: "arrow.left"
        case .moveRight: "arrow.right"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .wider: "arrow.left.and.line.vertical.and.arrow.right"
        case .narrower: "arrow.right.and.line.vertical.and.arrow.left"
        case .taller: "arrow.up.and.line.horizontal.and.arrow.down"
        case .shorter: "arrow.down.and.line.horizontal.and.arrow.up"
        }
    }
}

/// The context menu of a widget in edit mode: its moves and sizes one cell at a time, its settings and
/// Remove (docs/ui/dashboard.md › Edit mode).
private struct DashboardWidgetMenu: View {
    let model: DashboardModel
    let slot: DashboardSlot

    var body: some View {
        ForEach(DashboardStep.moves) { step in
            stepButton(step)
        }
        Divider()
        ForEach(DashboardStep.sizes) { step in
            stepButton(step)
        }
        Divider()
        Button(String(localized: "Widget Settings…", bundle: #bundle), systemImage: "slider.horizontal.3") {
            model.settingsSlot = slot
        }
        .accessibilityIdentifier("dashboard.widgetMenu.settings")
        Button(String(localized: "Remove Widget", bundle: #bundle), systemImage: "minus.circle", role: .destructive) {
            model.remove(slot)
        }
        .accessibilityIdentifier("dashboard.widgetMenu.remove")
    }

    private func stepButton(_ step: DashboardStep) -> some View {
        Button(step.title, systemImage: step.symbol) {
            withMotion(.layout) {
                model.step(slot, step)
            }
        }
        .disabled(!model.canStep(slot, step))
        .accessibilityIdentifier("dashboard.widgetMenu.\(step.rawValue)")
    }
}

// MARK: Widget

/// One widget: its title row, with the remove and settings buttons in edit mode, over its content,
/// which scrolls inside the widget when it does not fit (docs/ui/dashboard.md › Content, Widgets,
/// Edit mode).
struct DashboardWidgetCard<Content: View>: View {
    let widget: DashboardWidget
    let editing: Bool
    /// The qualifier of its controls' identifiers.
    let identifier: String
    /// Whether its settings popover is open.
    @Binding var settingsShown: Bool
    let remove: () -> Void
    /// Receives the height the widget needs at its width for its title row, its content and its
    /// padding.
    let measured: (CGFloat) -> Void
    /// Receives the size of the title row at full width in edit mode, with the padding: the
    /// smallest size of the widget.
    let measuredSmallest: (CGSize) -> Void
    /// The content of its settings popover.
    let settings: () -> DashboardWidgetSettings
    @ViewBuilder let content: Content

    /// The space between the title row and the content.
    static var spacing: CGFloat { 8 }

    @State private var titleHeight: CGFloat?
    @State private var contentHeight: CGFloat?

    private var neededHeight: CGFloat? {
        guard let titleHeight, let contentHeight else { return nil }
        return 2 * DashboardGridMetrics.padding + titleHeight + Self.spacing + contentHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            DashboardWidgetTitleRow(widget: widget, editing: editing, identifier: identifier,
                                    settingsShown: $settingsShown, remove: remove, settings: settings)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { titleHeight = $0 }
            DashboardWidgetScroll(measured: { contentHeight = $0 }) {
                Self.sized(content, kind: widget.kind)
            }
            // In edit mode a drag starts anywhere in the widget: its content takes no click and
            // no scroll.
            .allowsHitTesting(!editing)
        }
        .padding(DashboardGridMetrics.padding)
        // With a minimum as well as a maximum, the frame has the size of the widget's cells also
        // when the title row and the padding need more, and what does not fit is cut: nothing is
        // drawn outside a widget.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(.surface, in: CardShape.card)
        .clipShape(CardShape.card)
        .contentShape(CardShape.card)
        .background {
            if editing {
                // The title row at full width, which gives the smallest size of the widget.
                DashboardWidgetTitleRow(widget: widget, editing: true)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        measuredSmallest(CGSize(width: size.width + 2 * DashboardGridMetrics.padding,
                                                height: size.height + 2 * DashboardGridMetrics.padding))
                    }
            }
        }
        .onChange(of: neededHeight, initial: true) { _, height in
            if let height {
                measured(height)
            }
        }
    }

    /// The content keeps the height it needs at the width it gets, so that it scrolls when the
    /// widget is lower; only the map and the chart fill the widget.
    @ViewBuilder static func sized(_ content: Content, kind: DashboardWidgetKind) -> some View {
        if kind.fillsWidget {
            content
        } else {
            content
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The height a widget needs at a width for its title row, its content and its padding, for a
    /// widget that is not in the list yet: `Add Widget` gives it the rows that hold it.
    static func neededHeight(of widget: DashboardWidget, width: CGFloat, content: Content) -> CGFloat {
        let view = VStack(alignment: .leading, spacing: spacing) {
            DashboardWidgetTitleRow(widget: widget, editing: true)
            sized(content, kind: widget.kind)
        }
        .padding(DashboardGridMetrics.padding)
        .frame(width: width)
        return NSHostingView(rootView: view).fittingSize.height
    }
}

/// The title row of a widget: its title and, in edit mode, the remove button at its start and the
/// settings button at its end (docs/ui/dashboard.md › Edit mode). Without `settingsShown`, as when it
/// is only measured, the settings button opens nothing.
private struct DashboardWidgetTitleRow: View {
    let widget: DashboardWidget
    let editing: Bool
    /// The qualifier of its buttons' identifiers.
    var identifier = ""
    var settingsShown: Binding<Bool>?
    var remove: () -> Void = {}
    var settings: (() -> DashboardWidgetSettings)?

    var body: some View {
        ZStack(alignment: .leading) {
            // The row is as high without its buttons as with them, so the rows a widget needs
            // are the same in and out of edit mode.
            Image(systemName: "minus.circle.fill")
                .hidden()
            Image(systemName: "slider.horizontal.3")
                .hidden()
            HStack(spacing: 6) {
                if editing {
                    Button(action: remove) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.danger)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Remove Widget", bundle: #bundle))
                    .accessibilityLabel(Text("Remove Widget", bundle: #bundle))
                    .accessibilityIdentifier("dashboard.widget.remove.\(identifier)")
                }
                Text(verbatim: DashboardContent.title(of: widget))
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if editing {
                    settingsButton
                }
            }
        }
    }

    @ViewBuilder private var settingsButton: some View {
        let button = Button {
            settingsShown?.wrappedValue = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.textSecondary)
        }
        .buttonStyle(.plain)
        .help(Text("Widget Settings", bundle: #bundle))
        .accessibilityLabel(Text("Widget Settings", bundle: #bundle))
        .accessibilityIdentifier("dashboard.widget.settings.\(identifier)")
        if let settingsShown, let settings {
            button
                .popover(isPresented: settingsShown, arrowEdge: .bottom) {
                    settings()
                }
        } else {
            button
        }
    }
}

/// The settings popover of a widget: each change applies at once (docs/ui/dashboard.md › Settings),
/// and its position and size change one cell at a time, the keyboard's way to move and resize it
/// (docs/ui/dashboard.md › Edit mode).
struct DashboardWidgetSettings: View {
    let model: DashboardModel
    let slot: DashboardSlot

    @State private var title = ""
    /// The stored title the field last took: the field applies only a text the user changed.
    @State private var shownTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if let widget = model.widget(slot) {
                form(widget)
            }
        }
        .onAppear {
            let stored = model.widget(slot)?.title ?? ""
            title = stored
            shownTitle = stored
        }
        .onChange(of: model.widget(slot)?.title ?? "") { _, stored in
            // A title changed elsewhere replaces the text unless the user changed it.
            if title == shownTitle {
                title = stored
            }
            shownTitle = stored
        }
        .onDisappear(perform: commitTitle)
    }

    private func form(_ widget: DashboardWidget) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Title", bundle: #bundle)
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "Title", bundle: #bundle), text: $title, prompt: Text(widget.kind.title))
                        .labelsHidden()
                        .frame(width: 220)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, isFocused in
                            if !isFocused {
                                commitTitle()
                            }
                        }
                        .accessibilityIdentifier("dashboard.settings.title")
                    if DashboardContent.title(from: title) == nil {
                        Text("Enter a title of at most \(DashboardWidget.titleLimit) characters.", bundle: #bundle)
                            .font(.caption)
                            .foregroundStyle(.danger)
                            .accessibilityIdentifier("dashboard.settings.titleError")
                    }
                }
            }
            switch widget.kind {
            case .project:
                GridRow {
                    Text("Fields", bundle: #bundle)
                    CheckboxGroup(Array(DashboardProjectField.allCases), isChecked: { widget.fields.contains($0) }, keepsOneChecked: true,
                                  label: \.title, identifier: { "dashboard.settings.field.\($0.rawValue)" }) { field in
                        model.update(slot) { $0.fields = DashboardEdits.flipping(field, in: $0.fields) }
                    }
                }
            case .tickets:
                GridRow {
                    Text("Statuses", bundle: #bundle)
                    CheckboxGroup(Array(TicketStatus.allCases), isChecked: { widget.statuses.contains($0) }, keepsOneChecked: true,
                                  label: \.title, identifier: { "dashboard.settings.status.\($0.rawValue)" }) { status in
                        model.update(slot) { $0.statuses = DashboardEdits.flipping(status, in: $0.statuses) }
                    }
                }
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    // A click flips the newest value, so that each of several quick clicks applies.
                    Toggle(String(localized: "Include sub projects", bundle: #bundle),
                           isOn: Binding(get: { widget.includeSubprojects },
                                         set: { _ in model.update(slot) { $0.includeSubprojects.toggle() } }))
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("dashboard.settings.includeSubprojects")
                }
            case .recentBuilds, .busiestCalls, .failedRequests:
                GridRow {
                    Text("Number", bundle: #bundle)
                    countStepper(widget)
                }
            case .instances, .serviceGraph, .requestsPerMinute, .recentChats, .cost:
                // The Title setting only.
                EmptyView()
            }
            if let cells = model.cells(of: slot) {
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Position", bundle: #bundle)
                    positionControls(cells)
                }
                GridRow {
                    Text("Width", bundle: #bundle)
                    sizeStepper(label: String(localized: "Width", bundle: #bundle),
                                value: Text("^[\(cells.width) column](inflect: true)", bundle: #bundle),
                                increment: .wider, decrement: .narrower, identifier: "dashboard.settings.width")
                }
                GridRow {
                    Text("Height", bundle: #bundle)
                    sizeStepper(label: String(localized: "Height", bundle: #bundle),
                                value: Text("^[\(cells.height) row](inflect: true)", bundle: #bundle),
                                increment: .taller, decrement: .shorter, identifier: "dashboard.settings.height")
                }
            }
        }
        .padding(16)
    }

    /// The number, then the stepper of the `Number` setting, 1 to 20; each click steps from the
    /// newest number, so that each of several quick clicks applies.
    private func countStepper(_ widget: DashboardWidget) -> some View {
        let count = DashboardContent.rowLimit(of: widget)
        let range = DashboardWidget.countRange
        return HStack(spacing: 6) {
            Text(count, format: .number)
                .monospacedDigit()
                .accessibilityHidden(true)
            Stepper(String(localized: "Number", bundle: #bundle),
                    onIncrement: count < range.upperBound ? { model.update(slot) { $0.count = DashboardEdits.steppingCount(of: $0, by: 1) } } : nil,
                    onDecrement: count > range.lowerBound ? { model.update(slot) { $0.count = DashboardEdits.steppingCount(of: $0, by: -1) } } : nil)
                .labelsHidden()
                .accessibilityValue(Text(count, format: .number))
                .accessibilityIdentifier("dashboard.settings.count")
        }
    }

    /// The cell of the widget's top-left corner, counted from 1, then a button for each move.
    private func positionControls(_ cells: DashboardCells) -> some View {
        HStack(spacing: 8) {
            Text("Column \(cells.column + 1), row \(cells.row + 1)", bundle: #bundle)
                .monospacedDigit()
            ControlGroup {
                ForEach(DashboardStep.moves) { step in
                    Button(step.title, systemImage: step.symbol) {
                        perform(step)
                    }
                    .help(step.title)
                    .disabled(!model.canStep(slot, step))
                    .accessibilityIdentifier("dashboard.settings.\(step.rawValue)")
                }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
        }
    }

    /// The size in cells, then a stepper that adds or takes away one.
    private func sizeStepper(label: String, value: Text, increment: DashboardStep, decrement: DashboardStep,
                             identifier: String) -> some View {
        HStack(spacing: 6) {
            value
                .monospacedDigit()
                .accessibilityHidden(true)
            Stepper(label,
                    onIncrement: model.canStep(slot, increment) ? { perform(increment) } : nil,
                    onDecrement: model.canStep(slot, decrement) ? { perform(decrement) } : nil)
                .labelsHidden()
                .accessibilityValue(value)
                .accessibilityIdentifier(identifier)
        }
    }

    /// A step: the widgets move to their new places with AZDesign's `layout` motion.
    private func perform(_ step: DashboardStep) {
        withMotion(.layout) {
            model.step(slot, step)
        }
    }

    /// The Title applies on Return, when the field loses the focus and when the popover closes,
    /// when the user changed its text.
    private func commitTitle() {
        guard title != shownTitle, let trimmed = DashboardContent.title(from: title) else { return }
        shownTitle = title
        guard let widget = model.widget(slot), trimmed != widget.title else { return }
        model.update(slot) { $0.title = trimmed }
    }
}

// MARK: Project widget

/// A Project widget: the fields checked in its settings, in this order: the name in a large font,
/// the identifier, the type and the folder (docs/ui/dashboard.md › Widgets).
public struct DashboardProjectWidget: View {
    let widget: DashboardWidget
    let project: Project

    public init(widget: DashboardWidget, context: DashboardContext) {
        self.widget = widget
        self.project = context.project
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(DashboardContent.fields(of: widget)) { field in
                switch field {
                case .name:
                    Text(verbatim: project.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                case .identifier:
                    Text(verbatim: project.id)
                        .monospaced()
                        .foregroundStyle(.textSecondary)
                case .type:
                    Text("Type: \(project.kind.title)", bundle: #bundle)
                        .foregroundStyle(.textPrimary)
                case .folder:
                    Text(verbatim: project.path)
                        .font(.callout)
                        .monospaced()
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard.project.\(widget.id.uuidString)")
    }
}

// MARK: Previews

/// The Dashboard alone has only the Project widget's content; the tools draw the rest in the app.
private struct PreviewWidget: View {
    let widget: DashboardWidget
    let context: DashboardContext

    var body: some View {
        if widget.kind == .project {
            DashboardProjectWidget(widget: widget, context: context)
        } else {
            Text(verbatim: widget.kind.title)
                .foregroundStyle(.textSecondary)
        }
    }
}

/// A Dashboard of a sample project, kept in memory.
private func previewDashboard(_ project: Project, editing: Bool = false, saved: [DashboardWidget]? = nil, failure: String? = nil,
                              tools: Set<ToolKind> = Set(ToolKind.allCases)) -> some View {
    let store = SampleDashboardStore(saved.map { [project.id: $0] } ?? [:], failures: failure.map { [project.id: $0] } ?? [:])
    return DashboardRootView(model: DashboardModel(project: project, store: store, tools: tools, editing: editing)) {
        PreviewWidget(widget: $0, context: $1)
    }
    .environment(\.availableTools, tools)
}

/// The settings popover of a widget of the Orders sample, as it shows in edit mode on a 1240-point
/// window.
private func previewSettings(_ kind: DashboardWidgetKind) -> some View {
    let model = DashboardModel(project: Project.samples[0], store: SampleDashboardStore(), editing: true)
    model.areaWidth = 1160
    let slot = DashboardSlot.slots(of: model.widgets)[model.widgets.firstIndex { $0.kind == kind } ?? 0]
    return DashboardWidgetSettings(model: model, slot: slot)
}

#Preview("Orders", traits: .appChrome, .fixedLayout(width: 1240, height: 820)) {
    previewDashboard(Project.samples[0])
}

#Preview("Orders, Dark", traits: .appChrome, .fixedLayout(width: 1240, height: 820)) {
    previewDashboard(Project.samples[0])
        .preferredColorScheme(.dark)
}

#Preview("Editing, Dark", traits: .appChrome, .fixedLayout(width: 1240, height: 820)) {
    previewDashboard(Project.samples[0], editing: true)
        .preferredColorScheme(.dark)
}

#Preview("Default List", traits: .appChrome, .fixedLayout(width: 1000, height: 640)) {
    previewDashboard(Project.samples[3])
}

#Preview("No Widgets", traits: .appChrome, .fixedLayout(width: 1000, height: 640)) {
    previewDashboard(Project.samples[0], saved: [])
}

#Preview("Unavailable Tools", traits: .appChrome, .fixedLayout(width: 1000, height: 640)) {
    previewDashboard(Project.samples[0], tools: [.dashboard, .tickets])
}

#Preview("Change Failed", traits: .appChrome, .fixedLayout(width: 1000, height: 640)) {
    previewDashboard(Project.samples[3], editing: true,
                     failure: "Couldn't write /Users/example/Developer/Gateway/.hephaestus/project.yml: permission denied.")
}

#Preview("Editing, Largest Text", traits: .largestText, .fixedLayout(width: 1240, height: 820)) {
    previewDashboard(Project.samples[0], editing: true)
}

#Preview("List, iPad", traits: .padLayout, .fixedLayout(width: 760, height: 900)) {
    previewDashboard(Project.samples[0])
}

#Preview("List, Largest Text", traits: .padLayout, .largestText, .fixedLayout(width: 760, height: 900)) {
    previewDashboard(Project.samples[0])
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    previewDashboard(Project.samples[0])
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    previewDashboard(Project.samples[0])
        .preferredColorScheme(.dark)
}

#Preview("Settings, Project", traits: .appChrome) {
    previewSettings(.project)
}

#Preview("Settings, Tickets", traits: .appChrome) {
    previewSettings(.tickets)
}

#Preview("Settings, Recent Builds, Dark", traits: .appChrome) {
    previewSettings(.recentBuilds)
        .preferredColorScheme(.dark)
}

#Preview("Settings, Largest Text", traits: .largestText) {
    previewSettings(.busiestCalls)
}
