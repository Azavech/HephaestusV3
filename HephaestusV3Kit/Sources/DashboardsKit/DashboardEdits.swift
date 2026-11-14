import Foundation
import ToolsFoundation

// From HephaestusV2's Sources/HephaestusUI/Dashboard/DashboardView.swift: the slots, the arrangement
// and the changes of edit mode, unchanged but for the settings of Hephaestus V3's widgets and the steps of the
// keyboard and VoiceOver, which ask for cells as a drag does.

/// What the widgets show from their settings (docs/ui/dashboard.md › Widgets, Settings).
enum DashboardContent {
    /// The widget's `Title` setting, trimmed; nil when it is empty and the title of the kind shows.
    static func customTitle(of widget: DashboardWidget) -> String? {
        let title = widget.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// The widget's title: its `Title` setting, or the title of its kind when that is empty.
    static func title(of widget: DashboardWidget) -> String {
        customTitle(of: widget) ?? widget.kind.title
    }

    /// The fields a Project widget shows, in the order of its settings whatever the stored order.
    static func fields(of widget: DashboardWidget) -> [DashboardProjectField] {
        DashboardProjectField.allCases.filter(widget.fields.contains)
    }

    /// The rows a widget with a `Number` setting lists, brought back within 1–20.
    static func rowLimit(of widget: DashboardWidget) -> Int {
        min(max(widget.count, DashboardWidget.countRange.lowerBound), DashboardWidget.countRange.upperBound)
    }

    /// The title a `Title` field's text sets: the text trimmed; nil when that is longer than 100
    /// characters or holds a line break, and nothing applies.
    static func title(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= DashboardWidget.titleLimit, !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }
}

/// A widget of a list: its id and its rank among the widgets that have that id, which only a file
/// edited by hand repeats (docs/ui/dashboard.md › Saving). It identifies the widget's view and the
/// widget an edit applies to.
nonisolated struct DashboardSlot: Hashable {
    var id: UUID
    var occurrence: Int

    static func slots(of widgets: [DashboardWidget]) -> [DashboardSlot] {
        var seen: [UUID: Int] = [:]
        return widgets.map { widget in
            let occurrence = seen[widget.id, default: 0]
            seen[widget.id] = occurrence + 1
            return DashboardSlot(id: widget.id, occurrence: occurrence)
        }
    }

    func index(in widgets: [DashboardWidget]) -> Int? {
        Self.slots(of: widgets).firstIndex(of: self)
    }

    /// The qualifier of the widget's accessibility identifiers: its id, followed by its rank from 2
    /// for a widget whose id an earlier widget of the list has too (docs/ui/dashboard.md ›
    /// Accessibility).
    var identifier: String {
        occurrence == 0 ? id.uuidString : "\(id.uuidString)-\(occurrence + 1)"
    }
}

/// What the place of the widgets depends on besides their list: whether the service widgets show,
/// and the rows the content of each widget needs at the cell size of the window, which are known
/// once the widget has been laid out (docs/ui/dashboard.md › Placement, Lists without positions).
nonisolated struct DashboardArrangement: Equatable {
    var graphEnabled = false
    var rows: [DashboardSlot: Int] = [:]

    /// The cells of each widget of a list, nil for a hidden service widget. A widget without
    /// position whose rows are not known yet counts one row.
    func cells(of widgets: [DashboardWidget]) -> [DashboardCells?] {
        let slots = DashboardSlot.slots(of: widgets)
        return DashboardGrid.layout(of: widgets, graphEnabled: graphEnabled) { rows[slots[$0]] ?? 1 }
    }

    /// The list with `cells` as the stored position and size of each shown widget. A hidden service
    /// widget keeps its own, and a widget without position whose rows are not known yet stays
    /// without position.
    func storing(_ cells: [DashboardCells?], in widgets: [DashboardWidget]) -> [DashboardWidget] {
        let slots = DashboardSlot.slots(of: widgets)
        var list = widgets
        for (index, cell) in cells.enumerated() where index < list.count {
            guard let cell, list[index].cells != nil || rows[slots[index]] != nil else { continue }
            list[index].cells = cell
        }
        return list
    }
}

/// A step of the keyboard's and VoiceOver's way to move a widget or change its size, one cell at a
/// time, which a drag does with the pointer (docs/ui/dashboard.md › Edit mode).
nonisolated enum DashboardStep: String, CaseIterable, Identifiable, Sendable {
    case moveLeft, moveRight, moveUp, moveDown
    case wider, narrower, taller, shorter

    var id: Self { self }

    /// The steps that move the widget, and those that change its size.
    static let moves: [DashboardStep] = [.moveLeft, .moveRight, .moveUp, .moveDown]
    static let sizes: [DashboardStep] = [.wider, .narrower, .taller, .shorter]
}

/// The changes of edit mode, each a new list made from the newest one; nil when the widget it
/// applies to is no longer in the list (docs/ui/dashboard.md › Edit mode, Settings). A move, a
/// resize, an addition and a removal give each shown widget the position and the size the
/// Dashboard shows once the change is made; a change of settings stores no position.
enum DashboardEdits {
    /// `Add Widget`: the widget is appended with the default settings and a new id, at column 0
    /// under every widget, 12 columns wide and `rows` high, the rows its content needs at the cell
    /// size of the window; then it rises by the placement rule.
    static func appending(_ kind: DashboardWidgetKind, rows: Int, to widgets: [DashboardWidget], arrangement: DashboardArrangement,
                          id: UUID = UUID()) -> [DashboardWidget] {
        let shown = arrangement.cells(of: widgets)
        var list = arrangement.storing(shown, in: widgets)
        var widget = DashboardWidget(id: id, kind: kind)
        widget.cells = DashboardCells(column: 0, row: shown.compactMap { $0?.bottom }.max() ?? 0,
                                      width: DashboardGrid.halfWidth, height: max(rows, 1))
        list.append(widget)
        return arrangement.storing(arrangement.cells(of: list), in: list)
    }

