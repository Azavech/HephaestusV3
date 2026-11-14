import Foundation
import ToolsFoundation

/// Where the tickets come from. The app and the previews use `SampleTicketStore`; the tests a mock.
protocol TicketStore {
    /// The tickets of these projects, in the store's order.
    func tickets(of projects: Set<Project.ID>) -> [Ticket]
    /// The bundles of these projects, in the store's order.
    func bundles(of projects: Set<Project.ID>) -> [TicketBundle]
    /// The ticket with this id, whatever its project.
    func ticket(_ id: Ticket.ID) -> Ticket?
}

extension TicketStore {
    /// How many tickets of `project` are in `status`, with those of its sub projects at any depth
    /// when `includingSubprojects` is on.
    func count(of status: TicketStatus, in project: Project.ID, includingSubprojects: Bool) -> Int {
        let projects = includingSubprojects ? Set(Project.tree.family(of: project).map(\.id)) : [project]
        return tickets(of: projects).count { $0.status == status }
    }
}

/// The sample tickets and bundles (`Ticket.samples`, `TicketBundle.samples`), kept in memory.
struct SampleTicketStore: TicketStore {
    var allTickets = Ticket.samples
    var allBundles = TicketBundle.samples

    func tickets(of projects: Set<Project.ID>) -> [Ticket] {
        allTickets.filter { projects.contains($0.projectID) }
    }

    func bundles(of projects: Set<Project.ID>) -> [TicketBundle] {
        allBundles.filter { projects.contains($0.projectID) }
    }

    func ticket(_ id: Ticket.ID) -> Ticket? {
        allTickets.first { $0.id == id }
    }
}
