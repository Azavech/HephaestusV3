import Foundation
import Observation
import ToolsFoundation

/// Where the store is.
enum TicketStorePhase: Hashable, Sendable {
    /// The app is reading the tickets.
    case loading
    case ready
    /// The tickets can't be read; the message says why.
    case failed(String)
}

/// A change the window asks for. Each goes to the store, which applies the rules of docs/data.md ›
/// Ticket changes and gives back the message of the rule broken, if any.
enum TicketChangeRequest: Hashable, Sendable {
    /// Creates a ticket; the store returns its id.
    case create(NewTicketDraft)
    case setStatus([Ticket.ID], TicketStatus)
    /// The title, description, priority and labels, as the editor holds them.
    case edit(Ticket.ID, title: String, details: String, priority: TicketPriority?, labels: [String])
    case setPriority(Ticket.ID, TicketPriority?)
    /// The whole list of links the ticket declares.
    case setLinks(Ticket.ID, [TicketLinkDraft])
    case delete([Ticket.ID])
    case addComment(Ticket.ID, text: String, files: [URL])
    case editComment(Ticket.ID, UUID, text: String)
    case deleteComment(Ticket.ID, UUID)
    case addAttachments(Ticket.ID, [URL])
    case removeAttachment(Ticket.ID, UUID)
    /// Creates a bundle; the store returns its id.
    case createBundle(Project.ID, title: String, tickets: [Ticket.ID])
    case editBundle(TicketBundle.ID, title: String?, tickets: [Ticket.ID]?)
    case setBundleStatus(TicketBundle.ID, BundleStatus)
    case deleteBundle(TicketBundle.ID)
}

/// Why a change failed, in the words of the rule it broke.
struct TicketStoreError: Error, Hashable, Sendable {
    let message: String
}

/// Where the tickets come from: `LiveTicketStore` in the app, `SampleTicketStore` in previews, a mock in
/// tests. Reads are synchronous over the latest snapshot; changes are async.
@MainActor
protocol TicketStore {
    var phase: TicketStorePhase { get }
    /// The tickets of these projects, in ascending number per project.
    func tickets(of projects: Set<Project.ID>) -> [Ticket]
    /// The bundles of these projects, in ascending number per project.
    func bundles(of projects: Set<Project.ID>) -> [TicketBundle]
    /// The ticket with this id, whatever its project.
    func ticket(_ id: Ticket.ID) -> Ticket?
    /// Makes a change; returns the id of what it created, if anything.
    @discardableResult
    func perform(_ change: TicketChangeRequest) async throws(TicketStoreError) -> String?
    /// The file of an attachment, to open, show or save it.
    func url(of attachment: TicketAttachment, in projectID: Project.ID) async -> URL?
    /// Reads everything again, after a failure.
    func retry() async
}

extension TicketStore {
    var phase: TicketStorePhase { .ready }

    func perform(_ change: TicketChangeRequest) async throws(TicketStoreError) -> String? {
        throw TicketStoreError(message: "This store doesn't change tickets.")
    }

    func url(of attachment: TicketAttachment, in projectID: Project.ID) async -> URL? { nil }

    func retry() async {}

    /// How many tickets of `project` are in `status`, with those of its sub projects at any depth
    /// when `includingSubprojects` is on.
    func count(of status: TicketStatus, in project: Project.ID, includingSubprojects: Bool, tree: ProjectTree = Project.tree) -> Int {
        let projects = includingSubprojects ? Set(tree.family(of: project).map(\.id)) : [project]
        return tickets(of: projects).count { $0.status == status }
    }
}

/// The sample tickets and bundles (`Ticket.samples`, `TicketBundle.samples`), kept in memory. Its changes
/// apply in memory, without the library's rules, so previews and tests can follow them.
@MainActor @Observable
final class SampleTicketStore: TicketStore {
    var allTickets: [Ticket]
    var allBundles: [TicketBundle]
    var phase: TicketStorePhase
    /// Every change asked for, in order.
    private(set) var changes: [TicketChangeRequest] = []

