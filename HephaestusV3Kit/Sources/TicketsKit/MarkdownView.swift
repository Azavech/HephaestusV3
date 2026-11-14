import AppKit
import AZDesign
import AZDesignCode
import SwiftUI
import TextFormats
import TicketData
import ToolsFoundation

/// A description or a comment, as Markdown (docs/text.md): headings, paragraphs, quotes, lists with task
/// boxes, highlighted code blocks, tables and rules. Ticket and bundle ids of the loaded projects become links
/// that open them in their Tickets window; other links open in the browser. The text can be selected.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let options: MarkdownRenderOptions

    @Environment(\.openRoute) private var openRoute

    /// `markdown` rendered with the identifiers of `projects` linked. Each line break is kept, as people
    /// type them in tickets. Relative links open the files of the project at `root`.
    init(_ markdown: String, projects: Set<Project.ID> = [], root: String? = nil) {
        options = MarkdownRenderOptions(projectRootPath: root, projectIdentifiers: projects, softBreaksAsLineBreaks: true)
        blocks = MarkdownBlockRenderer.render(markdown, options: options)
    }

    var body: some View {
        MarkdownBlocks(blocks: blocks)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if let id = MarkdownItemIDs.id(fromHref: url.absoluteString) {
                    let project = TicketIDs.parseTicket(id)?.project ?? TicketIDs.parseBundle(id)?.project ?? ""
                    openRoute(.tool(.tickets, project: project, focus: id))
                    return .handled
                }
                // A relative link names a file of the project: it opens in its default app.
                if MarkdownLinks.scheme(of: url.absoluteString) == nil, let root = options.projectRootPath,
                   let reference = MarkdownLinks.resolve(url.absoluteString, options: options) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(reference.path))
                    return .handled
                }
                return .systemAction
            })
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

    var body: some View {
        switch block {
        case let .heading(level, _, content):
            Text(MarkdownInlines.attributed(content))
                .font(MarkdownInlines.headingFont(level))
                .foregroundStyle(.textPrimary)
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            Text(MarkdownInlines.attributed(content))
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
                if let label {
                    Text(verbatim: label)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
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
                            Text(MarkdownInlines.attributed(cell)).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownInlines.attributed(cell))
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
        case .softBreak:
            return AttributedString(" ")
        case .lineBreak:
            return AttributedString("\n")
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
