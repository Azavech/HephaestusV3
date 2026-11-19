import AZDesign
import ChatData
import SwiftUI
import TextFormats
import TextViews
import ToolsFoundation

/// Claude's picker request waiting for the user's answer, over the composer (docs/ui/chat.md › Picker cards): the
/// card of its kind. A chat has one request waiting at most, so it never shows with the questions card.
struct PickerCard: View {
    let request: PickerItem
    /// The conversation's project: its ids link, its files open, its sounds play.
    let projectID: Project.ID?
    let catalogs: PickerCatalogAccess
    /// Tighter, for the side panel and the iPhone layout.
    var compact = false
    /// ⌘Return answers; off while a permission card, which takes it, shows.
    var allowsShortcut = true
    /// Stores the answer; false when it wasn't taken.
    let answer: (String) async -> Bool

    var body: some View {
        switch request.kind {
        case .symbol:
            SymbolCard(request: request, projectID: projectID, catalogs: catalogs, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        case .color:
            ColorCard(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        case .sound:
            SoundCard(request: request, projectID: projectID, catalogs: catalogs, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        case .shortcut:
            ShortcutCard(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        case .font:
            FontCard(request: request, projectID: projectID, catalogs: catalogs, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        case .animation:
            AnimationCard(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut, answer: answer)
        }
    }
}

extension PickerKind {
    /// The card's title: `Symbol`, `Color`…
    var cardTitle: String {
        switch self {
        case .symbol: String(localized: "Symbol", bundle: #bundle, comment: "The title of Claude's request to choose an SF Symbol")
        case .color: String(localized: "Color", bundle: #bundle, comment: "The title of Claude's request to choose a color")
        case .sound: String(localized: "Sound", bundle: #bundle, comment: "The title of Claude's request to choose a sound")
        case .shortcut: String(localized: "Shortcut", bundle: #bundle, comment: "The title of Claude's request to choose a keyboard shortcut")
        case .font: String(localized: "Font", bundle: #bundle, comment: "The title of Claude's request to choose a font")
        case .animation: String(localized: "Animation", bundle: #bundle, comment: "The title of Claude's request to choose an animation")
        }
    }

    /// The SF Symbol of the transcript's card.
    var cardSymbol: String {
        switch self {
        case .symbol: "square.grid.3x3"
        case .color: "paintpalette"
        case .sound: "speaker.wave.2"
        case .shortcut: "command"
        case .font: "textformat"
        case .animation: "point.forward.to.point.capsulepath"
        }
    }
}

/// The frame every picker card shares: the header with Minimize, the question, the card's own rows, then Skip and
/// Submit; minimized, one line with the title.
struct PickerCardChrome<Content: View, Leading: View>: View {
    let request: PickerItem
    let projectID: Project.ID?
    let compact: Bool
    let allowsShortcut: Bool
    let canSubmit: Bool
    let isSending: Bool
    let skip: () -> Void
    let submit: () -> Void
    @ViewBuilder let content: () -> Content
    /// What sits at the leading end of Skip and Submit: the animation card's Play All.
    @ViewBuilder let leading: () -> Leading

    @State private var isMinimized = false
    /// The question and the rows' height, which the card takes up to its maximum, then scrolls.
    @State private var contentHeight: CGFloat = 160
    @Environment(\.projectDirectory) private var directory

    private var identifier: String { "chat.\(request.kind.rawValue)" }

    var body: some View {
        Group {
            if isMinimized {
                Button {
                    isMinimized = false
                } label: {
                    HStack {
                        Text(verbatim: request.kind.cardTitle)
                            .font(.headline)
                            .foregroundStyle(.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up")
                            .foregroundStyle(.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show the Request", bundle: #bundle, comment: "Opens a minimized picker card"))
                .accessibilityIdentifier("\(identifier).expand")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(verbatim: request.kind.cardTitle)
                            .font(.headline)
                            .foregroundStyle(.textPrimary)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("\(identifier).header")
                        Spacer(minLength: 8)
                        Button(String(localized: "Minimize", bundle: #bundle, comment: "Folds the questions card into one line"), systemImage: "chevron.down") {
                            isMinimized = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("\(identifier).minimize")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            MarkdownView(request.question, projects: Set(directory.projects.map(\.id)),
                                         root: projectID.flatMap { directory.project($0)?.path })
                                .foregroundStyle(.textPrimary)
                                .accessibilityIdentifier("\(identifier).text")
                            content()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Short of room over the composer, it shrinks to about two lines (docs/ui/chat.md › Over the composer).
                    .frame(minHeight: min(contentHeight, scrollingCardMinimum), idealHeight: min(contentHeight, compact ? 340 : 460),
                           maxHeight: min(contentHeight, compact ? 340 : 460))
                    HStack {
                        leading()
                        Spacer()
                        Button(String(localized: "Skip", bundle: #bundle, comment: "Skips one of Claude's questions"), action: skip)
                            .disabled(isSending)
                            .accessibilityIdentifier("\(identifier).skip")
                        Button(String(localized: "Submit", bundle: #bundle, comment: "Sends the answers to Claude's questions"), action: submit)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(allowsShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
                            .disabled(isSending || !canSubmit)
                            .help(String(localized: "Answer (⌘↩)", bundle: #bundle))
                            .accessibilityIdentifier("\(identifier).submit")
                    }
                }
            }
        }
        .padding(12)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(Color.accent.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension PickerCardChrome where Leading == EmptyView {
    init(request: PickerItem, projectID: Project.ID?, compact: Bool, allowsShortcut: Bool, canSubmit: Bool, isSending: Bool,
         skip: @escaping () -> Void, submit: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(request: request, projectID: projectID, compact: compact, allowsShortcut: allowsShortcut, canSubmit: canSubmit,
                  isSending: isSending, skip: skip, submit: submit, content: content, leading: { EmptyView() })
    }
}

/// "Answer another way": its own radio button and a field of one to six lines; typing in it, or a click on its
/// button or label, chooses it.
struct OtherAnswerRow: View {
    let isSelected: Bool
    @Binding var text: String
    let identifier: String
    let select: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: select) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accent : Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Answer another way", bundle: #bundle))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).other")
            TextField(String(localized: "Answer another way", bundle: #bundle), text: $text,
                      prompt: Text("Answer another way", bundle: #bundle), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onChange(of: text) {
                    if !text.isEmpty { select() }
                }
                .accessibilityIdentifier("\(identifier).other.field")
        }
    }
}

/// The star of the recommended suggestion, at a cell's top trailing corner.
struct RecommendedStar: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 8))
            .foregroundStyle(.accent)
            .padding(2)
            .accessibilityLabel(String(localized: "Recommended", bundle: #bundle, comment: "Marks the option Claude recommends"))
    }
}

extension View {
    /// A selected cell or row: `accent` at 20 % behind it and a 1.5 pt `accent` outline, so that its content keeps
    /// its own colors.
    func pickerSelection(_ isSelected: Bool) -> some View {
        background(isSelected ? Color.accent.opacity(0.2) : .clear, in: CardShape(minimum: 6))
            .overlay {
                if isSelected {
                    CardShape(minimum: 6).stroke(Color.accent, lineWidth: 1.5)
                }
            }
    }
}

/// Claude's picker request in the transcript: its title, the question, one line per suggestion with its marker
/// drawn, the recommended one tagged, then the answer or "Not answered yet".
struct PickerSummary: View {
    let request: PickerItem
    var projectID: Project.ID?

    @Environment(\.projectDirectory) private var directory

    var body: some View {
        let projects = Set(directory.projects.map(\.id))
        let root = projectID.flatMap { directory.project($0)?.path }
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: request.kind.cardTitle)
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
            } icon: {
                Image(systemName: request.kind.cardSymbol)
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            MarkdownView(request.question, projects: projects, root: root, keepsLineBreaks: false)
                .foregroundStyle(.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(request.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    HStack(spacing: 6) {
                        MarkerText(request.line(suggestion), root: root)
                            .foregroundStyle(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if suggestion == request.recommended {
                            RecommendedTag()
                        }
                    }
                    .font(.callout)
                }
            }
            Group {
                if let answer = request.answer {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Answer:", bundle: #bundle, comment: "Before the user's answer to Claude's picker request")
                        MarkerText(answer, projects: projects, root: root)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.textPrimary)
                } else {
                    Text("Not answered yet", bundle: #bundle)
                        .foregroundStyle(.textSecondary)
                }
            }
            .font(.callout)
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(Color.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.picker.\(request.requestID)")
    }
}

// MARK: - Previews

extension PickerItem {
    static func preview(_ kind: PickerKind) -> PickerItem {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        switch kind {
        case .symbol:
            return PickerItem(kind: .symbol, id: "preview.symbol", created: date, question: "Which icon should the **filter** button use?",
                              suggestions: ["line.3.horizontal.decrease.circle", "line.3.horizontal.decrease", "slider.horizontal.3", "camera.filters"].map { PickerSuggestion($0) },
                              recommended: PickerSuggestion("line.3.horizontal.decrease.circle"))
        case .color:
            return PickerItem(kind: .color, id: "preview.color", created: date, question: "Which background should the ticket card use?",
                              suggestions: [PickerSuggestion("#FFFFFF", dark: "#1C1C1E"), PickerSuggestion("systemBackground", dark: "secondarySystemBackground"),
                                            PickerSuggestion("#F2F2F7", dark: "#2C2C2E")],
                              recommended: PickerSuggestion("#FFFFFF", dark: "#1C1C1E"), lightAndDark: true)
        case .sound:
            return PickerItem(kind: .sound, id: "preview.sound", created: date, question: "Which sound should the app play when a message arrives?",
                              suggestions: ["macOS/Glass.aiff", "macOS/Ping.aiff", "macOS/Pop.aiff"].map { PickerSuggestion($0) },
                              recommended: PickerSuggestion("macOS/Glass.aiff"))
        case .shortcut:
            return PickerItem(kind: .shortcut, id: "preview.shortcut", created: date, question: "Which shortcut should open the ticket filter?",
                              suggestions: ["⇧⌘F", "⌥⌘F", "⌃⌘F", "⌘L"].map { PickerSuggestion($0) }, recommended: PickerSuggestion("⇧⌘F"),
                              inUse: [ShortcutInUse(shortcut: "⌘N", command: "New Ticket"), ShortcutInUse(shortcut: "⌘L", command: "Copy Link")])
        case .font:
            return PickerItem(kind: .font, id: "preview.font", created: date, question: "Which font should the ticket titles use?",
                              suggestions: ["System Rounded/Semibold/17", "System Serif/Regular/17", ".headline"].map { PickerSuggestion($0) },
                              recommended: PickerSuggestion("System Rounded/Semibold/17"),
                              sample: "Replace the status filter with a Filter by Status menu")
        case .animation:
            return PickerItem(kind: .animation, id: "preview.animation", created: date, question: "How should the sidebar slide in?",
                              suggestions: [".snappy", ".spring(duration: 0.4, bounce: 0.2)", ".easeInOut(duration: 0.25)"].map { PickerSuggestion($0) },
                              recommended: PickerSuggestion(".snappy"))
        }
    }
}

#Preview("Picker Requests in the Transcript", traits: .appChrome, .fixedLayout(width: 560, height: 900)) {
    var color = PickerItem.preview(.color)
    color.answer = "Light ![](color:#FFFFFF), Dark ![](color:#2C2C2E)"
    var shortcut = PickerItem.preview(.shortcut)
    shortcut.answer = "![](shortcut:⌥⌘F)"
    return ScrollView {
        VStack(spacing: 12) {
            PickerSummary(request: .preview(.symbol))
            PickerSummary(request: color)
            PickerSummary(request: shortcut)
        }
        .padding()
    }
}

#Preview("Picker Requests in the Transcript, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 700)) {
    var font = PickerItem.preview(.font)
    font.answer = "![](font:System Serif/Regular/17)"
    return VStack(spacing: 12) {
        PickerSummary(request: font)
        PickerSummary(request: .preview(.animation))
    }
    .padding()
    .preferredColorScheme(.dark)
}
