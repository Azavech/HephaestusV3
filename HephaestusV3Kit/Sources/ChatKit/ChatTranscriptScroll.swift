import AZDesign
import SwiftUI

/// The transcript's scroll view, in the Chat window and the panel: a short conversation starts at the top, a long
/// one opens on its end and follows new turns, and stays at its end when a card over the composer shrinks it;
/// scrolled up more than 40 pt from the end, **Jump to Latest** shows at its bottom edge. With a find query, the blocks that hold it are highlighted, the current one scrolled to.
struct TranscriptScrollView: View {
    let conversation: ChatConversation
    let activity: ChatActivity?
    var compact = false
    var padding: CGFloat
    let decide: (ChatApproval.ID, Bool) -> Void
    var stop: (() -> Void)?
    /// What Find looks for; empty for nothing.
    var findQuery = ""
    /// The match Find shows, by block id.
    var currentMatch: ChatBlock.ID?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var awayFromEnd = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A card waiting shows over the composer only, and here once answered.
                ChatTranscript(conversation: conversation, activity: activity, compact: compact, decide: decide, stop: stop,
                               findQuery: findQuery, currentMatch: currentMatch, hidesWaitingApprovals: true)
                    .padding(padding)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Place.self) { geometry in
                // The visible rectangle counts the toolbar's inset, which the offset leaves out.
                Place(height: geometry.containerSize.height, fromEnd: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { old, new in
                // A card over the composer shrinks the transcript: one that was at its end stays there.
                if new.height < old.height, old.fromEnd <= 40 {
                    position.scrollTo(edge: .bottom)
                    awayFromEnd = false
                } else {
                    awayFromEnd = new.fromEnd > 40
                }
            }
            .overlay(alignment: .bottom) {
                if awayFromEnd {
                    Button {
                        withMotion(.layout) { position.scrollTo(edge: .bottom) }
                    } label: {
                        Label(String(localized: "Jump to Latest", bundle: #bundle), systemImage: "arrow.down")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .background(.surface, in: .capsule)
                    .overlay(Capsule().stroke(Color.divider))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityIdentifier("chat.jumpToLatest")
                }
            }
            .onChange(of: currentMatch) {
                if let currentMatch {
                    withMotion(.layout) { proxy.scrollTo(currentMatch, anchor: .center) }
                }
            }
        }
    }
}

/// The transcript's height and its distance from its end, for Jump to Latest.
private struct Place: Equatable {
    var height: CGFloat
    var fromEnd: CGFloat
}

/// What shows over the composer, in the Chat window, the panels and chat windows: the Claude CLI line, the reason a
/// message wasn't sent, Resume and the cards waiting (docs/ui/chat.md › Over the composer). It gets its room before
/// the transcript, and takes the height it needs, at most `RoomOverComposer.share` of what the composer leaves; the
/// transcript keeps the rest. Short of room, the cards' previews and contents scroll inside them, so that their titles
/// and answers show; what still doesn't fit is cut at the bottom. Its smallest height is zero, so it never makes the
/// column taller than its window, which pushed the window's content under the toolbar and its composer out.
struct OverComposer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        RoomOverComposer {
            VStack(spacing: 0) {
                content
            }
        }
        .clipped()
        .layoutPriority(1)
    }
}

/// Lays out its one view at the height it needs, at most `share` of the height offered, and down to nothing: offered
/// less than it needs, the view gets the height there is and shrinks what scrolls in it.
private struct RoomOverComposer: Layout {
    /// The part of the room the composer leaves that the area may take.
    static let share: CGFloat = 0.7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let room = proposal.height.map { $0 * Self.share } ?? .infinity
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, room))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The smallest height of what scrolls inside a card over the composer, short of room: about two lines.
let scrollingCardMinimum: CGFloat = 44

extension ChatBlock {
    /// A card still waiting for the user's answer.
    var isWaitingApproval: Bool {
        if case .approval(let approval) = content { return approval.decision == nil }
        return false
    }
}

/// Find in a conversation (docs/ui/chat.md › Find): the blocks that hold the query, in order.
enum ChatFind {
    /// The ids of the blocks of `conversation` whose text holds `query`, ignoring case and diacritics: text and
    /// thinking, a call's action, gist, input and result, an answered card's request and preview (a card waiting
    /// shows over the composer, not in the transcript), a notice, questions.
    static func matches(of query: String, in conversation: ChatConversation) -> [ChatBlock.ID] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return conversation.turns.flatMap(\.blocks).filter { !$0.isWaitingApproval }.filter { block in
            texts(of: block).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.map(\.id)
    }

    static func texts(of block: ChatBlock) -> [String] {
        switch block.content {
        case .text(let text), .thinking(let text):
            return [text]
        case .call(let call):
            return [call.action, call.detail ?? "", call.details?.result ?? ""] + (call.details?.input.map(\.text) ?? [])
        case .approval(let approval):
            return [approval.request, approval.preview ?? ""]
        case .notice(let notice):
            return [notice.text]
        case .questions(let set):
            return set.questions.flatMap { [$0.question] + $0.options.map(\.label) } + Array(set.answers.values)
        case .images(let caption, let files):
            return [caption ?? ""] + files.map(\.name)
        case .picker(let request):
            return [request.question] + request.suggestions.map(request.line) + [request.answer ?? ""]
        }
    }
}
