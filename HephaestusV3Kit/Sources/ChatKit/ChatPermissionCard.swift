import AZDesign
import AZDesignCode
import SwiftUI

/// The oldest change Claude waits on, over the composer, as V2's pinned permission card (docs/ui/chat.md ›
/// Approval cards): what, why, a preview, a message for Claude, and the three answers.
struct PermissionCard: View {
    /// The pending cards, the oldest first.
    let approvals: [ChatApproval]
    let answer: (ChatApproval.ID, ChatApproval.Answer) -> Void

    /// A preview shows its first lines until Show All.
    static let shownLines = 20

    @State private var message = ""
    @State private var showsAll = false
    /// The keys act once the card has shown for a second, so a key meant for something else doesn't answer it.
    @State private var armed = false

    private var approval: ChatApproval { approvals[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(approval.request)
                        .font(.headline)
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.warning)
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if approvals.count > 1 {
                    Text("1 of \(approvals.count)", bundle: #bundle, comment: "The card shown among the cards waiting")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .monospacedDigit()
                }
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(verbatim: reason)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview
            note
            TextField(String(localized: "Message for Claude (optional)", bundle: #bundle), text: $message,
                      prompt: Text("Message for Claude (optional)", bundle: #bundle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.permission.message")
            HStack {
                Spacer()
                Button(String(localized: "Don't Allow", bundle: #bundle)) { answer(approval.id, .deny(message)) }
                    .keyboardShortcut(armed ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil)
                    .help(String(localized: "Don't Allow (⇧⌘↩): Claude reads your message as the call's error", bundle: #bundle))
                    .accessibilityIdentifier("chat.permission.deny")
                if approval.isCLI {
                    Button(String(localized: "Always Allow", bundle: #bundle)) { answer(approval.id, .allowAlways) }
                        .keyboardShortcut(armed ? KeyboardShortcut(.return, modifiers: [.command, .option]) : nil)
                        .help(String(localized: "Always Allow (⌥⌘↩): the Claude CLI keeps the rule it suggests", bundle: #bundle))
                        .accessibilityIdentifier("chat.permission.always")
                }
                Button(String(localized: "Allow", bundle: #bundle)) { answer(approval.id, .allow) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(armed ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(String(localized: "Allow (⌘↩)", bundle: #bundle))
                    .accessibilityIdentifier("chat.permission.allow")
            }
        }
        .padding(12)
        .background(.surface, in: CardShape(minimum: 10))
        .overlay {
            CardShape(minimum: 10)
                .stroke(Color.warning.opacity(0.5), lineWidth: 1)
        }
        .task(id: approval.id) {
            armed = false
            message = ""
            showsAll = false
            try? await Task.sleep(for: .seconds(1))
            armed = !Task.isCancelled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.permission")
    }

    /// An edit as V2's diff: the replaced text on red, the new on green; another preview in the code font, its first
    /// 20 lines until Show All.
    @ViewBuilder private var preview: some View {
        if let edit = approval.edit {
            VStack(alignment: .leading, spacing: 0) {
                diffText(edit.old, color: .danger)
                diffText(edit.new, color: .success)
            }
            .clipShape(CardShape(minimum: 6))
            .accessibilityIdentifier("chat.permission.diff")
        } else if let preview = approval.preview {
            let lines = preview.split(separator: "\n", omittingEmptySubsequences: false)
            let cut = !showsAll && lines.count > Self.shownLines
            VStack(alignment: .leading, spacing: 4) {
                IDLinkedText(text: cut ? lines.prefix(Self.shownLines).joined(separator: "\n") : preview)
                    .font(.code(.callout))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.surfaceSunken, in: CardShape(minimum: 6))
                if cut {
                    Button(String(localized: "Show All", bundle: #bundle, comment: "Shows a card's whole preview")) { showsAll = true }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("chat.permission.showAll")
                }
            }
        }
    }

    private func diffText(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(.code(.callout))
            .foregroundStyle(.textPrimary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.16))
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
}

/// "Allow All" on red, in the composer of a chat in that mode, as V2's badge.
struct AllowAllBadge: View {
    var body: some View {
        Text("Allow All", bundle: #bundle, comment: "The badge of a chat whose Claude runs every action without asking")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.danger, in: Capsule())
            .help(String(localized: "Every action runs without asking.", bundle: #bundle))
            .accessibilityIdentifier("chat.allowAll")
    }
}
