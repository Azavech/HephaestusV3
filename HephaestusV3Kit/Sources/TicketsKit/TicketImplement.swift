import SwiftUI
import TicketData
import ToolsFoundation

// Implement and Implement All (docs/ui/tickets.md › Implement): the window says when they apply and asks about the
// dependencies; the sheet and the chat are the app's, through `ImplementAction`.
extension TicketsModel {
    /// Why Implement is disabled for the ticket: done, or a draft; nil when it applies.
    func implementRefusal(of ticket: Ticket) -> String? {
        switch ticket.status {
        case .done: String(localized: "Set another status to implement this ticket.", bundle: #bundle)
        case .draft: String(localized: "Create the ticket to implement it.", bundle: #bundle)
        case .created, .inProgress, .inReview: nil
        }
    }

    /// The tickets `ticket` depends on that aren't done, in ascending number.
    func undoneDependencies(of ticket: Ticket) -> [Ticket.ID] {
        let ids = ticket.links.filter { $0.kind == .dependsOn }.map(\.target)
        let undone = ids.filter { id in self.ticket(id).map { $0.status != .done } ?? false }
        return Array(Set(undone)).sorted { (TicketIDs.parseTicket($0)?.number ?? 0) < (TicketIDs.parseTicket($1)?.number ?? 0) }
    }

    /// Implement: the dependencies alert first when some aren't done; otherwise the sheet at once. The ticket is
    /// selected.
    func implement(_ ticket: Ticket, with action: ImplementAction) {
        guard implementRefusal(of: ticket) == nil else { return }
        selection = ticket.id
        if undoneDependencies(of: ticket).isEmpty {
            action(Self.target(ticket))
        } else {
            implementPending = (ticket, action)
        }
    }

    /// The alert's Implement: the sheet.
    func confirmImplement() {
        guard let pending = implementPending else { return }
        implementPending = nil
        pending.action(Self.target(pending.ticket))
    }

    /// The alert's message: "ORD-142 depends on ORD-139, which is not done. Implement it anyway?"
    func implementAlertMessage(_ ticket: Ticket) -> String {
        let ids = undoneDependencies(of: ticket)
        let list = ids.joined(separator: ", ")
        return ids.count == 1
            ? String(localized: "\(ticket.id) depends on \(list), which is not done. Implement it anyway?", bundle: #bundle,
                     comment: "The first value is a ticket id, the second another ticket's id")
            : String(localized: "\(ticket.id) depends on \(list), which are not done. Implement it anyway?", bundle: #bundle,
                     comment: "The first value is a ticket id, the second other tickets' ids separated by commas")
    }

    /// Implement All applies to a bundle To Do with a ticket left that isn't done (V2's rule).
    func canImplement(_ bundle: TicketBundle) -> Bool {
        bundle.status == .todo && bundle.ticketIDs.contains { ticket($0).map { $0.status != .done } ?? false }
    }

    static func target(_ ticket: Ticket) -> ImplementTarget {
        ImplementTarget(.ticket, id: ticket.id, projectID: ticket.projectID, title: ticket.title)
    }

    static func target(_ bundle: TicketBundle) -> ImplementTarget {
        ImplementTarget(.bundle, id: bundle.id, projectID: bundle.projectID, title: bundle.title)
    }
}

extension View {
    /// The dependencies alert of Implement (docs/ui/tickets.md › Implement).
    func implementAlert(_ model: TicketsModel) -> some View {
        // V2's alert: its one sentence is the title.
        alert(
            model.implementPending.map { model.implementAlertMessage($0.ticket) } ?? "",
            isPresented: Binding(get: { model.implementPending != nil }, set: { if !$0 { model.implementPending = nil } }),
            presenting: model.implementPending?.ticket
        ) { _ in
            Button(String(localized: "Implement", bundle: #bundle, comment: "Implements a ticket whose dependencies aren't done")) {
                model.confirmImplement()
            }
            .accessibilityIdentifier("ticket.implement.anyway")
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) { model.implementPending = nil }
        }
    }
}
