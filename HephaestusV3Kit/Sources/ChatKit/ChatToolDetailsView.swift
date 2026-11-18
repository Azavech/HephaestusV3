import AZDesign
import AZDesignCode
import ChatData
import SwiftUI
import TextFormats
import TextViews
import ToolsFoundation

/// A call's row expanded, as V2's tool cards were (docs/ui/chat.md › Tool-call rows): the tool, its input, its
/// result with its images, and the steps of the sub-agent it started.
struct ToolCallDetailsView: View {
    let turnID: ChatTurn.ID
    let details: ChatToolDetails
    let compact: Bool

    /// A result shows its first lines until Show All.
    static let shownLines = 200

    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: details.name)
                    .font(.code(.caption))
                    .foregroundStyle(.textPrimary)
                if let server = details.server {
                    Text("MCP · \(server)", bundle: #bundle, comment: "Tags an MCP tool's call with its server")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.surface, in: .capsule)
                }
            }
            section(String(localized: "Input", bundle: #bundle, comment: "A call's input")) {
                ForEach(Array(details.input.enumerated()), id: \.offset) { _, input in
                    if let title = input.title {
                        Text(verbatim: title)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    MarkdownView(Self.fenced(input.text, language: input.language), keepsLineBreaks: false)
                }
            }
            section(String(localized: "Result", bundle: #bundle, comment: "A call's result")) {
                if let result = details.result {
                    let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
                    let cut = !showsAll && lines.count > Self.shownLines
                    IDLinkedText(text: cut ? lines.prefix(Self.shownLines).joined(separator: "\n") : result)
                        .font(.code(.caption))
                        .accessibilityIdentifier("chat.toolCall.\(turnID).result")
                    if cut {
                        Button(String(localized: "Show All", bundle: #bundle, comment: "Shows a call's whole result")) { showsAll = true }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("chat.toolCall.\(turnID).showAll")
                    }
                    if !details.resultImages.isEmpty {
                        MessageFiles(turnID: turnID, files: details.resultImages, compact: true)
                    }
                } else {
                    Text("No result yet", bundle: #bundle, comment: "A call still waiting for its result")
                        .foregroundStyle(.textSecondary)
                }
            }
            if !details.steps.isEmpty {
                section(String(localized: "Steps", bundle: #bundle, comment: "The work of a sub-agent, in its call's row")) {
                    ForEach(details.steps) { step in
                        ChatStepView(turnID: turnID, block: step, compact: compact)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// `text` as a fenced code block, its fence longer than any run of backticks in it.
    static func fenced(_ text: String, language: String?) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language ?? "")\n\(text)\n\(fence)"
    }
}

/// A step of a sub-agent in its call's row: text, thinking or a call, drawn as the transcript draws them.
struct ChatStepView: View {
    let turnID: ChatTurn.ID
    let block: ChatBlock
    let compact: Bool

    var body: some View {
        // The row of a call holds rows of calls: an erased view breaks the type's recursion.
        AnyView(content)
    }

    @ViewBuilder private var content: some View {
        switch block.content {
        case .text(let text):
            MarkdownView(text, keepsLineBreaks: false)
                .foregroundStyle(.textPrimary)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .call(let call):
            ToolCallRow(turnID: turnID, blockID: block.id, call: call, compact: compact)
        case .notice(let notice):
            NoticeRow(notice: notice)
        default:
            EmptyView()
        }
    }
}

/// Claude's thinking, folded under "Thinking", as V2 showed it; unfolded, its Markdown in `textSecondary`.
struct ThinkingRow: View {
    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownView(text, keepsLineBreaks: false)
                .foregroundStyle(.textSecondary)
                .padding(.top, 4)
        } label: {
            Label {
                Text("Thinking", bundle: #bundle, comment: "Claude's thinking, folded in the transcript")
            } icon: {
                Image(systemName: "brain")
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(.textSecondary)
        }
        .accessibilityIdentifier("chat.thinking")
    }
}

/// Plain text, selectable, whose ticket and bundle ids of the loaded projects are links that open them in their
/// Tickets window, as V2 linked them in results and summaries.
struct IDLinkedText: View {
    let text: String

    @Environment(\.projectDirectory) private var directory
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        // No fixedSize: in the card over the composer, a fixed height made the window's split view take the
        // transcript's whole height.
        Text(attributed)
            .foregroundStyle(.textPrimary)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let id = MarkdownItemIDs.id(fromHref: url.absoluteString) else { return .systemAction }
                openRoute(.tool(.tickets, project: id.split(separator: "-").first.map(String.init) ?? "", focus: id))
                return .handled
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for inline in MarkdownItemIDs.inlines(in: text, projectIdentifiers: Set(directory.projects.map(\.id))) {
            switch inline {
            case .text(let piece):
                result += AttributedString(piece)
            case .itemID(let id, _):
                var link = AttributedString(id)
                link.link = URL(string: MarkdownItemIDs.href(for: id))
                result += link
            default:
                break
            }
        }
        return result
    }
}
