import Foundation
import Observation
import ToolsFoundation

/// What the sidebar lets into the list.
enum TicketFilter: Hashable {
    case all
    case status(TicketStatus)
    case bundle(TicketBundle.ID)
    /// A project of the window's family: its tickets and those of its own sub projects.
    case project(Project.ID)
}

/// A section of the sidebar and of the iPhone's Filter menu, which list them in the same order.
enum TicketFilterSection: Hashable, Identifiable {
    case status
    case projects
    case bundles

    var id: Self { self }
}

/// The tickets of one project of a parent's window, under the project's header.
struct TicketGroup: Identifiable, Hashable {
    let project: Project
    let tickets: [Ticket]

    var id: Project.ID { project.id }
}

/// What the New Ticket sheet holds while it is open.
struct NewTicketDraft: Hashable {
    var title = ""
    var details = ""
    var priority = TicketPriority.medium
    var startsAsDraft = true
    /// The project the ticket goes to: the window's project or one of its sub projects.
    var projectID: Project.ID

    /// A ticket needs a title with more than spaces in it.
    var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The Tickets window: its tickets, the sidebar's filter, the selection, what a route's focus selects,
/// the New Ticket sheet and the comments being written.
///
/// A project with sub projects also lists their tickets, at any depth, grouped by project, as in V2.
/// Its bundles stay its own: a bundle never spans projects.
@Observable
final class TicketsModel {
    /// The window's project.
    let project: Project
    /// The project and its sub projects, in tree order.
    let family: [Project]
    /// The tickets of the project and its sub projects, in the store's order.
    let tickets: [Ticket]
    /// The window's own bundles, for the sidebar: a parent lists only its own (the user's choice).
    let bundles: [TicketBundle]
    /// The bundles of the whole family, for the Bundle property of a sub project's ticket.
    @ObservationIgnored private let familyBundles: [TicketBundle]
    /// Opened on a ticket: an iPhone's layout starts on its page.
    let opensSelection: Bool

    /// The sidebar's choice. Nil lets every ticket through, as `.all` does.
    var filter: TicketFilter?
    /// The selected ticket's id. It can name no ticket of the window, when a route asked for one.
    var selection: Ticket.ID?
    /// Whether the New Ticket sheet is open.
    var isComposing = false
    /// What the New Ticket sheet holds.
    var draft: NewTicketDraft
    /// What is typed in each ticket's comment field, by ticket.
    private(set) var commentDrafts: [Ticket.ID: String] = [:]

    /// The window of `project`, with `focus` (a ticket id) selected; without one, the first ticket of
    /// the list.
    init(project: Project, focus: String?, filter: TicketFilter = .all, store: any TicketStore) {
        let family = Project.tree.family(of: project.id)
        let ids = Set(family.map(\.id))
        self.project = project
        self.family = family
        self.tickets = store.tickets(of: ids)
        self.bundles = store.bundles(of: [project.id])
        self.familyBundles = store.bundles(of: ids)
        self.opensSelection = focus != nil
        self.filter = filter
        self.draft = NewTicketDraft(projectID: project.id)
        self.selection = nil
        selection = focus ?? visibleTickets.first?.id
    }

    // MARK: The list

    /// Whether the list groups the tickets by project: for a project with sub projects.
    var isGrouped: Bool {
        family.count > 1
    }

    /// The sidebar's sections, in order. The Projects section only for a project with sub projects,
    /// the Bundles section only when the project has bundles.
    var filterSections: [TicketFilterSection] {
        [.status] + (isGrouped ? [.projects] : []) + (bundles.isEmpty ? [] : [.bundles])
    }

    /// Whether a filter other than All Tickets applies.
    var isFiltered: Bool {
        (filter ?? .all) != .all
    }

    /// The tickets the filter lets through, in the list's order: the store's, or for a parent, the
    /// window's project first, then each sub project in tree order.
    var visibleTickets: [Ticket] {
        isGrouped ? groups.flatMap(\.tickets) : tickets.filter(passesFilter)
    }

    /// The groups of a parent's list: one per project with tickets left after the filter.
    var groups: [TicketGroup] {
        let passing = tickets.filter(passesFilter)
        return family.compactMap { member in
            let group = passing.filter { $0.projectID == member.id }
            return group.isEmpty ? nil : TicketGroup(project: member, tickets: group)
        }
    }

    /// What the list shows.
    var listState: TicketListState {
        if tickets.isEmpty { return .empty }
        if isGrouped {
            let groups = groups
            return groups.isEmpty ? .noMatch(noMatchMessage) : .grouped(groups)
        }
        let visible = visibleTickets
        return visible.isEmpty ? .noMatch(noMatchMessage) : .loaded(visible)
    }

