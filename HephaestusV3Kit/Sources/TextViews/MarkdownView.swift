import AppKit
import AZDesign
import AZDesignCode
import SwiftUI
import TextFormats
import ToolsFoundation

/// Markdown as the tools show it (docs/text.md): a ticket's description or comment, Claude's reply. Headings,
/// paragraphs, quotes, lists with task boxes, highlighted code blocks with a Copy button, tables and rules.
/// Ticket and bundle ids of the loaded projects become links that open them in their Tickets window; other
/// links open in the browser. V2's markers draw as symbols, swatches, key caps, fonts, sounds and animations
/// (docs/text.md › Markers). The text can be selected.
public struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let options: MarkdownRenderOptions

    /// `markdown` rendered with the identifiers of `projects` linked. With `keepsLineBreaks`, each line break is
    /// kept, as people type them in tickets; without, Markdown's own rules join a paragraph's lines. Relative
    /// links open the files of the project at `root`. With `highlightsMentions`, as a comment, `@Claude` shows in
    /// the accent color.
    public init(_ markdown: String, projects: Set<Project.ID> = [], root: String? = nil, keepsLineBreaks: Bool = true,
                highlightsMentions: Bool = false) {
        options = MarkdownRenderOptions(projectRootPath: root, projectIdentifiers: projects, softBreaksAsLineBreaks: keepsLineBreaks,
                                        markers: Self.markerOptions, highlightsMentions: highlightsMentions)
        blocks = MarkdownBlockRenderer.render(markdown, options: options)
    }

    /// Every Markdown view reads the six kinds of markers; a symbol marker draws when this Mac has the symbol.
    public static let markerOptions = MarkdownMarkerOptions(isSymbolAvailable: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })

    public var body: some View {
        MarkdownBlocks(blocks: blocks)
            .textSelection(.enabled)
            .modifier(MarkdownLinkActions(root: options.projectRootPath, options: options))
    }
}

/// What a click on a link of rendered text does: an id opens its ticket or bundle in its Tickets window; a sound
/// marker's ▶ plays the sound of the view's project, a failure shown in the alert "Play Sound failed"; a relative
/// link opens the project's file in its default app; other links open in the browser.
struct MarkdownLinkActions: ViewModifier {
    let root: String?
    let options: MarkdownRenderOptions

    @Environment(\.openRoute) private var openRoute
    @Environment(\.playSound) private var playSound
    @State private var soundFailure: String?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let id = MarkdownItemIDs.id(fromHref: url.absoluteString) {
                    // `ORD-142` and the bundle `ORD-B2` belong to the project `ORD`.
                    let project = id.split(separator: "-").first.map(String.init) ?? ""
                    openRoute(.tool(.tickets, project: project, focus: id))
                    return .handled
                }
                if let name = SoundLinks.name(from: url) {
                    Task {
                        guard let playSound else {
                            soundFailure = String(localized: "This window can't play sounds.", bundle: #bundle)
                            return
                        }
                        soundFailure = await playSound(name, projectRoot: root)
                    }
                    return .handled
                }
                // A relative link names a file of the project: it opens in its default app.
                if MarkdownLinks.scheme(of: url.absoluteString) == nil, let root,
                   let reference = MarkdownLinks.resolve(url.absoluteString, options: options) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(reference.path))
                    return .handled
                }
                return .systemAction
            })
            .alert(String(localized: "Play Sound failed", bundle: #bundle, comment: "A sound of a marker couldn't be played"),
                   isPresented: Binding(get: { soundFailure != nil }, set: { if !$0 { soundFailure = nil } })) {
                Button(String(localized: "OK", bundle: #bundle)) { soundFailure = nil }
            } message: {
                Text(verbatim: soundFailure ?? "")
            }
    }
}

/// Blocks, one under the other, 10 pt apart.
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch block {
        case let .heading(level, _, content):
            MarkdownInlines.text(content, dark: colorScheme == .dark)
                .font(MarkdownInlines.headingFont(level))
                .foregroundStyle(.textPrimary)
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            MarkdownInlines.text(content, dark: colorScheme == .dark)
                .fixedSize(horizontal: false, vertical: true)
        case .blockQuote(let blocks):
            MarkdownBlocks(blocks: blocks)
                .foregroundStyle(.textSecondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.divider)
                        .frame(width: 3)
                }
        case .list(let list):
            VStack(alignment: .leading, spacing: list.tight ? 4 : 10) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checkbox {
                                Image(systemName: checked ? "checkmark.square" : "square")
                                    .accessibilityLabel(checked ? Text("Done", bundle: #bundle) : Text("Not done", bundle: #bundle))
                            } else if list.ordered {
                                Text(verbatim: "\(list.start + index).")
                                    .monospacedDigit()
                            } else {
                                Text(verbatim: "•")
                            }
                        }
                        .foregroundStyle(.textSecondary)
                        .frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocks(blocks: item.blocks)
                    }
                }
            }
        case let .codeBlock(_, label, code, tokens):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let label {
                        Text(verbatim: label)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer()
                    Button(String(localized: "Copy", bundle: #bundle, comment: "Copies a code block"), systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(String(localized: "Copy", bundle: #bundle, comment: "Copies a code block"))
                    .accessibilityIdentifier("markdown.code.copy")
                }
                ScrollView(.horizontal) {
                    Text(MarkdownInlines.highlighted(code, tokens: tokens))
                        .font(.code(.callout))
                        .fixedSize()
                }
                .scrollIndicators(.automatic)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(6)), isUniform: true))
        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                            MarkdownInlines.text(cell, dark: colorScheme == .dark).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                MarkdownInlines.text(cell, dark: colorScheme == .dark)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case .thematicBreak:
            Divider()
        case .rawHTML(let source):
            Text(verbatim: source)
                .font(.code(.callout))
                .foregroundStyle(.textSecondary)
        }
    }
}

