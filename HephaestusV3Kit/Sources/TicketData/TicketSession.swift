import FileStorage
import Foundation
import Observation
import ProjectData
import SystemConfiguration

/// The tickets and bundles as the windows see them: the latest snapshot and the changes the windows ask
/// for, each made as the user on this Mac. One session serves the whole app; everything it does goes
/// through its `TicketLibrary`, which the MCP tools share.
@MainActor @Observable
public final class TicketSession {
    public private(set) var snapshot = TicketSnapshot.empty
    /// True once the tickets of the loaded projects are read.
    public private(set) var isLoaded = false

    /// The library, once started: the MCP tools make Claude's changes through it.
    public private(set) var library: TicketLibrary?
    /// The name of this Mac, written in the history entries of the user's changes.
    public let device: String
    @ObservationIgnored private let projects: ProjectSession
    @ObservationIgnored private let trash: Trash
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(projects: ProjectSession, trash: Trash = .system, device: String = TicketSession.computerName()) {
        self.projects = projects
        self.trash = trash
        self.device = device
    }

    /// The Mac's name as set in System Settings ▸ General ▸ Sharing, else "This Mac".
    public nonisolated static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"
    }

    /// Starts once the projects are ready: loads the tickets of every loaded project, then follows the
    /// projects (added, moved, removed) and the files changed outside the app.
    public func start() async {
        guard library == nil, let projectLibrary = projects.projectLibrary else { return }
        let library = TicketLibrary(projects: projectLibrary, trash: trash)
        self.library = library
        apply(await library.sync(with: projects.snapshot))
        isLoaded = true
        projects.observeFileEvents { [weak self] batch in
            guard let self, let library = self.library else { return }
            self.apply(await library.sync(with: self.projects.snapshot))
            self.apply(await library.handle(batch))
        }
        let projects = projects
        following = Task { [weak self] in
            for await snapshot in Observations({ projects.snapshot }) {
                guard let self, let library = self.library else { return }
                self.apply(await library.sync(with: snapshot))
            }
        }
    }

    /// Reads the latest snapshot again, after a change made through the library by another client.
    public func refresh() async {
        guard let library else { return }
        apply(await library.snapshot)
    }

    private var me: TicketActor { .user(device: device) }

    // MARK: Changes

    @discardableResult
    public func create(_ request: TicketLibrary.NewTicket) async throws(TicketError) -> String {
        let result = try await readyLibrary().create(request, by: me)
        apply(result.snapshot)
        return result.id
    }

    public func update(_ id: String, _ change: TicketLibrary.TicketChange) async throws(TicketError) {
        apply(try await readyLibrary().update(id, change, by: me))
    }

    public func setStatus(_ ids: [String], to status: TicketFileStatus) async throws(TicketError) {
        let library = try readyLibrary()
        for id in ids { apply(try await library.setStatus(id, to: status, by: me)) }
    }

    public func delete(_ ids: [String]) async throws(TicketError) {
        apply(try await readyLibrary().delete(ids))
    }

    public func addComment(to id: String, text: String, files: [URL]) async throws(TicketError) {
        let snapshot = try await readyLibrary().addComment(to: id, text: text, files: files, by: me)
        apply(snapshot)
        // A new comment of the user that mentions Claude gets Claude's answer (docs/ui/tickets.md › Comment answers).
        if let comment = snapshot.ticket(id)?.file.comments.last, comment.author == .user, CommentMentions.mentionsClaude(comment.text) {
            onMention?(id, comment.id)
        }
    }

    /// Called with the ticket and the comment, for each new comment of the user that mentions Claude.
    @ObservationIgnored public var onMention: (@MainActor (String, UUID) -> Void)?

    public func updateComment(_ commentID: UUID, of id: String, text: String) async throws(TicketError) {
        apply(try await readyLibrary().updateComment(commentID, of: id, text: text))
    }

    public func deleteComment(_ commentID: UUID, of id: String) async throws(TicketError) {
        apply(try await readyLibrary().deleteComment(commentID, of: id))
    }

    public func addAttachments(_ files: [URL], to id: String) async throws(TicketError) {
        apply(try await readyLibrary().addAttachments(files, to: id))
    }

    public func removeAttachment(_ attachmentID: UUID, of id: String) async throws(TicketError) {
        apply(try await readyLibrary().removeAttachment(attachmentID, of: id))
    }

    public func attachmentURL(_ path: String, in projectID: String) async throws(TicketError) -> URL {
        try await readyLibrary().attachmentURL(path, in: projectID)
    }

    @discardableResult
    public func createBundle(in projectID: String, title: String = "", ticketIDs: [String]) async throws(TicketError) -> String {
        let result = try await readyLibrary().createBundle(in: projectID, title: title, ticketIDs: ticketIDs)
        apply(result.snapshot)
        return result.id
    }

    public func updateBundle(_ id: String, title: String? = nil, ticketIDs: [String]? = nil) async throws(TicketError) {
        apply(try await readyLibrary().updateBundle(id, title: title, ticketIDs: ticketIDs))
    }

    public func setBundleStatus(_ id: String, to status: BundleFile.Status) async throws(TicketError) {
        apply(try await readyLibrary().setBundleStatus(id, to: status, by: me))
    }

    public func deleteBundle(_ id: String) async throws(TicketError) {
        apply(try await readyLibrary().deleteBundle(id))
    }

    /// Implement: appends the chat to the ticket's `chats` (docs/data.md › Implement chats).
    public func linkChat(_ chatID: String, toTicket id: String) async throws(TicketError) {
        apply(try await readyLibrary().linkChat(chatID, toTicket: id))
    }

    /// A bundle's CI chat: appends it to the bundle's `chats` (docs/data.md › CI chats).
    public func linkChat(_ chatID: String, toBundle id: String) async throws(TicketError) {
        apply(try await readyLibrary().linkChat(chatID, toBundle: id))
    }

    /// Implement All: the bundle lists the chat and is In Progress, once its checks pass again.
    public func startImplementation(of id: String, chat chatID: String) async throws(TicketError) {
        apply(try await readyLibrary().startImplementation(of: id, chat: chatID))
    }

    // MARK: Private

    private func readyLibrary() throws(TicketError) -> TicketLibrary {
        guard let library else { throw .notFound("The tickets aren't loaded yet.") }
        return library
    }

    /// Keeps a snapshot newer than the one shown.
    private func apply(_ snapshot: TicketSnapshot?) {
        guard let snapshot, snapshot.revision > self.snapshot.revision else { return }
        self.snapshot = snapshot
    }
}
