import AppKit
import AZDesign
import ChatData
import SwiftUI
import TextFormats
import TextViews
import ToolsFoundation

/// What the font card's list has chosen (docs/ui/chat.md › Font card).
enum FontChoice: Hashable {
    /// A suggestion, by its place.
    case suggestion(Int)
    /// A family of the search's results.
    case family(String)
    /// A text style of the search's results.
    case textStyle(FontTextStyle)
    /// "Answer another way".
    case other
}

/// Claude's request to choose a font (docs/ui/chat.md › Font card): the suggestions drawn in their fonts, the
/// recommended one starred and preselected, a search over every font, a Weight menu and a Size field, the sample in
/// the chosen font, "Answer another way", Skip and Submit.
struct FontCard: View {
    let request: PickerItem
    let projectID: Project.ID?
    let catalogs: PickerCatalogAccess
    var compact = false
    var allowsShortcut = true
    let answer: (String) async -> Bool

    @State private var choice: FontChoice
    @State private var weight = "Regular"
    /// The family the weight was chosen in, for the nearest weight.
    @State private var weightFamily = "System"
    @State private var size = "17"
    @State private var otherText = ""
    @State private var query = ""
    @State private var catalog: FontCatalog?
    @State private var listHeight: CGFloat = 40
    @State private var isSending = false

