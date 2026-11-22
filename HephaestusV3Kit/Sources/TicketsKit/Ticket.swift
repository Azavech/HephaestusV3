import Foundation
import ToolsFoundation

// `TicketStatus` is in ToolsFoundation: the Dashboard's Tickets widget counts by status too.

/// How urgent a ticket is.
enum TicketPriority: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case urgent

    var id: Self { self }
}

/// Something a ticket points to: another ticket of its project (links and their inverses), or an
/// item in another tool. Opening it opens that window, the Tickets window for a ticket.
struct TicketLink: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// This ticket needs the other one done first (declared by this ticket).
        case dependsOn
        /// The other ticket depends on this one (declared by the other).
        case blocks
        /// The tickets are related (declared by either).
        case related
        case service
        case request
        case contract
        case build

        /// Whether it points to another ticket.
        var isTicket: Bool { self == .dependsOn || self == .blocks || self == .related }
    }

    let id: String
    let kind: Kind
    let title: String
    /// What the other window selects when it opens: a ticket id, a service, a request, an operation, a run.
    let target: String
    /// Declared by this ticket, so it can be removed here; the inverse of another ticket's link can't.
    var isDeclared = false
    /// A declared link whose ticket no longer exists, for example after git removed its file.
    var isMissing = false

    /// The window this link opens, for the ticket's project.
    func route(in projectID: Project.ID) -> Route {
        switch kind {
        case .dependsOn, .blocks, .related: .tool(.tickets, project: projectID, focus: target)
        case .service: .tool(.serviceMap, project: projectID, focus: "service:\(target)")
        case .request: .tool(.serviceMap, project: projectID, focus: "request:\(target)")
        case .contract: .tool(.contracts, project: projectID, focus: target)
        case .build: .tool(.builds, project: projectID, focus: target)
        }
    }
}

/// A file of a ticket or of one of its comments, stored in the project's `.hephaestus/attachments/`.
struct TicketAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// Relative to the project's `.hephaestus/` folder.
    let path: String
    let contentType: String
    let size: Int

    /// Shown as a thumbnail rather than a chip.
    var isImage: Bool {
        ["image/png", "image/jpeg", "image/gif", "image/heic", "image/heif", "image/tiff", "image/bmp", "image/webp"].contains(contentType)
    }
}

/// Who wrote a ticket, a comment or made a change.
enum TicketAuthor: String, Hashable, Sendable {
    case user
    case claude
    /// The automatic naming.
    case automatic
}

/// One entry in a ticket's activity: its history, and its comments among it.
struct TicketEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case drafted
        case created
        case statusChanged
        case renamed
        case linkAdded
        case linkRemoved
        case descriptionEdited
        case commented
    }

    /// Unique within the ticket.
    let id: Int
    let kind: Kind
    let text: String
    let date: Date
    /// What a comment says, under the line that announces it (Markdown).
    var comment: String? = nil
    /// The comment's own id, for editing and deleting it.
    var commentID: UUID? = nil
    var author: TicketAuthor = .user
    /// The comment's files.
    var attachments: [TicketAttachment] = []
    /// When the comment's text was last edited.
    var editedAt: Date? = nil
}

/// A ticket as the views show it: plain values, from a `TicketStore`.
struct Ticket: Identifiable, Hashable, Sendable {
    let id: String
    let projectID: Project.ID
    var title: String
    var details: String
    var status: TicketStatus
    /// None until one is set.
    var priority: TicketPriority?
    var labels: [String]
    var reporter: String
    let createdAt: Date
    var updatedAt: Date
    var links: [TicketLink]
    var events: [TicketEvent]
    /// The ticket's own files.
    var attachments: [TicketAttachment] = []

    /// The tickets it depends on that aren't done: it is blocked while there are any.
    var isBlocked = false
    /// The tickets it depends on that aren't done, in ascending number: what the Blocked mark names.
    var blockedBy: [Ticket.ID] = []
}

/// The status of a bundle, separate from its tickets'.
enum BundleStatus: String, CaseIterable, Identifiable, Sendable {
    case todo
    case inProgress
    case done

    var id: Self { self }
}

/// Tickets shipped together, such as the work for one release.
struct TicketBundle: Identifiable, Hashable, Sendable {
    let id: String
    let projectID: Project.ID
    var title: String
    var ticketIDs: [Ticket.ID]
    var status: BundleStatus = .todo
}

/// A link the user declares: its kind and the other ticket.
struct TicketLinkDraft: Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case dependsOn
        case related

        var id: Self { self }
    }

    var kind: Kind
    var ticketID: Ticket.ID
}
