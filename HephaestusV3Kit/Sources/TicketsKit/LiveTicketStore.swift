import Foundation
import Observation
import SwiftUI
import TicketData
import ToolsFoundation

/// The app's tickets: the `TicketSession`'s snapshot, mapped to what the views show, and its changes made
/// as the user on this Mac (docs/data.md › Tickets and bundles).
@MainActor @Observable
public final class LiveTicketStore: TicketStore {
    public let session: TicketSession
    /// The mapped tickets and bundles of the last snapshot read, by project.
    @ObservationIgnored private var cache: (revision: Int, tickets: [String: [Ticket]], bundles: [String: [TicketBundle]])?

    public init(session: TicketSession) {
        self.session = session
    }

    /// How a comment Claude added from a chat names its model and effort, "(Opus 5.5 · Extra High)": the app gives the
    /// CLI's model names. Nil leaves "Claude".
    public static var commentCaption: @MainActor (_ model: String, _ effort: String?) -> String? = { _, _ in nil }

    var phase: TicketStorePhase {
        session.isLoaded ? .ready : .loading
    }

    var unreadableFiles: [String] {
        session.snapshot.invalidFiles.map { "\(URL(fileURLWithPath: $0.key).lastPathComponent): \($0.value)" }.sorted()
    }

    func tickets(of projects: Set<Project.ID>) -> [Ticket] {
        let mapped = current()
        return projects.sorted().flatMap { mapped.tickets[$0] ?? [] }
    }

    func bundles(of projects: Set<Project.ID>) -> [TicketBundle] {
        let mapped = current()
        return projects.sorted().flatMap { mapped.bundles[$0] ?? [] }
    }

    func ticket(_ id: Ticket.ID) -> Ticket? {
        guard let project = TicketIDs.parseTicket(id)?.project else { return nil }
        return current().tickets[project]?.first { $0.id == id }
    }

    /// The counts of the Projects window's Tickets tile and sidebar: open (not done, not drafts), in
    /// review, drafts, for each project on its own.
    public func counts() -> [Project.ID: TicketCounts] {
        current().tickets.mapValues { tickets in
            TicketCounts(
                open: tickets.count { $0.status != .done && $0.status != .draft },
                inReview: tickets.count { $0.status == .inReview },
                drafts: tickets.count { $0.status == .draft }
            )
        }
    }

    func perform(_ change: TicketChangeRequest) async throws(TicketStoreError) -> String? {
        do {
            switch change {
            case .create(let draft):
                return try await session.create(TicketLibrary.NewTicket(
                    projectID: draft.projectID, title: draft.title, description: draft.details,
                    status: draft.startsAsDraft ? .draft : .todo, priority: draft.priority.map(Self.filePriority)
                ))
            case let .setStatus(ids, status):
                try await session.setStatus(ids, to: Self.fileStatus(status))
            case let .edit(id, title, details, priority, labels):
                try await session.update(id, .init(title: title, description: details, priority: .some(priority.map(Self.filePriority)), labels: labels))
            case let .setPriority(id, priority):
                try await session.update(id, .init(priority: .some(priority.map(Self.filePriority))))
            case let .setLinks(id, links):
                try await session.update(id, .init(links: links.map {
                    TicketLinkEntry(kind: $0.kind == .dependsOn ? .dependsOn : .related, ticketID: $0.ticketID)
                }))
            case .delete(let ids):
                try await session.delete(ids)
            case let .addComment(id, text, files):
                try await session.addComment(to: id, text: text, files: files)
            case let .editComment(id, commentID, text):
                try await session.updateComment(commentID, of: id, text: text)
            case let .deleteComment(id, commentID):
                try await session.deleteComment(commentID, of: id)
            case let .addAttachments(id, files):
                try await session.addAttachments(files, to: id)
            case let .removeAttachment(id, attachmentID):
                try await session.removeAttachment(attachmentID, of: id)
            case let .createBundle(projectID, title, tickets):
                return try await session.createBundle(in: projectID, title: title, ticketIDs: tickets)
            case let .editBundle(id, title, tickets):
                try await session.updateBundle(id, title: title, ticketIDs: tickets)
            case let .setBundleStatus(id, status):
                try await session.setBundleStatus(id, to: Self.fileBundleStatus(status))
            case .deleteBundle(let id):
                try await session.deleteBundle(id)
            }
        } catch {
            throw TicketStoreError(message: error.description)
        }
        return nil
    }

