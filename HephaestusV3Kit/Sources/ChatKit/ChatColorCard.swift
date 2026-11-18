import AppKit
import AZDesign
import ChatData
import SwiftUI
import TextFormats
import TextViews
import ToolsFoundation

/// What the color card holds (docs/ui/chat.md › Color card): one color, or a Light and a Dark row while `Light and
/// dark` is on, and which row a click sets; or "Answer another way".
struct ColorChoice: Equatable {
    enum Row: Hashable { case light, dark }

    /// `Light and dark` is on.
    var isPair: Bool
    /// The card's color while the toggle is off: its hex field's text.
    var single: String
    var light: String
    var dark: String
    /// The row a click sets while the toggle is on.
    var row: Row = .light
    /// "Answer another way" is chosen.
    var choosesOther = false

    /// The recommended suggestion, the toggle as Claude asked.
    init(request: PickerItem) {
        isPair = request.lightAndDark
        single = request.recommended.value
        light = request.recommended.value
        dark = request.recommended.dark ?? request.recommended.value
    }

    /// The text of the row a click sets.
    var current: String {
        get { isPair ? (row == .light ? light : dark) : single }
        set {
            if !isPair { single = newValue } else if row == .light { light = newValue } else { dark = newValue }
        }
    }

    /// A click on a cell: a color sets the card, or the selected row; a pair sets both rows, or the card to its
    /// light color.
    mutating func choose(_ suggestion: PickerSuggestion) {
        choosesOther = false
        if let pairDark = suggestion.dark, isPair {
            light = suggestion.value
            dark = pairDark
        } else {
            current = suggestion.value
        }
    }

    /// The toggle: on gives both rows the card's color and selects Light; off gives the card the Light row's.
    mutating func setPair(_ on: Bool) {
        choosesOther = false
        guard on != isPair else { return }
        if on {
            light = single
            dark = single
            row = .light
        } else {
            single = light
        }
        isPair = on
    }

    /// The cell's outline: its colors are the card's, or the selected row's; a pair's are both rows while the
    /// toggle is on, its light color the card's while it is off.
    func isHighlighted(_ suggestion: PickerSuggestion) -> Bool {
        guard !choosesOther else { return false }
        if let pairDark = suggestion.dark {
            return isPair ? SystemColors.isSame(suggestion.value, light) && SystemColors.isSame(pairDark, dark)
                : SystemColors.isSame(suggestion.value, single)
        }
        return SystemColors.isSame(suggestion.value, current)
    }

    /// Every field shown holds a hex color or a system color name.
    var fieldsAreColors: Bool {
        isPair ? SystemColors.isColor(trim(light)) && SystemColors.isColor(trim(dark)) : SystemColors.isColor(trim(single))
    }

    /// `![](color:<color>)`, `Light ![](color:<light>), Dark ![](color:<dark>)`, a hex color in uppercase; or the
    /// field's text, trimmed.
    func answer(other: String) -> String {
        if choosesOther { return trim(other) }
        if isPair { return PickerItem.pairMarker(light: SystemColors.normalized(trim(light)), dark: SystemColors.normalized(trim(dark))) }
        return "![](color:\(SystemColors.normalized(trim(single))))"
    }

    func canSubmit(other: String) -> Bool {
        choosesOther ? !trim(other).isEmpty : fieldsAreColors
    }

    private func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Claude's request to choose a color (docs/ui/chat.md › Color card): the suggestions and every system color as
/// swatches, the recommended one starred, `Light and dark`, a color well and a hex field per row, "Answer another
/// way", Skip and Submit.
struct ColorCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    @State private var choice: ColorChoice
    @State private var otherText = ""
    @State private var gridHeight: CGFloat = 40
    @State private var isSending = false
    @FocusState private var focusedRow: ColorChoice.Row?

    init(request: PickerItem, projectID: Project.ID?, compact: Bool = false, allowsShortcut: Bool = true, answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        _choice = State(initialValue: ColorChoice(request: request))
    }

