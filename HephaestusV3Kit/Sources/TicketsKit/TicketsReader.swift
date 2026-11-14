import Foundation
import ToolsFoundation

/// The Tickets tool's read function for other clients, the chat among them: what a ticket is, in a
/// sentence, and the questions worth asking about it. In the real suite it answers from the tool's
/// API; here, from the sample tickets.
public enum TicketsReader {
    /// `focus` is a ticket id, e.g. `ORD-142`. Nil when no ticket has that id.
    public static func read(_ focus: String) -> ToolReading? {
        read(focus, store: SampleTicketStore())
    }

    static func read(_ focus: String, store: any TicketStore) -> ToolReading? {
        guard let ticket = store.ticket(focus) else { return nil }
        return ToolReading(
            action: String(localized: "Read ticket \(ticket.id)", bundle: #bundle),
            detail: detail(of: ticket),
            suggestions: suggestions(for: ticket)
        )
    }

    /// A ticket as the chat panel names it.
    static func reference(_ ticket: Ticket) -> ChatReference {
        ChatReference(tool: .tickets, projectID: ticket.projectID, focus: ticket.id, title: ticket.id)
    }

    /// The ticket's title, status and priority, as one sentence per status and priority.
    static func detail(of ticket: Ticket) -> String {
        let title = ticket.title
        switch (ticket.status, ticket.priority) {
        case (.draft, .low): return String(localized: "“\(title)” is a draft, with low priority.", bundle: #bundle)
        case (.draft, .medium): return String(localized: "“\(title)” is a draft, with medium priority.", bundle: #bundle)
        case (.draft, .high): return String(localized: "“\(title)” is a draft, with high priority.", bundle: #bundle)
        case (.draft, .urgent): return String(localized: "“\(title)” is a draft, with urgent priority.", bundle: #bundle)
        case (.created, .low): return String(localized: "“\(title)” is waiting to start, with low priority.", bundle: #bundle)
        case (.created, .medium): return String(localized: "“\(title)” is waiting to start, with medium priority.", bundle: #bundle)
        case (.created, .high): return String(localized: "“\(title)” is waiting to start, with high priority.", bundle: #bundle)
        case (.created, .urgent): return String(localized: "“\(title)” is waiting to start, with urgent priority.", bundle: #bundle)
        case (.inProgress, .low): return String(localized: "“\(title)” is in progress, with low priority.", bundle: #bundle)
        case (.inProgress, .medium): return String(localized: "“\(title)” is in progress, with medium priority.", bundle: #bundle)
        case (.inProgress, .high): return String(localized: "“\(title)” is in progress, with high priority.", bundle: #bundle)
        case (.inProgress, .urgent): return String(localized: "“\(title)” is in progress, with urgent priority.", bundle: #bundle)
        case (.inReview, .low): return String(localized: "“\(title)” is in review, with low priority.", bundle: #bundle)
        case (.inReview, .medium): return String(localized: "“\(title)” is in review, with medium priority.", bundle: #bundle)
        case (.inReview, .high): return String(localized: "“\(title)” is in review, with high priority.", bundle: #bundle)
        case (.inReview, .urgent): return String(localized: "“\(title)” is in review, with urgent priority.", bundle: #bundle)
        case (.done, .low): return String(localized: "“\(title)” is done. Its priority was low.", bundle: #bundle)
        case (.done, .medium): return String(localized: "“\(title)” is done. Its priority was medium.", bundle: #bundle)
        case (.done, .high): return String(localized: "“\(title)” is done. Its priority was high.", bundle: #bundle)
        case (.done, .urgent): return String(localized: "“\(title)” is done. Its priority was urgent.", bundle: #bundle)
        case (.draft, nil): return String(localized: "“\(title)” is a draft.", bundle: #bundle)
        case (.created, nil): return String(localized: "“\(title)” is waiting to start.", bundle: #bundle)
        case (.inProgress, nil): return String(localized: "“\(title)” is in progress.", bundle: #bundle)
        case (.inReview, nil): return String(localized: "“\(title)” is in review.", bundle: #bundle)
        case (.done, nil): return String(localized: "“\(title)” is done.", bundle: #bundle)
        }
    }

    /// The questions worth asking about the ticket where it is in its life, the one its status raises
    /// first, then a summary.
    static func suggestions(for ticket: Ticket) -> [String] {
        let id = ticket.id
        let question = switch ticket.status {
        case .draft: String(localized: "Is \(id) ready to create?", bundle: #bundle)
        case .created: String(localized: "Where should work on \(id) start?", bundle: #bundle)
        case .inProgress: String(localized: "What's left before \(id) can go to review?", bundle: #bundle)
        case .inReview: String(localized: "Is \(id) ready to be marked as done?", bundle: #bundle)
        case .done: String(localized: "What did \(id) change?", bundle: #bundle)
        }
        return [question, String(localized: "Summarize \(id)", bundle: #bundle)]
    }
}
