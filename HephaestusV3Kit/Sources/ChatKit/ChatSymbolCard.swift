import AppKit
import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// Claude's request to choose an SF Symbol (docs/ui/chat.md › Symbol card): the suggestions as a grid of icons, the
/// recommended one starred and preselected, a search over every symbol of the Mac, "Answer another way", Skip and
/// Submit.
struct SymbolCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    let catalogs: PickerCatalogAccess
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    /// The chosen symbol; nil for "Answer another way".
    @State private var choice: String?
    @State private var otherText = ""
    @State private var query = ""
    @State private var catalog: SFSymbolCatalog?
    @State private var gridHeight: CGFloat = 40
    @State private var isSending = false

    static let cell: CGFloat = 36
    static let spacing: CGFloat = 4
    /// Four rows show; more scroll inside the grid.
    static let maxGridHeight = 4 * cell + 3 * spacing

    init(request: PickerItem, projectID: Project.ID?, catalogs: PickerCatalogAccess, compact: Bool = false, allowsShortcut: Bool = true,
         answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.catalogs = catalogs
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        // The recommended symbol is chosen when the card appears.
        _choice = State(initialValue: request.recommended.value)
    }

    private var suggestions: [String] { request.suggestions.map(\.value) }

    /// The suggestions, then the search's results; the suggestions alone while the field is empty.
    private var names: [String] {
        suggestions + (catalog?.search(query, excluding: Set(suggestions)) ?? [])
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut,
                         canSubmit: Self.canSubmit(choice: choice, other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) },
                         submit: { send(Self.answer(request: request, choice: choice, other: otherText)) }) {
            TextField(String(localized: "Search symbols", bundle: #bundle), text: $query,
                      prompt: Text("Search symbols", bundle: #bundle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.symbol.search")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: Self.spacing)], spacing: Self.spacing) {
                    ForEach(names, id: \.self) { name in
                        cell(name)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gridHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(gridHeight, Self.cell), Self.maxGridHeight))
            HStack(spacing: 6) {
                if let choice {
                    Text(verbatim: choice)
                        .foregroundStyle(.textPrimary)
                    if choice == request.recommended.value {
                        RecommendedTag()
                    }
                }
            }
            .frame(minHeight: 18)
            .accessibilityIdentifier("chat.symbol.selected")
            OtherAnswerRow(isSelected: choice == nil, text: $otherText, identifier: "chat.symbol") { choice = nil }
        }
        .task {
            catalog = await catalogs.symbols()
        }
    }

    private func cell(_ name: String) -> some View {
        let isSelected = choice == name
        let available = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        return Button {
            choice = name
        } label: {
            Image(systemName: available ? name : "questionmark.square.dashed")
                .font(.title3)
                .foregroundStyle(.textPrimary)
                .frame(width: Self.cell, height: Self.cell)
                .pickerSelection(isSelected)
                .overlay(alignment: .topTrailing) {
                    if name == request.recommended.value { RecommendedStar() }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chat.symbol.cell.\(name)")
    }

    private func send(_ text: String) {
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }

    /// `![](sf:<name>)` for a chosen symbol, else the field's text, trimmed.
    static func answer(request: PickerItem, choice: String?, other: String) -> String {
        choice.map(request.marker) ?? other.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canSubmit(choice: String?, other: String) -> Bool {
        choice != nil || !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview("Symbol Card, Waiting", traits: .appChrome, .fixedLayout(width: 560, height: 460)) {
    SymbolCard(request: .preview(.symbol), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
}

#Preview("Symbol Card, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 460)) {
    SymbolCard(request: .preview(.symbol), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Symbol Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 700)) {
    SymbolCard(request: .preview(.symbol), projectID: nil, catalogs: .samples, compact: true) { _ in true }
        .padding()
}
