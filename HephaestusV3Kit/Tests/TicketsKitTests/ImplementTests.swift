import Foundation
import Testing
import ToolsFoundation
@testable import TicketsKit

/// The targets the Implement action was called with.
@MainActor
private final class Opened {
    var targets: [ImplementTarget] = []
    lazy var action = ImplementAction { [unowned self] in self.targets.append($0) }
}

/// docs/ui/tickets.md › Implement: when Implement and Implement All apply, and the dependencies alert.
@Suite("Implement")
@MainActor
struct ImplementTests {
    @Test("Implement applies to a ticket neither done nor a draft, and says why otherwise")
    func refusal() {
        let model = model("ORD")
        for status in [TicketStatus.created, .inProgress, .inReview] {
            #expect(model.implementRefusal(of: ticket("ORD-2", in: "ORD", status)) == nil)
        }
        #expect(model.implementRefusal(of: ticket("ORD-1", in: "ORD", .done)) == "Set another status to implement this ticket.")
        #expect(model.implementRefusal(of: ticket("ORD-3", in: "ORD", .draft)) == "Create the ticket to implement it.")
    }

    @Test("Tickets it depends on that aren't done come first in an alert, in ascending number; otherwise the sheet opens at once")
    func dependencies() {
        var main = ticket("ORD-20", in: "ORD", .created, title: "Checkout")
        main.links = [
            TicketLink(id: "a", kind: .dependsOn, title: "ORD-10", target: "ORD-10", isDeclared: true),
            TicketLink(id: "b", kind: .dependsOn, title: "ORD-9", target: "ORD-9", isDeclared: true),
            TicketLink(id: "c", kind: .dependsOn, title: "ORD-3", target: "ORD-3", isDeclared: true),
            TicketLink(id: "d", kind: .related, title: "ORD-4", target: "ORD-4", isDeclared: true),
        ]
        let free = ticket("ORD-4", in: "ORD", .inReview, title: "Receipts")
        let store = MockTicketStore(allTickets: [
            main, ticket("ORD-10", in: "ORD", .created), ticket("ORD-9", in: "ORD", .inProgress), ticket("ORD-3", in: "ORD", .done), free,
        ])
        let model = model("ORD", store: store)
        let opened = Opened()
        #expect(model.undoneDependencies(of: main) == ["ORD-9", "ORD-10"])
        #expect(model.implementAlertMessage(main) == "ORD-20 depends on ORD-9, ORD-10, which are not done. Implement it anyway?")

        model.implement(main, with: opened.action)
        #expect(opened.targets.isEmpty && model.implementPending?.ticket.id == "ORD-20" && model.selection == "ORD-20")
        model.confirmImplement()
        #expect(opened.targets == [ImplementTarget(.ticket, id: "ORD-20", projectID: "ORD", title: "Checkout")])
        #expect(model.implementPending == nil)

        model.implement(free, with: opened.action)
        #expect(opened.targets.last == ImplementTarget(.ticket, id: "ORD-4", projectID: "ORD", title: "Receipts"), "No dependency: the sheet at once")
        model.implement(ticket("ORD-3", in: "ORD", .done), with: opened.action)
        #expect(opened.targets.count == 2, "A done ticket opens nothing")

        var single = free
        single.links = [TicketLink(id: "e", kind: .dependsOn, title: "ORD-9", target: "ORD-9", isDeclared: true)]
        #expect(model.implementAlertMessage(single) == "ORD-4 depends on ORD-9, which is not done. Implement it anyway?")
    }

    @Test("Implement All applies to a bundle To Do with a ticket left that isn't done")
    func bundles() {
        let model = model("ORD")
        let open = TicketBundle(id: "ORD-B1", projectID: "ORD", title: "Checkout", ticketIDs: ["ORD-2", "ORD-1"])
        #expect(model.canImplement(open))
        var started = open
        started.status = .inProgress
        #expect(!model.canImplement(started))
        started.status = .done
        #expect(!model.canImplement(started))
        #expect(!model.canImplement(TicketBundle(id: "ORD-B2", projectID: "ORD", title: "Done", ticketIDs: ["ORD-1"])))
        #expect(!model.canImplement(TicketBundle(id: "ORD-B3", projectID: "ORD", title: "Gone", ticketIDs: ["ORD-99"])),
                "A listed id without its ticket doesn't count")
        #expect(TicketsModel.target(open) == ImplementTarget(.bundle, id: "ORD-B1", projectID: "ORD", title: "Checkout"))
    }
}
