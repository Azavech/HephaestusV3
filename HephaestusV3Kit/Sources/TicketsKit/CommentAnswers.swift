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