    static let maxListHeight: CGFloat = 8 * 26
    /// The size the rows draw their fonts at: the card's text.
    private var rowSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize }

    init(request: PickerItem, projectID: Project.ID?, catalogs: PickerCatalogAccess, compact: Bool = false, allowsShortcut: Bool = true,
         answer: @escaping (String) async -> Bool) {
        self.request = request
        self.projectID = projectID
        self.catalogs = catalogs
        self.compact = compact
        self.allowsShortcut = allowsShortcut
        self.answer = answer
        let index = request.suggestions.firstIndex(of: request.recommended) ?? 0
        _choice = State(initialValue: .suggestion(index))
        if case .family(let family, let weight, let size)? = FontNotation(request.recommended.value) {
            _weight = State(initialValue: weight)
            _weightFamily = State(initialValue: family)
            _size = State(initialValue: size)
        }
    }

    /// The family chosen: a family suggestion's or a result's; nil for a text style and "Answer another way".
    private var family: String? {
        Self.family(of: choice, suggestions: request.suggestions.map(\.value))
    }

    var body: some View {
        PickerCardChrome(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut,
                         canSubmit: Self.canSubmit(choice: choice, suggestions: request.suggestions.map(\.value), size: size, other: otherText), isSending: isSending,
                         skip: { send(PickerItem.skipped) },
                         submit: { send(Self.answer(choice: choice, suggestions: request.suggestions.map(\.value), weight: weight, size: size, other: otherText)) }) {
            TextField(String(localized: "Search fonts", bundle: #bundle), text: $query, prompt: Text("Search fonts", bundle: #bundle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.font.search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(request.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        suggestionRow(suggestion.value, index: index)
                    }
                    ForEach(catalog?.search(query, excludingSuggestions: request.suggestions.map(\.value)) ?? [], id: \.self) { result in
                        resultRow(result)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 26), Self.maxListHeight))
            weightAndSize
            preview
            OtherAnswerRow(isSelected: choice == .other, text: $otherText, identifier: "chat.font") { choice = .other }
        }
        .task {
            let read = await catalogs.fonts()
            // The project's faces draw in every view once read.
            for family in read?.families ?? [] {
                for face in family.faces {
                    if let file = face.file { FontFaces.register(family: family.name, style: face.name, file: file, postScriptName: face.postScriptName) }
                }
            }
            catalog = read
        }
    }

    private func suggestionRow(_ suggestion: String, index: Int) -> some View {
        let notation = FontNotation(suggestion)
        let font: Font = switch notation {
        case .textStyle(let style)?: FontFaces.font(style)
        case .family(let family, let weight, _)?: FontFaces.font(family: family, weight: weight, size: rowSize) ?? .body
        case nil: .body
        }
        return row(notation?.label ?? suggestion, font: font, isSelected: choice == .suggestion(index), isRecommended: suggestion == request.recommended.value,
                   identifier: "chat.font.row.\(index)") {
            choice = .suggestion(index)
            if case .family(let family, let weight, let size)? = notation {
                self.weight = weight
                weightFamily = family
                self.size = size
            }
        }
    }

    @ViewBuilder private func resultRow(_ result: FontCatalog.SearchResult) -> some View {
        switch result {
        case .family(let name):
            let face = catalog?.family(named: name).flatMap(FontCatalog.nameFace)
            row(name, font: face.flatMap { FontFaces.font(family: name, weight: $0.name, size: rowSize) } ?? .body,
                isSelected: choice == .family(name), isRecommended: false, identifier: "chat.font.family.\(name)") {
                choose(family: name)
            }
        case .textStyle(let style):
            row(style.notation, font: FontFaces.font(style), isSelected: choice == .textStyle(style), isRecommended: false,
                identifier: "chat.font.style.\(style.rawValue)") {
                choice = .textStyle(style)
            }
        }
    }

    private func row(_ label: String, font: Font, isSelected: Bool, isRecommended: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(font)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isRecommended { RecommendedStar() }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .pickerSelection(isSelected)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// A family of the results keeps the weight when it has one of that name, else takes the nearest one.
    private func choose(family name: String) {
        choice = .family(name)
        guard let catalog, let family = catalog.family(named: name) else { return }
        let value = catalog.face(family: weightFamily, weight: weight)?.weight ?? 0
        if let face = FontCatalog.nearestFace(name: weight, value: value, in: family) {
            weight = face.name
            weightFamily = name
        }
    }

    private var weightAndSize: some View {
        let faces = family.flatMap { catalog?.family(named: $0)?.faces.map(\.name) } ?? []
        let names = faces.contains(weight) ? faces : [weight] + faces
        let disabled = family == nil
        return HStack(spacing: 8) {
            Picker(String(localized: "Weight", bundle: #bundle, comment: "The menu of the font card's weights"), selection: Binding(
                get: { weight },
                set: { weight = $0; weightFamily = family ?? weightFamily }
            )) {
                ForEach(names, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("chat.font.weight")
            Text("Size", bundle: #bundle, comment: "The label of the font card's size field")
                .foregroundStyle(.textPrimary)
            TextField(String(localized: "Size", bundle: #bundle, comment: "The label of the font card's size field"), text: $size)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .accessibilityIdentifier("chat.font.size")
            Text("pt", bundle: #bundle, comment: "After the font card's size: points")
                .foregroundStyle(.textSecondary)
        }
        .disabled(disabled)
    }

    /// The sample in the chosen font; empty for "Answer another way" and a size that isn't one.
    @ViewBuilder private var preview: some View {
        let font: Font? = switch choice {
        case .other: nil
        case .textStyle(let style): FontFaces.font(style)
        case .suggestion(let index):
            switch FontNotation(request.suggestions[index].value) {
            case .textStyle(let style)?: FontFaces.font(style)
            default: family.flatMap { family in sizeValue.flatMap { FontFaces.font(family: family, weight: weight, size: $0) } }
            }
        case .family(let name): sizeValue.flatMap { FontFaces.font(family: name, weight: weight, size: $0) }
        }
        ScrollView {
            Text(verbatim: font == nil ? "" : request.sample ?? "")
                .font(font ?? .body)
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.surfaceSunken, in: CardShape(minimum: 6))
        .accessibilityIdentifier("chat.font.preview")
    }

    private var sizeValue: CGFloat? {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        return FontNotation.isSize(trimmed) ? Double(trimmed).map { CGFloat($0) } : nil
    }

    private func send(_ text: String) {
        isSending = true
        Task {
            _ = await answer(text)
            isSending = false
        }
    }

    /// The family a choice uses: a family suggestion's, or a result's.
    static func family(of choice: FontChoice, suggestions: [String]) -> String? {
        switch choice {
        case .suggestion(let index):
            guard suggestions.indices.contains(index), case .family(let family, _, _)? = FontNotation(suggestions[index]) else { return nil }
            return family
        case .family(let name): return name
        case .textStyle, .other: return nil
        }
    }

    /// `![](font:<family>/<weight>/<size>)` with the menu's weight and the field's size, written `17` or `15.5`;
    /// `![](font:<style>)` for a text style; else the field's text, trimmed.
    static func answer(choice: FontChoice, suggestions: [String], weight: String, size: String, other: String) -> String {
        switch choice {
        case .other:
            return other.trimmingCharacters(in: .whitespacesAndNewlines)
        case .textStyle(let style):
            return "![](font:\(style.notation))"
        case .suggestion(let index):
            if suggestions.indices.contains(index), case .textStyle(let style)? = FontNotation(suggestions[index]) {
                return "![](font:\(style.notation))"
            }
        case .family:
            break
        }
        let family = family(of: choice, suggestions: suggestions) ?? ""
        let written = Double(size.trimmingCharacters(in: .whitespaces)).flatMap(FontNotation.sizeText) ?? size
        return "![](font:\(family)/\(weight)/\(written))"
    }

    /// Disabled for "Answer another way" with an empty field, and for a family whose size field isn't a size.
    static func canSubmit(choice: FontChoice, suggestions: [String], size: String, other: String) -> Bool {
        switch choice {
        case .other: !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .textStyle: true
        case .suggestion, .family: family(of: choice, suggestions: suggestions) == nil || FontNotation.isSize(size.trimmingCharacters(in: .whitespaces))
        }
    }
}

#Preview("Font Card, Waiting", traits: .appChrome, .fixedLayout(width: 560, height: 560)) {
    FontCard(request: .preview(.font), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
}

#Preview("Font Card, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 560)) {
    FontCard(request: .preview(.font), projectID: nil, catalogs: .samples) { _ in true }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Font Card, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 760)) {
    FontCard(request: .preview(.font), projectID: nil, catalogs: .samples, compact: true) { _ in true }
        .padding()
}