    init(allTickets: [Ticket] = Ticket.samples, allBundles: [TicketBundle] = TicketBundle.samples, phase: TicketStorePhase = .ready) {
        self.allTickets = allTickets
        self.allBundles = allBundles
        self.phase = phase
    }

    func tickets(of projects: Set<Project.ID>) -> [Ticket] {
        allTickets.filter { projects.contains($0.projectID) }
    }

    func bundles(of projects: Set<Project.ID>) -> [TicketBundle] {
        allBundles.filter { projects.contains($0.projectID) }
    }

    func ticket(_ id: Ticket.ID) -> Ticket? {
        allTickets.first { $0.id == id }
    }

    func perform(_ change: TicketChangeRequest) async throws(TicketStoreError) -> String? {
        changes.append(change)
        switch change {
        case .create(let draft):
            let number = (allTickets.filter { $0.projectID == draft.projectID }.compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            let id = "\(draft.projectID)-\(number)"
            allTickets.append(Ticket(
                id: id, projectID: draft.projectID, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), details: draft.details,
                status: draft.startsAsDraft ? .draft : .created, priority: draft.priority, labels: [], reporter: TicketWords.you,
                createdAt: SampleClock.date(), updatedAt: SampleClock.date(), links: [], events: []
            ))
            return id
        case let .setStatus(ids, status):
            update(ids) { $0.status = status }
        case let .edit(id, title, details, priority, labels):
            update([id]) {
                $0.title = title
                $0.details = details
                $0.priority = priority
                $0.labels = labels
            }
        case let .setPriority(id, priority):
            update([id]) { $0.priority = priority }
        case let .setLinks(id, links):
            update([id]) { ticket in
                ticket.links = ticket.links.filter { !$0.isDeclared } + links.map {
                    TicketLink(id: "\($0.kind.rawValue)-\($0.ticketID)", kind: $0.kind == .dependsOn ? .dependsOn : .related,
                               title: $0.ticketID, target: $0.ticketID, isDeclared: true)
                }
            }
        case .delete(let ids):
            allTickets.removeAll { ids.contains($0.id) }
            for index in allBundles.indices { allBundles[index].ticketIDs.removeAll { ids.contains($0) } }
        case let .addComment(id, text, _):
            update([id]) { ticket in
                ticket.events.append(TicketEvent(id: (ticket.events.map(\.id).max() ?? 0) + 1, kind: .commented, text: TicketWords.commented(by: .user),
                                                 date: SampleClock.date(), comment: text, commentID: UUID()))
            }
        case let .editComment(id, commentID, text):
            update([id]) { ticket in
                if let index = ticket.events.firstIndex(where: { $0.commentID == commentID }) { ticket.events[index].comment = text }
            }
        case let .deleteComment(id, commentID):
            update([id]) { $0.events.removeAll { $0.commentID == commentID } }
        case .addAttachments:
            break
        case let .removeAttachment(id, attachmentID):
            update([id]) { $0.attachments.removeAll { $0.id == attachmentID } }
        case let .createBundle(projectID, title, tickets):
            let numbers = allBundles.filter { $0.projectID == projectID }.compactMap { Int($0.id.split(separator: "B").last ?? "") }
            let id = "\(projectID)-B\((numbers.max() ?? 0) + 1)"
            allBundles.append(TicketBundle(id: id, projectID: projectID, title: title.isEmpty ? id : title, ticketIDs: tickets))
            return id
        case let .editBundle(id, title, tickets):
            if let index = allBundles.firstIndex(where: { $0.id == id }) {
                if let title { allBundles[index].title = title }
                if let tickets { allBundles[index].ticketIDs = tickets }
            }
        case let .setBundleStatus(id, status):
            if let index = allBundles.firstIndex(where: { $0.id == id }) { allBundles[index].status = status }
        case .deleteBundle(let id):
            allBundles.removeAll { $0.id == id }
        }
        return nil
    }

    private func update(_ ids: [Ticket.ID], _ change: (inout Ticket) -> Void) {
        for index in allTickets.indices where ids.contains(allTickets[index].id) {
            change(&allTickets[index])
        }
    }
}
