import AZDesign
import SwiftUI
import ToolsFoundation

/// Where Claude's answer to a comment that mentions it stands (docs/ui/tickets.md › Comment answers): runtime state,
/// which a restart doesn't keep.
public enum CommentAnswerState: Equatable, Sendable {
    /// The run works: "Claude is replying…".
    case replying
    /// The run failed or was stopped: "Claude could not reply." with Retry.
    case failed
}

/// What the Tickets window reads of the comment answers, and its Retry: the app gives it.
public struct CommentAnswersReader {
    public let state: @MainActor (UUID) -> CommentAnswerState?
    public let retry: @MainActor (UUID) -> Void

    public init(state: @escaping @MainActor (UUID) -> CommentAnswerState?, retry: @escaping @MainActor (UUID) -> Void) {
        self.state = state
        self.retry = retry
    }
}

private struct CommentAnswersKey: EnvironmentKey {
    static let defaultValue: CommentAnswersReader? = nil
}

extension EnvironmentValues {
    public var commentAnswers: CommentAnswersReader? {
        get { self[CommentAnswersKey.self] }
        set { self[CommentAnswersKey.self] = newValue }
    }
}

/// The row under a comment while Claude answers it, or after its run failed, as V2's.
struct CommentAnswerRow: View {
    let state: CommentAnswerState
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .replying:
                ProgressView()
                    .controlSize(.small)
                Text("Claude is replying…", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.warning)
                    .accessibilityHidden(true)
                Text("Claude could not reply.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
                Button(String(localized: "Retry", bundle: #bundle, comment: "Runs Claude's answer to a comment again"), action: retry)
                    .accessibilityIdentifier("ticket.comment.answer.retry")
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ticket.comment.answer")
    }
}

/// The completion list over the comment field while `@` and the start of `Claude` are typed (docs/ui/tickets.md ›
/// Mentioning Claude): one row, `Claude`, shown selected. A click on it completes the mention.
struct MentionSuggestion: View {
    let complete: () -> Void

    var body: some View {
        Button(action: complete) {
            Text(verbatim: "Claude")
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(minWidth: 120, alignment: .leading)
                .background(.accent, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.surface, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityLabel(String(localized: "Mention Claude", bundle: #bundle, comment: "The completion of @Claude in a comment"))
        .accessibilityIdentifier("ticket.comment.mention")
    }
}