    /// The suggestions, then every system color that isn't one.
    private var cells: [PickerSuggestion] {
        let suggested = Set(request.suggestions.filter { !$0.isPair }.map(\.value))
        return request.suggestions + SystemColors.names.filter { !suggested.contains($0) }.map { PickerSuggestion($0) }
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut,
                         canSubmit: choice.canSubmit(other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) }, submit: { send(choice.answer(other: otherText)) }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: SymbolCard.cell, maximum: SymbolCard.cell), spacing: SymbolCard.spacing)],
                          spacing: SymbolCard.spacing) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { index, suggestion in
                        cell(suggestion, index: index)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gridHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(gridHeight, SymbolCard.cell), SymbolCard.maxGridHeight))
            Toggle(String(localized: "Light and dark", bundle: #bundle, comment: "Switches the color card between one color and a light and dark pair"),
                   isOn: Binding(get: { choice.isPair }, set: { choice.setPair($0) }))
                .toggleStyle(.switch)
                .accessibilityIdentifier("chat.color.lightAndDark")
            if choice.isPair {
                colorRow(.light, title: String(localized: "Light", bundle: #bundle, comment: "The color of the light appearance"), text: $choice.light)
                colorRow(.dark, title: String(localized: "Dark", bundle: #bundle, comment: "The color of the dark appearance"), text: $choice.dark)
            } else {
                HStack(spacing: 8) {
                    ColorWell(value: choice.single) { picked in
                        choice.choosesOther = false
                        choice.single = picked
                    }
                    .frame(width: 56, height: 28)
                    .accessibilityIdentifier("chat.color.well")
                    hexField($choice.single, row: nil)
                }
            }
            OtherAnswerRow(isSelected: choice.choosesOther, text: $otherText, identifier: "chat.color") { choice.choosesOther = true }
        }
    }

    private func cell(_ suggestion: PickerSuggestion, index: Int) -> some View {
        let isHighlighted = choice.isHighlighted(suggestion)
        let tooltip = suggestion.dark.map { dark in
            choice.isPair ? String(localized: "Light \(suggestion.value), Dark \(dark)", bundle: #bundle, comment: "A light and dark pair's tooltip")
                : suggestion.value
        } ?? suggestion.value
        return Button {
            choice.choose(suggestion)
        } label: {
            ColorSwatchView(light: suggestion.value, dark: choice.isPair ? suggestion.dark : nil)
                .frame(width: 28, height: 28)
                .frame(width: SymbolCard.cell, height: SymbolCard.cell)
                .pickerSelection(isHighlighted)
                .overlay(alignment: .topTrailing) {
                    if suggestion == request.recommended { RecommendedStar() }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("chat.color.cell.\(index)")
    }

    private func colorRow(_ row: ColorChoice.Row, title: String, text: Binding<String>) -> some View {
        let isSelected = choice.row == row && !choice.choosesOther
        return HStack(spacing: 8) {
            Text(verbatim: title)
                .foregroundStyle(.textPrimary)
                .frame(minWidth: 44, alignment: .leading)
            ColorWell(value: text.wrappedValue) { picked in
                choice.choosesOther = false
                choice.row = row
                text.wrappedValue = picked
            }
            .frame(width: 56, height: 28)
            .accessibilityIdentifier("chat.color.well.\(row == .light ? "light" : "dark")")
            hexField(text, row: row)
        }
        .padding(6)
        .background(isSelected ? Color.accent.opacity(0.15) : .clear, in: CardShape(minimum: 6))
        .contentShape(.rect)
        .onTapGesture {
            choice.choosesOther = false
            choice.row = row
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.color.row.\(row == .light ? "light" : "dark")")
    }

    /// The row's hex color in uppercase, or its system color's name; a hex color is written in uppercase when the
    /// field loses the focus.
    private func hexField(_ text: Binding<String>, row: ColorChoice.Row?) -> some View {
        TextField(String(localized: "Hex Color", bundle: #bundle, comment: "The field of a color's hex value or system name"), text: text,
                  prompt: Text(verbatim: "#RRGGBB"))
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .frame(maxWidth: 260)
            .focused($focusedRow, equals: row ?? .light)
            .onChange(of: focusedRow) { old, _ in
                if old == (row ?? .light) {
                    let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if SystemColors.isHex(trimmed) { text.wrappedValue = trimmed.uppercased() }
                }
                if focusedRow == (row ?? .light) {
                    choice.choosesOther = false
                    if let row { choice.row = row }
                }
            }
            .onChange(of: text.wrappedValue) { choice.choosesOther = false }
            .accessibilityIdentifier(row == nil ? "chat.color.hex" : "chat.color.hex.\(row == .light ? "light" : "dark")")
    }

    private func send(_ text: String) {
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }
}

/// A color's swatch, or a pair's split by the diagonal from its bottom leading corner to its top trailing one, the
/// light color above it; a hairline border.
struct ColorSwatchView: View {
    let light: String
    var dark: String?

    var body: some View {
        ZStack {
            if let dark {
                Rectangle().fill(ColorSwatches.color(dark) ?? .clear)
                UpperTriangle().fill(ColorSwatches.color(light) ?? .clear)
            } else {
                Rectangle().fill(ColorSwatches.color(light) ?? .clear)
            }
        }
        .clipShape(CardShape(minimum: 6))
        .overlay {
            CardShape(minimum: 6).stroke(Color.textSecondary.opacity(0.3), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// The triangle over the diagonal from the bottom leading corner to the top trailing one.
    private nonisolated struct UpperTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

/// The macOS color well in its expanded style: its swatch shows the color, its button opens the color panel,
/// without opacity. A color picked is converted to sRGB and given as `#RRGGBB` in uppercase.
struct ColorWell: NSViewRepresentable {
    let value: String
    let pick: (String) -> Void

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .expanded)
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.pick = pick
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let color = ColorSwatches.nsColor(trimmed), Self.hex(of: well.color) != Self.hex(of: color) || !SystemColors.isHex(trimmed) {
            well.color = color
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pick: pick)
    }

    /// `#RRGGBB` in uppercase of a color, in sRGB.
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    final class Coordinator: NSObject {
        var pick: (String) -> Void

        init(pick: @escaping (String) -> Void) {
            self.pick = pick
        }

        @objc func changed(_ sender: NSColorWell) {
            if let hex = ColorWell.hex(of: sender.color) { pick(hex) }
        }
    }
}

#Preview("Color Card, Waiting", traits: .appChrome, .fixedLayout(width: 560, height: 560)) {
    ColorCard(request: .preview(.color), projectID: nil) { _ in true }
        .padding()
}

#Preview("Color Card, One Color, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 480)) {
    var request = PickerItem.preview(.color)
    request.lightAndDark = false
    request.suggestions = [PickerSuggestion("#FF9500"), PickerSuggestion("systemBlue"), PickerSuggestion("#34C759")]
    request.recommended = PickerSuggestion("systemBlue")
    return ColorCard(request: request, projectID: nil) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Color Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 760)) {
    ColorCard(request: .preview(.color), projectID: nil, compact: true) { _ in true }
        .padding()
}