    /// Whether `filter` lets `ticket` through.
    func lets(_ filter: TicketFilter, through ticket: Ticket) -> Bool {
        switch filter {
        case .all:
            true
        case .status(let status):
            ticket.status == status
        case .bundle(let id):
            bundles.first { $0.id == id }?.ticketIDs.contains(ticket.id) ?? false
        case .project(let id):
            Project.tree.family(of: id).contains { $0.id == ticket.projectID }
        }
    }

    /// The window's tickets that `filter` lets through, before any other filter: the sidebar's counts.
    func count(_ filter: TicketFilter) -> Int {
        tickets.count { lets(filter, through: $0) }
    }

    /// The tickets of `bundle` that are done, for its progress bar.
    func doneCount(of bundle: TicketBundle) -> Int {
        tickets.count { bundle.ticketIDs.contains($0.id) && $0.status == .done }
    }

    /// Shows every ticket again.
    func showAllTickets() {
        filter = .all
    }

    /// The name of `filter`, as the sidebar and the filter bar show it.
    func title(of filter: TicketFilter) -> String {
        switch filter {
        case .all: String(localized: "All Tickets", bundle: #bundle)
        case .status(let status): status.title
        case .bundle(let id): bundles.first { $0.id == id }?.title ?? id
        case .project(let id): family.first { $0.id == id }?.name ?? id
        }
    }

    /// The symbol of `filter`, as the sidebar shows it.
    func symbol(of filter: TicketFilter) -> String {
        switch filter {
        case .all: "tray.full"
        case .status(let status): status.symbol
        case .bundle: "shippingbox"
        case .project(let id): family.first { $0.id == id }?.symbol ?? "folder"
        }
    }

    private func passesFilter(_ ticket: Ticket) -> Bool {
        lets(filter ?? .all, through: ticket)
    }

    /// Why the list is empty under the current filter, in a sentence.
    private var noMatchMessage: String {
        switch filter ?? .all {
        case .all:
            String(localized: "No ticket matches this filter.", bundle: #bundle)
        case .status(.draft):
            String(localized: "No ticket is a draft.", bundle: #bundle)
        case .status(.created):
            String(localized: "No ticket is waiting to start.", bundle: #bundle)
        case .status(.inProgress):
            String(localized: "No ticket is in progress.", bundle: #bundle)
        case .status(.inReview):
            String(localized: "No ticket is in review.", bundle: #bundle)
        case .status(.done):
            String(localized: "No ticket is done.", bundle: #bundle)
        case .bundle, .project:
            String(localized: "\(title(of: filter ?? .all)) has no tickets.", bundle: #bundle)
        }
    }

    // MARK: Selection

    /// The selected ticket, when the selection names one of the window's tickets.
    var selectedTicket: Ticket? {
        tickets.first { $0.id == selection }
    }

    /// The id a route asked for that names none of the window's tickets.
    var missingSelection: Ticket.ID? {
        selectedTicket == nil ? selection : nil
    }

    /// Selects the ticket a route asked for, even when it was selected before and the user has picked
    /// another since. A filter that hides it gives way to All Tickets, so its row shows.
    func select(focus: String) {
        selection = focus
        if let ticket = tickets.first(where: { $0.id == focus }), !passesFilter(ticket) {
            filter = .all
        }
    }

    /// The bundle `ticket` is in: one of its own project's, so a sub project's ticket shows its bundle
    /// in a parent's window too.
    func bundle(of ticket: Ticket) -> TicketBundle? {
        familyBundles.first { $0.projectID == ticket.projectID && $0.ticketIDs.contains(ticket.id) }
    }

    /// The selected ticket, as the chat panel asks about it.
    var chatSubject: ChatReference? {
        selectedTicket.map(TicketsReader.reference)
    }

    // MARK: Comments

    /// What is typed in `ticket`'s comment field. Each ticket keeps its own.
    func commentDraft(for ticket: Ticket.ID) -> String {
        commentDrafts[ticket, default: ""]
    }

    func setCommentDraft(_ text: String, for ticket: Ticket.ID) {
        commentDrafts[ticket] = text.isEmpty ? nil : text
    }

    // MARK: New Ticket

    /// The projects a new ticket can go to: the window's project and its sub projects, in tree order.
    var newTicketProjects: [Project] {
        family
    }

    /// The project a new ticket goes to unless the user picks another: the one picked in the
    /// sidebar's Projects section, or the window's project.
    var defaultNewTicketProjectID: Project.ID {
        if case .project(let id)? = filter { id } else { project.id }
    }

    /// Opens the New Ticket sheet, empty.
    func startNewTicket() {
        draft = NewTicketDraft(projectID: defaultNewTicketProjectID)
        isComposing = true
    }

    func cancelNewTicket() {
        isComposing = false
    }

    /// Closes the sheet once the ticket has a title. Not wired yet: no ticket is saved.
    func createNewTicket() {
        guard draft.canCreate else { return }
        isComposing = false
    }
}
