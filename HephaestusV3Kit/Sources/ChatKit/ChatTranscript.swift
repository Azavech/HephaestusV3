import AZDesign
import SwiftUI
import ToolsFoundation

// The parts of a conversation, shared by the Chat window and the side panel. They take values and
// closures only: the window's and the panel's models do the work.

/// The turns of a conversation, then Claude at work while a reply is coming.
struct ChatTranscript: View {
    let conversation: ChatConversation
    let isResponding: Bool
    /// Tighter, for the side panel.
    var compact = false
    /// The user's answer to a change Claude asked to make: allow or not.
    let decide: (ChatApproval.ID, Bool) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: compact ? 16 : 22) {
            ForEach(conversation.turns) { turn in
                ChatTurnView(turn: turn, compact: compact, decide: decide)
            }
            if isResponding {
                ChatAuthorRow(author: .claude, isSample: false) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading…", bundle: #bundle, comment: "Claude reads through the tools while a reply is coming")
                            .foregroundStyle(.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.responding")
            }
        }
    }
}

/// Who speaks, then what they say. No bubbles: a Mac document, as Xcode's assistant shows it.
struct ChatAuthorRow<Content: View>: View {
    let author: ChatTurn.Author
    let isSample: Bool
    @ViewBuilder let content: Content

    @ScaledMetric private var badge = 24.0

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
                    if isSample {
                        Text("Sample reply", bundle: #bundle)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                            .help(String(localized: "No model is connected yet: the reply comes from the example's sample engine.", bundle: #bundle))
                    }
                }
                content
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        author == .user ? .info : .accentSecondary
    }
}

/// One turn: what the user attached, then each block in order.
struct ChatTurnView: View {
    let turn: ChatTurn
    let compact: Bool
    let decide: (ChatApproval.ID, Bool) -> Void

    var body: some View {
        ChatAuthorRow(author: turn.author, isSample: turn.isSample) {
            if !turn.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.attachments) { reference in
                        ContextChip(reference: reference, identifier: "chat.attachment.\(turn.id).\(reference.id)")
                    }
                }
            }
            ForEach(turn.blocks) { block in
                switch block.content {
                case .text(let text):
                    Text(text)
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .toolCall(let reference, let reading):
                    ToolCallRow(turnID: turn.id, reference: reference, reading: reading, compact: compact)
                case .approval(let approval):
                    ApprovalCard(approval: approval) { allow in
                        decide(approval.id, allow)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.turn.\(turn.id)")
    }
}

/// An item Claude read through its tool: what it read, the gist, and the way to the tool's window.
struct ToolCallRow: View {
    /// The turn that read it: an item read in two turns has two rows.
    let turnID: ChatTurn.ID
    let reference: ChatReference
    let reading: ToolReading
    var compact = false

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reference.tool.symbol)
                .foregroundStyle(.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            if compact {
                Text(reading.action)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                    .help(reading.detail)
            } else {
                Text(reading.action)
                    .foregroundStyle(.textPrimary)
                    .fixedSize()
                Text(reading.detail)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reading.detail)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Open", bundle: #bundle, comment: "Opens an item in its tool's window"), action: open)
                .buttonStyle(.borderless)
                .help(openHelp)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.surfaceSunken, in: CardShape(minimum: 6))
        // One element: what was read, the tool's answer, and Open as its action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.action)
        .accessibilityValue(reading.detail)
        .accessibilityHint(openHelp)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("chat.toolCall.\(turnID).\(reference.id)")
    }

    private var openHelp: String {
        String(localized: "Open \(reference.title) in \(reference.tool.title)", bundle: #bundle, comment: "An item, then its tool: Open ORD-142 in Tickets")
    }

    private func open() {
        openRoute(reference.route)
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
            Text(verbatim: approval.preview)
                .font(.callout)
                .foregroundStyle(.textPrimary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSunken, in: CardShape(minimum: 6))
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

    private var note: some View {
        Label {
            Text("Through \(approval.reference.tool.title), as if you did it", bundle: #bundle, comment: "How Claude would make a change: through a tool, such as Tickets")
        } icon: {
            Image(systemName: approval.reference.tool.symbol)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.textSecondary)
    }

    @ViewBuilder private var answer: some View {
        switch approval.decision {
        case nil:
            HStack {
                Button(String(localized: "Don't Allow", bundle: #bundle)) { decide(false) }
                    .accessibilityIdentifier("chat.approval.\(approval.id).deny")
                Button(String(localized: "Allow", bundle: #bundle)) { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.approval.\(approval.id).allow")
            }
        case .allowed?:
            Label(String(localized: "Allowed", bundle: #bundle, comment: "The user allowed the change"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.success)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        case .declined?:
            Label(String(localized: "Not Allowed", bundle: #bundle, comment: "The user didn't allow the change"), systemImage: "xmark.circle")
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("chat.approval.\(approval.id).decision")
        }
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
        ChatApproval(
            id: "preview.comment", change: .comment,
            reference: ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-142", title: "ORD-142"),
            preview: "Seen again on Staging: req-8f3a retried 3 times in 4.2 s and ended in a 504. Waiting on run 1288.",
            decision: decision
        )
    }
}
