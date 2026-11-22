import AZDesign
import SwiftUI
import TextViews
import ToolsFoundation

// The parts of a conversation, shared by the Chat window and the side panel. They take values and
// closures only: the window's and the panel's models do the work.

/// The turns of a conversation, then Claude at work while a reply is coming.
struct ChatTranscript: View {
    let conversation: ChatConversation
    /// What Claude is doing; nil when it has nothing to do.
    let activity: ChatActivity?
    /// Tighter, for the side panel.
    var compact = false
    /// The user's answer to a change Claude asked to make: allow or not.
    let decide: (ChatApproval.ID, Bool) -> Void
    /// Stops Claude's turn; nil where nothing can be stopped (the samples).
    var stop: (() -> Void)?
    /// The blocks Find found, highlighted.
    var findMatches: Set<ChatBlock.ID> = []
    /// The match Find shows, outlined.
    var currentMatch: ChatBlock.ID?
    /// Leaves out the cards still waiting, which show over the composer: each shows once, then here with its answer.
    var hidesWaitingApprovals = false

    var body: some View {
        let matches = findMatches
        LazyVStack(alignment: .leading, spacing: compact ? 16 : 22) {
            ForEach(conversation.turns) { turn in
                // A turn that didn't change isn't drawn again: the one at work changes at each word Claude writes.
                ChatTurnView(turn: turn, projectID: conversation.projectID, compact: compact, decide: decide, matches: matches,
                             currentMatch: currentMatch, hidesWaitingApprovals: hidesWaitingApprovals)
                    .equatable()
            }
            if let activity {
                ChatAuthorRow(author: .claude, isSample: false) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        ChatActivityText(activity: activity)
                            .foregroundStyle(.textSecondary)
                        if let stop {
                            Button(String(localized: "Stop", bundle: #bundle, comment: "Stops Claude's turn"), systemImage: "stop.circle", action: stop)
                                .buttonStyle(.borderless)
                                .keyboardShortcut(".", modifiers: .command)
                                .help(String(localized: "Stop (⌘.)", bundle: #bundle))
                                .accessibilityIdentifier("chat.stop")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.responding")
            }
        }
    }
}

/// What Claude is doing in a conversation, for the line at its end.
enum ChatActivity: Hashable {
    /// The sample engine reads through the tools.
    case reading
    /// The Claude CLI starts.
    case starting
    /// Claude works on the messages, since the date.
    case working(since: Date)
    /// The CLI compacts the conversation, since the date.
    case compacting(since: Date)
    /// A card waits for the user's answer.
    case waiting
}

/// "Claude is working… 0:12", its time counting while it shows.
struct ChatActivityText: View {
    let activity: ChatActivity

    var body: some View {
        switch activity {
        case .reading:
            Text("Reading…", bundle: #bundle, comment: "Claude reads through the tools while a reply is coming")
        case .starting:
            Text("Starting Claude…", bundle: #bundle)
        case .waiting:
            Text("Waiting for your answer", bundle: #bundle, comment: "A card waits for the user")
        case .working(let since), .compacting(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let elapsed = Duration.seconds(max(0, Int(context.date.timeIntervalSince(since))))
                let time = elapsed.formatted(.time(pattern: .minuteSecond))
                if case .compacting = activity {
                    Text("Compacting the conversation… \(time)", bundle: #bundle, comment: "The time since it began, such as 0:12")
                } else {
                    Text("Claude is working… \(time)", bundle: #bundle, comment: "The time since the turn began, such as 0:12")
                }
            }
        }
    }
}

/// Who speaks, then what they say. No bubbles: a Mac document, as Xcode's assistant shows it.
struct ChatAuthorRow<Content: View>: View {
    let author: ChatTurn.Author
    let isSample: Bool
    /// When the turn began; nil for the activity line.
    var date: Date?
    /// Claude's model and effort, after its name.
    var caption: ChatTurnCaption?
    /// What Copy puts on the pasteboard: the turn's Markdown; nil for no Copy button.
    var copyText: String?
    @ViewBuilder let content: Content

    @ScaledMetric private var badge = 24.0
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: author == .user ? "person.fill" : "sparkle")
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: badge, height: badge)
                .background(color.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Group {
                        if author == .user {
                            Text("You", bundle: #bundle, comment: "The author of the user's messages")
                        } else {
                            Text("Claude", bundle: #bundle)
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    if let caption, let shown = Self.caption(caption) {
                        Text(verbatim: shown)
                            .font(.callout)
                            .foregroundStyle(.textSecondary)
                    }
                    if let date {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                            .help(date.formatted(date: .complete, time: .standard))
                    }
                    if isSample {
                        Text("Sample reply", bundle: #bundle)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                            .help(String(localized: "No model is connected yet: the reply comes from the example's sample engine.", bundle: #bundle))
                    }
                    Spacer(minLength: 0)
                    if let copyText {
                        Button(String(localized: "Copy", bundle: #bundle, comment: "Copies a message's text"), systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyText, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .opacity(isHovered ? 1 : 0)
                        .help(String(localized: "Copy", bundle: #bundle, comment: "Copies a message's text"))
                        .accessibilityIdentifier("chat.turn.copy")
                    }
                }
                content
            }
            Spacer(minLength: 0)
        }
        .onHover { isHovered = $0 }
    }

    private var color: Color {
        author == .user ? .info : .accentSecondary
    }

    /// "(Opus 5.5 · Extra High)", "(Opus 5.5)"; nil without either.
    static func caption(_ caption: ChatTurnCaption) -> String? {
        let parts = [caption.model, caption.effort].compactMap { $0 }
        return parts.isEmpty ? nil : "(" + parts.joined(separator: " · ") + ")"
    }
}

/// One turn: what the user attached, then each block in order.
struct ChatTurnView: View {
    let turn: ChatTurn
    /// The conversation's project, whose folder relative links open from.
    var projectID: Project.ID?
    let compact: Bool
    let decide: (ChatApproval.ID, Bool) -> Void
    /// Find's matches, by block id: highlighted.
    var matches: Set<ChatBlock.ID> = []
    var currentMatch: ChatBlock.ID?
    /// Leaves out the cards still waiting, which show over the composer.
    var hidesWaitingApprovals = false

    @Environment(\.projectDirectory) private var directory

    var body: some View {
        ChatAuthorRow(author: turn.author, isSample: turn.isSample, date: turn.isSample ? nil : turn.date, caption: turn.caption,
                      copyText: copyText) {
            if !turn.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.attachments) { reference in
                        ContextChip(reference: reference, identifier: "chat.attachment.\(turn.id).\(reference.id)")
                    }
                }
            }
            ForEach(hidesWaitingApprovals ? turn.blocks.filter { !$0.isWaitingApproval } : turn.blocks) { block in
                blockView(block)
                    .padding(matches.contains(block.id) ? 4 : 0)
                    .background(matches.contains(block.id) ? Color.highlight : .clear, in: CardShape(minimum: 6))
                    .overlay {
                        if currentMatch == block.id {
                            CardShape(minimum: 6).stroke(Color.accent, lineWidth: 2)
                        }
                    }
                    .id(block.id)
            }
            if !turn.files.isEmpty {
                MessageFiles(turnID: turn.id, files: turn.files, compact: compact)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.turn.\(turn.id)")
    }

    @ViewBuilder private func blockView(_ block: ChatBlock) -> some View {
        switch block.content {
        case .text(let text):
            // Markdown, as V2's bubbles: ids of the loaded projects are links; the user's line breaks stay.
            ChatMarkdown(text: text, projects: Set(directory.projects.map(\.id)), root: directory.project(projectID)?.path,
                         keepsLineBreaks: turn.author == .user)
                .equatable()
                .foregroundStyle(.textPrimary)
        case .call(let call):
            ToolCallRow(turnID: turn.id, blockID: block.id, call: call, compact: compact)
        case .approval(let approval):
            ApprovalCard(approval: approval) { allow in
                decide(approval.id, allow)
            }
        case .notice(let notice):
            NoticeRow(notice: notice)
        case .questions(let set):
            QuestionsSummary(questionSet: set, projectID: projectID)
        case .picker(let request):
            PickerSummary(request: request, projectID: projectID)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .images(let caption, let files):
            VStack(alignment: .leading, spacing: 8) {
                if let caption {
                    MarkdownView(caption, projects: Set(directory.projects.map(\.id)), root: directory.project(projectID)?.path, keepsLineBreaks: false)
                        .foregroundStyle(.textPrimary)
                }
                MessageFiles(turnID: turn.id, files: files, compact: compact)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.images.\(block.id)")
        }
    }

    /// The turn's text, its blocks' Markdown one after the other; nil without text.
    private var copyText: String? {
        let texts = turn.blocks.compactMap { block -> String? in
            if case .text(let text) = block.content { return text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// Claude's Markdown: emphasis, code and links inline, line breaks kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

extension ChatTurnView: Equatable {
    /// `decide` is left out: a view gives every turn the same action, made again at each of its own draws.
    static func == (lhs: ChatTurnView, rhs: ChatTurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.projectID == rhs.projectID && lhs.compact == rhs.compact && lhs.matches == rhs.matches
            && lhs.currentMatch == rhs.currentMatch && lhs.hidesWaitingApprovals == rhs.hidesWaitingApprovals
    }
}

/// A text of a turn as Markdown, parsed again only when the text or what it links changes: the turn at work is drawn
/// again at each word Claude writes, and parsing each of its texts again each time held the main thread.
struct ChatMarkdown: View, Equatable {
    let text: String
    let projects: Set<Project.ID>
    let root: String?
    let keepsLineBreaks: Bool

    var body: some View {
        MarkdownView(text, projects: projects, root: root, keepsLineBreaks: keepsLineBreaks)
    }
}

/// The files a message carried, after its text: images as thumbnails, other files as chips. A click opens the
/// file in Quick Look, which steps through the message's files.
struct MessageFiles: View {
    let turnID: ChatTurn.ID
    let files: [ChatMessageFile]
    let compact: Bool

    @State private var previewed: URL?

    var body: some View {
        FlowStack(spacing: 8) {
            ForEach(files) { file in
                Button {
                    previewed = file.url
                } label: {
                    FileTile(name: file.name, contentType: file.contentType, size: file.size, url: file.url,
                             thumbnailSize: compact ? CGSize(width: 220, height: 140) : CGSize(width: 320, height: 200))
                }
                .buttonStyle(.plain)
                .disabled(file.url == nil)
                .help(String(localized: "Open \(file.name)", bundle: #bundle, comment: "Opens a file of a message in Quick Look"))
                .contextMenu {
                    if let url = file.url {
                        Button(String(localized: "Open", bundle: #bundle, comment: "Opens a file of a message in Quick Look")) { previewed = url }
                        Button(String(localized: "Open With Default App", bundle: #bundle)) { NSWorkspace.shared.open(url) }
                        Button(String(localized: "Show in Finder", bundle: #bundle)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                .accessibilityIdentifier("chat.file.\(turnID).\(file.id)")
            }
        }
        .quickLookPreview($previewed, in: files.compactMap(\.url))
    }
}

/// A line from the app: an error of the Claude CLI, a warning, a compaction.
struct NoticeRow: View {
    let notice: ChatNotice

    var body: some View {
        Label {
            Text(verbatim: notice.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(color)
        .accessibilityIdentifier("chat.notice")
    }

    private var symbol: String {
        switch notice.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .done: "checkmark.circle"
        }
    }

    private var color: Color {
        switch notice.level {
        case .info, .done: .textSecondary
        case .warning: .warning
        case .error: .danger
        }
    }
}

/// A call Claude made through a tool: what it read or changed, the gist, and the way to the tool's window.
struct ToolCallRow: View {
    /// The turn that made it: an item read in two turns has two rows.
    let turnID: ChatTurn.ID
    let blockID: ChatBlock.ID
    let call: ChatToolCall
    var compact = false

    @Environment(\.openRoute) private var openRoute
    @Environment(\.toolReader) private var toolReader
    @State private var isExpanded: Bool

    /// `expanded` opens the row on its details, for previews.
    init(turnID: ChatTurn.ID, blockID: ChatBlock.ID, call: ChatToolCall, compact: Bool = false, expanded: Bool = false) {
        self.turnID = turnID
        self.blockID = blockID
        self.call = call
        self.compact = compact
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded, let details = call.details {
                ToolCallDetailsView(turnID: turnID, details: details, compact: compact)
                    .padding(8)
                    .background(.surface, in: CardShape(minimum: 6))
                    .transition(.opacity)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.surfaceSunken, in: CardShape(minimum: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.toolCall.\(turnID).\(call.reference?.id ?? blockID)")
    }

    /// The icon, what the call did, its gist, then a spinner, the Error tag, the number of steps, Open and the
    /// chevron. A click on it, outside Open, shows or hides the details.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: call.failed ? "exclamationmark.triangle" : call.reference?.tool.symbol ?? "wrench.and.screwdriver")
                .foregroundStyle(call.failed ? Color.danger : Color.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            if compact {
                Text(verbatim: call.action)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                    .help(detail)
            } else {
                Text(verbatim: call.action)
                    .foregroundStyle(.textPrimary)
                    .fixedSize()
                Text(verbatim: detail)
                    .foregroundStyle(call.failed ? Color.danger : Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
            }
            Spacer(minLength: 8)
            if let details = call.details {
                if details.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(String(localized: "Running", bundle: #bundle, comment: "A call without its result yet"))
                }
                if call.failed {
                    Text("Error", bundle: #bundle, comment: "Tags a call that failed")
                        .font(.caption)
                        .foregroundStyle(.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.danger.opacity(0.14), in: .capsule)
                }
                if !details.steps.isEmpty, !isExpanded {
                    Text(stepCount(details.steps))
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            if call.reference != nil {
                Button(String(localized: "Open", bundle: #bundle, comment: "Opens an item in its tool's window"), action: open)
                    .buttonStyle(.borderless)
                    .help(openHelp)
            }
            if call.details != nil {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard call.details != nil else { return }
            withMotion(.fade) { isExpanded.toggle() }
        }
        // One element: what was read, the tool's answer; Open and the details as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(call.action)
        .accessibilityValue(detail)
        .accessibilityHint(openHelp)
        .accessibilityAddTraits(call.reference == nil && call.details == nil ? [] : .isButton)
        .accessibilityAction(.default) {
            if call.reference != nil { open() } else if call.details != nil { isExpanded.toggle() }
        }
        .accessibilityAction(named: Text(isExpanded ? "Hide Details" : "Show Details", bundle: #bundle)) {
            isExpanded.toggle()
        }
        .accessibilityIdentifier("chat.toolCall.\(turnID).\(call.reference?.id ?? blockID).header")
    }

    /// "1 step", "3 steps".
    private func stepCount(_ steps: [ChatBlock]) -> String {
        String(localized: "\(steps.count) steps", bundle: #bundle, comment: "The number of a sub-agent's steps in a call's row")
    }

    /// The call's own detail, else the item's tool's one-line answer.
    private var detail: String {
        call.detail ?? call.reference.flatMap { toolReader($0)?.detail } ?? ""
    }

    private var openHelp: String {
        guard let reference = call.reference else { return "" }
        return String(localized: "Open \(reference.title) in \(reference.tool.title)", bundle: #bundle, comment: "An item, then its tool: Open ORD-142 in Tickets")
    }

    private func open() {
        if let reference = call.reference { openRoute(reference.route) }
    }
}

/// A change Claude asks to make: what, where, and the user's answer. Nothing changes without it.
struct ApprovalCard: View {
    let approval: ChatApproval
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(approval.request)
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.warning)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            if let preview = approval.preview {
                Text(verbatim: preview)
                    .font(.callout)
                    .foregroundStyle(.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(20)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.surfaceSunken, in: CardShape(minimum: 6))
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    note
                    Spacer()
                    answer
                }
                VStack(alignment: .leading, spacing: 8) {
                    note
                    answer
                }
            }
        }
        .padding(12)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(approval.decision == nil ? Color.warning.opacity(0.5) : Color.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.approval.\(approval.id)")
    }

    @ViewBuilder private var note: some View {
        if let channel = approval.channel {
            Label {
                Text("Through \(channel.title), as if you did it", bundle: #bundle, comment: "How Claude would make a change: through a tool, such as Tickets")
            } icon: {
                Image(systemName: channel.symbol)
                    .accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(.textSecondary)
        } else {
            Text("Through the Claude CLI", bundle: #bundle, comment: "A change Claude would make with a tool of its own")
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
    }

    @ViewBuilder private var answer: some View {
        // The pending card's buttons are those of the card over the composer; the transcript keeps the answer.
        switch approval.decision {
        case nil:
            Label(String(localized: "Waiting for your answer", bundle: #bundle, comment: "A card waits for the user"), systemImage: "hourglass")
                .foregroundStyle(.warning)
                .accessibilityIdentifier("chat.approval.\(approval.id).waiting")
        case .allowed?:
            Label(by(String(localized: "Allowed", bundle: #bundle, comment: "The user allowed the change"),
                     String(localized: "Allowed by \(approval.decidedBy ?? "")", bundle: #bundle, comment: "The user allowed the change, on the Mac named")),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.success)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        case .allowedAlways?:
            Label(by(String(localized: "Always Allowed", bundle: #bundle, comment: "The user allowed the change and its kind"),
                     String(localized: "Always allowed by \(approval.decidedBy ?? "")", bundle: #bundle, comment: "The user allowed it and its kind, on the Mac named")),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.success)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        case .declined?:
            Label(by(String(localized: "Not Allowed", bundle: #bundle, comment: "The user didn't allow the change"),
                     String(localized: "Not allowed by \(approval.decidedBy ?? "")", bundle: #bundle, comment: "The user didn't allow it, on the Mac named")),
                  systemImage: "xmark.circle")
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        case .cancelled?:
            Label(String(localized: "Cancelled", bundle: #bundle, comment: "A card the app refused: Stop, the end of Claude's process"), systemImage: "minus.circle")
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        }
    }

    /// The answer with the Mac whose user gave it, when known.
    private func by(_ alone: String, _ named: String) -> String {
        approval.decidedBy == nil ? alone : named
    }
}

/// Why the last message wasn't sent, or a setting not changed, over the composer.
struct ChatFailure: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.failure")
    }
}

/// An item a message carries, as a chip; `remove` adds a button that takes it off.
struct ContextChip: View {
    let reference: ChatReference
    let identifier: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: reference.tool.symbol)
                .accessibilityHidden(true)
            Text(verbatim: reference.title)
                .accessibilityLabel(itemName)
            if let remove {
                Button(String(localized: "Remove \(reference.title)", bundle: #bundle), systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.textSecondary)
                    .help(String(localized: "Remove \(reference.title)", bundle: #bundle))
                    .accessibilityIdentifier("\(identifier).remove")
            }
        }
        .font(.caption)
        .foregroundStyle(.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.surfaceSunken, in: Capsule())
        .help(itemName)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// "Tickets: ORD-142".
    private var itemName: String {
        String(localized: "\(reference.tool.title): \(reference.title)", bundle: #bundle, comment: "An item named with its tool: Tickets: ORD-142")
    }
}

/// The project a message is about, as a chip that can't be taken off.
struct ProjectChip: View {
    let project: Project

    var body: some View {
        HStack(spacing: 4) {
            ProjectIcon(project)
            Text(verbatim: project.name)
        }
        .font(.caption)
        .foregroundStyle(.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.surfaceSunken, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.composer.project")
    }
}

/// Questions to start from, as buttons that send them.
struct SuggestionList: View {
    let suggestions: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    pick(suggestion)
                } label: {
                    Text(verbatim: suggestion)
                }
                .buttonStyle(.suggestion)
                .accessibilityIdentifier(ChatSuggestion.identifier(for: suggestion))
            }
        }
    }
}

// MARK: - Previews

#Preview("Approval, Waiting", traits: .appChrome, .fixedLayout(width: 520, height: 260)) {
    ApprovalCard(approval: .preview(decision: nil)) { _ in }
        .padding()
}

#Preview("Approval, Allowed", traits: .appChrome, .fixedLayout(width: 520, height: 260)) {
    ApprovalCard(approval: .preview(decision: .allowed)) { _ in }
        .padding()
}

#Preview("Approval, Not Allowed, Dark", traits: .appChrome, .fixedLayout(width: 520, height: 260)) {
    ApprovalCard(approval: .preview(decision: .declined)) { _ in }
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Approval, Narrow, Largest Text", traits: .largestText, .fixedLayout(width: 340, height: 640)) {
    ApprovalCard(approval: .preview(decision: nil)) { _ in }
        .padding()
}

private extension ChatApproval {
    static func preview(decision: Decision?) -> ChatApproval {
        ChatApproval.comment(
            id: "preview.comment", on: ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142"),
            preview: "Seen again on Staging: req-8f3a retried 3 times in 4.2 s and ended in a 504. Waiting on run 1288.",
            decision: decision
        )
    }
}