    /// The remove button: the other widgets keep the place the Dashboard shows, and those under
    /// the removed widget rise.
    static func removing(_ slot: DashboardSlot, from widgets: [DashboardWidget], arrangement: DashboardArrangement) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        var list = arrangement.storing(arrangement.cells(of: widgets), in: widgets)
        list.remove(at: index)
        return arrangement.storing(arrangement.cells(of: list), in: list)
    }

    /// A widget moved or resized to `cells`: the placement rule applies to the arrangement the
    /// Dashboard shows, with the widget at these cells and placed before the other widgets that
    /// start on its row. Nil when the arrangement stays as it is.
    static func placing(_ slot: DashboardSlot, at cells: DashboardCells, in widgets: [DashboardWidget],
                        arrangement: DashboardArrangement) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        let shown = arrangement.cells(of: widgets)
        guard shown[index] != nil else { return nil }
        let placed = DashboardGrid.layout(shown, placing: index, at: cells)
        guard placed != shown else { return nil }
        var list = arrangement.storing(placed, in: widgets)
        // The widget the user placed gets its position whatever is known of its rows.
        list[index].cells = placed[index]
        return list
    }

    /// A step of the keyboard or VoiceOver (docs/ui/dashboard.md › Edit mode): the widget asks for the
    /// cells the step gives, as if it were dragged there, and the placement rule applies as when a drag
    /// ends. Nil when the step changes nothing.
    static func stepping(_ slot: DashboardSlot, _ step: DashboardStep, in widgets: [DashboardWidget],
                         arrangement: DashboardArrangement, smallest: DashboardSmallestSize) -> [DashboardWidget]? {
        guard let cells = target(of: slot, step, in: widgets, arrangement: arrangement, smallest: smallest) else { return nil }
        return placing(slot, at: cells, in: widgets, arrangement: arrangement)
    }

    /// The cells a step asks for, from the cells the widget shows; nil when it can't change anything.
    ///
    /// - Left and right: the next column, within the 24 columns.
    /// - Up: the nearest row above from which the widget ends higher, which puts it before the widget
    ///   above it; nothing at row 0.
    /// - Down: the nearest row below from which the widget ends lower, which puts it after the widget
    ///   under it; nothing when no widget is under it.
    /// - Wider, narrower, taller, shorter: one cell more or less, never smaller than `smallest` and
    ///   never past column 24, as the resize handle does.
    static func target(of slot: DashboardSlot, _ step: DashboardStep, in widgets: [DashboardWidget],
                       arrangement: DashboardArrangement, smallest: DashboardSmallestSize) -> DashboardCells? {
        guard let index = slot.index(in: widgets) else { return nil }
        let shown = arrangement.cells(of: widgets)
        guard let start = shown[index] else { return nil }
        /// Whether the cells change the arrangement the way the step asks.
        func applies(_ cells: DashboardCells) -> Bool {
            let placed = DashboardGrid.layout(shown, placing: index, at: cells)
            guard let result = placed[index], placed != shown else { return false }
            switch step {
            case .moveUp: return result.row < start.row
            case .moveDown: return result.row > start.row
            default: return true
            }
        }
        var cells = start
        switch step {
        case .moveLeft, .moveRight:
            cells.column += step == .moveLeft ? -1 : 1
            guard cells.column >= 0, cells.column + cells.width <= DashboardGrid.columns else { return nil }
            return applies(cells) ? cells : nil
        case .moveUp:
            for row in stride(from: start.row - 1, through: 0, by: -1) {
                cells.row = row
                if applies(cells) { return cells }
            }
            return nil
        case .moveDown:
            // Past the lowest widget, the widget is placed last, as it is from the lowest one's bottom.
            let lowest = shown.compactMap { $0?.bottom }.max() ?? start.bottom
            for row in stride(from: start.row + 1, through: lowest, by: 1) {
                cells.row = row
                if applies(cells) { return cells }
            }
            return nil
        case .wider, .narrower, .taller, .shorter:
            guard let resized = resized(start, step, smallest: smallest) else { return nil }
            return applies(resized) ? resized : nil
        }
    }

    /// The cells one cell wider, narrower, taller or shorter, kept within the smallest size and the 24
    /// columns as by the resize handle; nil when that size is the size the widget has.
    static func resized(_ cells: DashboardCells, _ step: DashboardStep, smallest: DashboardSmallestSize) -> DashboardCells? {
        let most = max(DashboardGrid.columns - cells.column, 1)
        let width = { (columns: Int) in min(max(columns, min(smallest.columns, most)), most) }
        let height = { (rows: Int) in min(max(rows, smallest.rows), DashboardGrid.rowLimit) }
        var result = cells
        switch step {
        case .wider: result.width = width(cells.width + 1)
        case .narrower: result.width = width(cells.width - 1)
        case .taller: result.height = height(cells.height + 1)
        case .shorter: result.height = height(cells.height - 1)
        case .moveLeft, .moveRight, .moveUp, .moveDown: return nil
        }
        switch step {
        case .wider: return result.width > cells.width ? result : nil
        case .narrower: return result.width < cells.width ? result : nil
        case .taller: return result.height > cells.height ? result : nil
        default: return result.height < cells.height ? result : nil
        }
    }

    /// A change of a widget's settings.
    static func updating(_ slot: DashboardSlot, in widgets: [DashboardWidget],
                         _ update: (inout DashboardWidget) -> Void) -> [DashboardWidget]? {
        guard let index = slot.index(in: widgets) else { return nil }
        var list = widgets
        update(&list[index])
        return list
    }

    /// A checkbox of a group checked or unchecked: the checked values, in the order of the
    /// settings; the last checked value stays checked.
    static func toggling<Value: CaseIterable & Hashable>(_ value: Value, on: Bool, in checked: [Value]) -> [Value] {
        var values = Set(checked)
        if on {
            values.insert(value)
        } else if values != [value] {
            values.remove(value)
        }
        return Value.allCases.filter(values.contains)
    }

    /// Whether the box of a value is the only checked box of its group, which cannot be unchecked.
    static func isLastChecked<Value: Hashable>(_ value: Value, in checked: [Value]) -> Bool {
        Set(checked) == [value]
    }

    /// A click on a checkbox: its value is checked when the newest list does not have it, unchecked
    /// when it does, so that each of several quick clicks applies.
    static func flipping<Value: CaseIterable & Hashable>(_ value: Value, in checked: [Value]) -> [Value] {
        toggling(value, on: !checked.contains(value), in: checked)
    }

    /// A click on the stepper of `Number`: one more or one less than the newest number, within
    /// 1–20.
    static func steppingCount(of widget: DashboardWidget, by step: Int) -> Int {
        let range = DashboardWidget.countRange
        return min(max(DashboardContent.rowLimit(of: widget) + step, range.lowerBound), range.upperBound)
    }
}