    func url(of attachment: TicketAttachment, in projectID: Project.ID) async -> URL? {
        try? await session.attachmentURL(attachment.path, in: projectID)
    }

    func retry() async {
        await session.refresh()
    }

    // MARK: Mapping

    private func current() -> (tickets: [String: [Ticket]], bundles: [String: [TicketBundle]]) {
        let snapshot = session.snapshot
        if let cache, cache.revision == snapshot.revision { return (cache.tickets, cache.bundles) }
        var tickets: [String: [Ticket]] = [:]
        for (projectID, loaded) in snapshot.tickets {
            let byID = Dictionary(loaded.map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
            tickets[projectID] = loaded.map { Self.ticket($0, others: byID) }
        }
        let bundles = snapshot.bundles.mapValues { files in
            files.map { TicketBundle(id: $0.id, projectID: TicketIDs.parseBundle($0.id)?.project ?? "", title: $0.title,
                                     ticketIDs: $0.ticketIDs, status: Self.bundleStatus($0.status)) }
        }
        cache = (snapshot.revision, tickets, bundles)
        return (tickets, bundles)
    }

    static func ticket(_ loaded: LoadedTicket, others: [String: TicketFile]) -> Ticket {
        let file = loaded.file
        func title(of id: String) -> String {
            others[id].map { "\(id) · \($0.title)" } ?? id
        }
        var links = file.links.map { link in
            TicketLink(id: "\(link.kind.rawValue)-\(link.ticketID)", kind: link.kind == .dependsOn ? .dependsOn : .related,
                       title: title(of: link.ticketID), target: link.ticketID, isDeclared: true, isMissing: others[link.ticketID] == nil)
        }
        links += loaded.inverseLinks.map { link in
            TicketLink(id: "\(link.kind.rawValue)-\(link.ticketID)", kind: link.kind == .blocks ? .blocks : .related,
                       title: title(of: link.ticketID), target: link.ticketID)
        }
        let blockers = file.links.filter { $0.kind == .dependsOn && others[$0.ticketID].map { $0.status != .done } == true }
            .map(\.ticketID).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let blocked = !blockers.isEmpty
        return Ticket(
            id: file.id, projectID: loaded.projectID, title: file.title, details: file.description, status: status(file.status),
            priority: file.priority.map(priority), labels: file.labels,
            reporter: file.createdBy == .claude ? TicketWords.claude : TicketWords.you,
            createdAt: file.created, updatedAt: file.updated, links: links, events: events(of: file),
            attachments: file.attachments.map(attachment), isBlocked: blocked, blockedBy: blockers
        )
    }

    /// The history and the comments, oldest first; at equal dates the creation, then the comments, then the
    /// other entries.
    static func events(of file: TicketFile) -> [TicketEvent] {
        var ranked: [(rank: Int, event: TicketEvent)] = []
        for (index, entry) in file.history.enumerated() {
            let author = author(entry.author)
            let event: TicketEvent
            switch entry.kind {
            case .created:
                let drafted = entry.to == TicketFileStatus.draft.rawValue
                event = TicketEvent(id: index, kind: drafted ? .drafted : .created, text: TicketWords.created(by: author, asDraft: drafted),
                                    date: entry.date, author: author)
            case .status:
                event = TicketEvent(id: index, kind: .statusChanged,
                                    text: TicketWords.moved(by: author, from: statusTitle(entry.from), to: statusTitle(entry.to)),
                                    date: entry.date, author: author)
            case .title:
                event = TicketEvent(id: index, kind: .renamed, text: TicketWords.renamed(by: author, from: entry.from ?? "", to: entry.to ?? ""),
                                    date: entry.date, author: author)
            case .linkAdded, .linkRemoved:
                let parts = (entry.to ?? "").split(separator: " ").map(String.init)
                let kind = parts.first == TicketLinkEntry.Kind.dependsOn.rawValue ? TicketLink.Kind.dependsOn : .related
                let other = parts.last ?? ""
                event = TicketEvent(id: index, kind: entry.kind == .linkAdded ? .linkAdded : .linkRemoved,
                                    text: entry.kind == .linkAdded ? TicketWords.linkAdded(by: author, kind: kind, ticket: other)
                                        : TicketWords.linkRemoved(by: author, kind: kind, ticket: other),
                                    date: entry.date, author: author)
            case .description:
                event = TicketEvent(id: index, kind: .descriptionEdited, text: TicketWords.descriptionEdited(by: author),
                                    date: entry.date, author: author)
            }
            ranked.append((entry.kind == .created ? 0 : 2, event))
        }
        let base = file.history.count
        for (index, comment) in file.comments.enumerated() {
            let author: TicketAuthor = comment.author == .claude ? .claude : .user
            let caption = author == .claude ? comment.model.flatMap { commentCaption($0, comment.effort) } : nil
            ranked.append((1, TicketEvent(id: base + index, kind: .commented, text: TicketWords.commented(by: author, caption: caption), date: comment.created,
                                          comment: comment.text, commentID: comment.id, author: author,
                                          attachments: comment.attachments.map(attachment), editedAt: comment.updated)))
        }
        return ranked.enumerated().sorted { a, b in
            if a.element.event.date != b.element.event.date { return a.element.event.date < b.element.event.date }
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            return a.offset < b.offset
        }.map(\.element.event)
    }

    static func attachment(_ entry: AttachmentEntry) -> TicketAttachment {
        TicketAttachment(id: entry.id, name: entry.name, path: entry.path, contentType: entry.contentType, size: entry.size)
    }

    static func author(_ author: HistoryEntry.HistoryAuthor) -> TicketAuthor {
        switch author {
        case .user: .user
        case .claude: .claude
        case .automatic: .automatic
        }
    }

    static func statusTitle(_ raw: String?) -> String {
        raw.flatMap(TicketFileStatus.init(rawValue:)).map { status($0).title } ?? (raw ?? "")
    }

    static func status(_ status: TicketFileStatus) -> TicketStatus {
        switch status {
        case .draft: .draft
        case .todo: .created
        case .inProgress: .inProgress
        case .review: .inReview
        case .done: .done
        }
    }

    static func fileStatus(_ status: TicketStatus) -> TicketFileStatus {
        switch status {
        case .draft: .draft
        case .created: .todo
        case .inProgress: .inProgress
        case .inReview: .review
        case .done: .done
        }
    }

    static func priority(_ priority: TicketFilePriority) -> TicketPriority {
        TicketPriority(rawValue: priority.rawValue) ?? .medium
    }

    static func filePriority(_ priority: TicketPriority) -> TicketFilePriority {
        TicketFilePriority(rawValue: priority.rawValue) ?? .medium
    }

    static func bundleStatus(_ status: BundleFile.Status) -> BundleStatus {
        switch status {
        case .todo: .todo
        case .inProgress: .inProgress
        case .done: .done
        }
    }

    static func fileBundleStatus(_ status: BundleStatus) -> BundleFile.Status {
        switch status {
        case .todo: .todo
        case .inProgress: .inProgress
        case .done: .done
        }
    }
}

extension EnvironmentValues {
    /// The app's tickets, for the Tickets windows; nil in previews, which use the samples.
    @Entry public var ticketStore: LiveTicketStore?
}