/// Inline Markdown as an attributed string, and code with its highlight colors.
enum MarkdownInlines {
    static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { $0 += piece($1) }
    }

    /// The inlines as one text: an attributed string, joined with the images of the symbol and color markers
    /// when there are some (docs/text.md › Markers). `dark` draws the swatches for the dark appearance.
    static func text(_ inlines: [MarkdownInline], dark: Bool) -> Text {
        guard inlines.contains(where: drawsImage) else { return Text(attributed(inlines)) }
        var pieces: [Text] = []
        var pending = AttributedString()
        func flush() {
            guard !pending.characters.isEmpty else { return }
            pieces.append(Text(pending))
            pending = AttributedString()
        }
        func walk(_ inlines: [MarkdownInline], intent: InlinePresentationIntent) {
            for inline in inlines {
                switch inline {
                case .emphasis(let content): walk(content, intent: intent.union(.emphasized))
                case .strong(let content): walk(content, intent: intent.union(.stronglyEmphasized))
                case .strikethrough(let content): walk(content, intent: intent.union(.strikethrough))
                case .symbol(let name):
                    flush()
                    pieces.append(styled(Text(Image(systemName: name)), intent: intent))
                    pending += adding(intent, to: AttributedString(" " + name))
                case .color(let value):
                    flush()
                    if let swatch = ColorSwatches.swatchImage(value, dark: dark) {
                        pieces.append(Text(Image(nsImage: swatch)).baselineOffset(-1))
                    }
                    pending += adding(intent, to: AttributedString(" " + value))
                default:
                    pending += intent.isEmpty ? piece(inline) : adding(intent, to: piece(inline))
                }
            }
        }
        walk(inlines, intent: [])
        flush()
        return pieces.dropFirst().reduce(pieces.first ?? Text(verbatim: "")) { joined, next in
            Text("\(joined)\(next)", bundle: #bundle, comment: "Two pieces of a line of Markdown, one after the other: never translated")
        }
    }

    /// Whether an inline, or one inside it, draws an image: a symbol or a color marker.
    private static func drawsImage(_ inline: MarkdownInline) -> Bool {
        switch inline {
        case .symbol, .color: true
        case .emphasis(let content), .strong(let content), .strikethrough(let content): content.contains(where: drawsImage)
        default: false
        }
    }

    private static func styled(_ text: Text, intent: InlinePresentationIntent) -> Text {
        var text = text
        if intent.contains(.stronglyEmphasized) { text = text.bold() }
        if intent.contains(.emphasized) { text = text.italic() }
        if intent.contains(.strikethrough) { text = text.strikethrough() }
        return text
    }

    private static func piece(_ inline: MarkdownInline) -> AttributedString {
        switch inline {
        case .text(let text):
            return AttributedString(text)
        case .code(let code):
            var piece = AttributedString(code)
            piece.inlinePresentationIntent = .code
            piece.font = .code(.body)
            return piece
        case .emphasis(let content):
            return adding(.emphasized, to: attributed(content))
        case .strong(let content):
            return adding(.stronglyEmphasized, to: attributed(content))
        case .strikethrough(let content):
            return adding(.strikethrough, to: attributed(content))
        case let .link(destination, _, content):
            var piece = attributed(content)
            piece.link = URL(string: destination)
            return piece
        case let .image(source, alt, _):
            var piece = AttributedString(alt.isEmpty ? String(localized: "Image", bundle: #bundle) : alt)
            if case .remote(let url) = source { piece.link = URL(string: url) }
            piece.foregroundColor = .textSecondary
            return piece
        case let .itemID(id, code):
            var piece = AttributedString(id)
            piece.link = URL(string: MarkdownItemIDs.href(for: id))
            if code { piece.font = .code(.body) }
            return piece
        case .mention(let text):
            // In the accent color, in the font around it; not a link (docs/ui/tickets.md › Mentioning Claude).
            var piece = AttributedString(text)
            piece.foregroundColor = .accent
            return piece
        case .softBreak:
            return AttributedString(" ")
        case .lineBreak:
            return AttributedString("\n")
        case .symbol(let name):
            // Drawn with its image by `text(_:dark:)`; its name alone here.
            return AttributedString(name)
        case .color(let value):
            return AttributedString(value)
        case .sound(let name):
            // ▶ plays the sound (docs/text.md › Markers › Sounds).
            var play = AttributedString("▶")
            play.link = SoundLinks.href(for: name)
            return play + AttributedString(" " + name)
        case .shortcut(_, let keyCaps):
            // Key caps as text: each on the sunken surface, a thin space apart.
            var caps = AttributedString()
            for (index, cap) in keyCaps.enumerated() {
                if index > 0 { caps += AttributedString("\u{2009}") }
                var key = AttributedString("\u{2009}" + cap + "\u{2009}")
                key.backgroundColor = .surfaceSunken
                key.font = .body.weight(.medium)
                caps += key
            }
            return caps
        case let .font(value, label):
            var text = AttributedString(label)
            if let notation = FontNotation(value), let font = FontFaces.markerFont(notation) { text.font = font }
            return text
        case .animation(let expression):
            var text = AttributedString(expression)
            text.font = .code(.body)
            return text
        }
    }

    private static func adding(_ intent: InlinePresentationIntent, to text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return text
    }

    /// Code with each token's color, weight and slant; text no token covers stays plain.
    static func highlighted(_ code: String, tokens: [HighlightToken]) -> AttributedString {
        var text = AttributedString(code)
        let utf16 = code.utf16
        for token in tokens {
            guard token.range.lowerBound >= 0, token.range.upperBound <= utf16.count,
                  let lower = String.Index(utf16.index(utf16.startIndex, offsetBy: token.range.lowerBound), within: code),
                  let upper = String.Index(utf16.index(utf16.startIndex, offsetBy: token.range.upperBound), within: code),
                  let start = AttributedString.Index(lower, within: text), let end = AttributedString.Index(upper, within: text) else { continue }
            text[start..<end].foregroundColor = color(of: token.kind)
            let style = token.kind.style
            if style.weight != .regular || style.italic {
                var intent: InlinePresentationIntent = []
                if style.weight != .regular { intent.insert(.stronglyEmphasized) }
                if style.italic { intent.insert(.emphasized) }
                text[start..<end].inlinePresentationIntent = intent
            }
        }
        return text
    }

    /// The token kinds in AZDesign's semantic colors, after Dracula's code colors (docs/ui/tickets.md ›
    /// Markdown); the original hex values stay in `TokenKind.style` for reference.
    static func color(of kind: TokenKind) -> Color {
        switch kind {
        case .keyword, .interpolation: .accentSecondary
        case .type, .property, .heading, .link: .info
        case .builtin, .number: .accent
        case .function, .code: .success
        case .string, .escape: .warning
        case .comment, .docComment: .textSecondary
        case .attribute, .directive: .danger
        case .variable, .emphasis, .strong: .textPrimary
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

#Preview("Markdown", traits: .appChrome, .fixedLayout(width: 560, height: 700)) {
    ScrollView {
        MarkdownView("""
            ## Problem
            Retries in **orders-api** have *no* backoff; see ORD-139 and `ORD-137`.

            - [x] Cap the retries at three
            - [ ] Add jitter
            1. First
            2. Second

            > The provider timeout is 4 s.

            ```swift
            let delay = min(base * pow(2, attempt), 4.0) // seconds
            ```

            | Retry | Delay |
            | --- | ---: |
            | 1 | 0.5 s |
            | 2 | 1 s |

            ---
            See https://example.com/runbook.
            """, projects: ["ORD"])
        .padding()
    }
}

#Preview("Markdown, Dark", traits: .appChrome, .fixedLayout(width: 560, height: 400)) {
    MarkdownView("""
        ### Change
        Use `Retry.backoff` in **PaymentsClient**:

        ```go
        for i := 0; i < 3; i++ { // retry
            time.Sleep(time.Duration(1<<i) * 100 * time.Millisecond)
        }
        ```
        """, projects: ["ORD"])
    .padding()
    .preferredColorScheme(.dark)
}
