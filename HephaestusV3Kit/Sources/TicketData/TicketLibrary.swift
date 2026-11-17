import FileStorage
import Foundation
import ProjectData

/// A ticket as loaded: its file, its project, and the links other tickets declare to it.
public struct LoadedTicket: Sendable, Hashable, Identifiable {
    public var file: TicketFile
    public var projectID: String
    /// The links the other tickets of the project declare to this one: `blocks` for their `dependsOn`,
    /// `related` for theirs, in ascending number of the declaring ticket.
    public var inverseLinks: [InverseLink]
    public var id: String { file.id }

    public init(file: TicketFile, projectID: String, inverseLinks: [InverseLink] = []) {
        self.file = file
        self.projectID = projectID
        self.inverseLinks = inverseLinks
    }

    public struct InverseLink: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case blocks, related }
        public var kind: Kind
        public var ticketID: String

        public init(kind: Kind, ticketID: String) {
            self.kind = kind
            self.ticketID = ticketID
        }
    }
}

/// Every ticket and bundle loaded, at one moment.
public struct TicketSnapshot: Sendable, Hashable {
    public var revision: Int
    /// The tickets of each project, in ascending number.
    public var tickets: [String: [LoadedTicket]]
    /// The bundles of each project, in ascending number.
    public var bundles: [String: [BundleFile]]
    /// The ticket and bundle files that can't be read, with why. A file loaded before keeps its last valid
    /// version until it is fixed or written again.
    public var invalidFiles: [String: String]

    public init(revision: Int = 0, tickets: [String: [LoadedTicket]] = [:], bundles: [String: [BundleFile]] = [:],
                invalidFiles: [String: String] = [:]) {
        self.revision = revision
        self.tickets = tickets
        self.bundles = bundles
        self.invalidFiles = invalidFiles
    }

    public static let empty = TicketSnapshot()

    public func ticket(_ id: String) -> LoadedTicket? {
        guard let project = TicketIDs.parseTicket(id)?.project else { return nil }
        return tickets[project]?.first { $0.id == id }
    }

    public func bundle(_ id: String) -> BundleFile? {
        guard let project = TicketIDs.parseBundle(id)?.project else { return nil }
        return bundles[project]?.first { $0.id == id }
    }
}

/// The tickets and bundles of every loaded project: it reads their files, applies the rules to every change
/// and gives a new snapshot after each (docs/data.md › Tickets).
public actor TicketLibrary {
    private let projects: ProjectLibrary
    private let trash: Trash
    private let ownWrites: OwnWrites
    private let now: @Sendable () -> Date

    /// The folder of each loaded project, by identifier.
    private var roots: [String: String] = [:]
    private var tickets: [String: [String: TicketFile]] = [:]
    private var bundles: [String: [String: BundleFile]] = [:]
    private var invalidFiles: [String: String] = [:]
    private var revision = 0
    private var last = TicketSnapshot.empty
    /// Told of each ticket created without a title (`onUntitled(_:)`).
    private var untitledHandler: (@Sendable (UntitledTicket) -> Void)?

    public init(projects: ProjectLibrary, trash: Trash = .system, ownWrites: OwnWrites = OwnWrites(),
                now: @escaping @Sendable () -> Date = { ISODate.now() }) {
        self.projects = projects
        self.trash = trash
        self.ownWrites = ownWrites
        self.now = now
    }

    /// The latest snapshot.
    public var snapshot: TicketSnapshot { last }

    // MARK: Loading

    /// Follows the loaded projects: loads the tickets and bundles of new ones (and of moved ones), drops those
    /// of removed ones. Each project loaded applies the Complete rule to its bundles.
    public func sync(with snapshot: ProjectSnapshot) -> TicketSnapshot {
        let wanted = Dictionary(snapshot.projects.map { ($0.id, $0.root) }, uniquingKeysWith: { first, _ in first })
        for id in Array(roots.keys) where wanted[id] != roots[id] {
            let folder = projectFolder(id).dataFolder.path + "/"
            invalidFiles = invalidFiles.filter { !$0.key.hasPrefix(folder) }
            roots[id] = nil
            tickets[id] = nil
            bundles[id] = nil
        }
        for (id, root) in wanted.sorted(by: { $0.key < $1.key }) where roots[id] == nil {
            roots[id] = root
            loadAll(id)
            for bundle in sortedBundles(id) where bundle.status != .done && isComplete(bundle, in: id) {
                var done = bundle
                done.status = .done
                done.updated = now()
                try? write(done, in: id)
            }
        }
        return publish()
    }

    /// Applies a batch of file events: reads again each ticket and bundle file they name, the whole project
    /// when events were dropped, then applies the automatic rules to the bundles concerned. Returns the new
    /// snapshot, or nil when nothing changed.
    public func handle(_ events: [FileEvent]) -> TicketSnapshot? {
        let before = last.revision
        var files: [String: Set<String>] = [:]
        var whole: Set<String> = []
        for event in events {
            for id in roots.keys {
                let data = projectFolder(id).dataFolder.path
                for base in Set([data, URL(fileURLWithPath: data).resolvingSymlinksInPath().path]) {
                    if event.kind.contains(.mustRescan) || event.kind.contains(.rootChanged) {
                        if base.hasPrefix(event.path + "/") || event.path.hasPrefix(base) { whole.insert(id) }
                    } else if event.path.hasPrefix(base + "/ticket/") || event.path.hasPrefix(base + "/bundle/") {
                        files[id, default: []].insert(String(event.path.dropFirst(base.count + 1)))
                    } else if event.path == base || event.path == base + "/ticket" || event.path == base + "/bundle"
                                || base.hasPrefix(event.path + "/") {
                        whole.insert(id)
                    }
                }
            }
        }
        for id in roots.keys.sorted() where whole.contains(id) || files[id] != nil {
            let oldTickets = tickets[id] ?? [:]
            let oldBundles = bundles[id] ?? [:]
            if whole.contains(id) {
                loadAll(id)
            } else {
                for path in (files[id] ?? []).sorted() { reload(path, in: id) }
            }
            let newTickets = tickets[id] ?? [:]
            let changedTickets = Set(oldTickets.keys).union(newTickets.keys).filter { oldTickets[$0]?.status != newTickets[$0]?.status }
            let changedBundles = Set((bundles[id] ?? [:]).values
                .filter { Set($0.ticketIDs) != Set(oldBundles[$0.id]?.ticketIDs ?? []) || oldBundles[$0.id] == nil }.map(\.id))
            for bundle in sortedBundles(id) where changedBundles.contains(bundle.id) || !changedTickets.isDisjoint(with: bundle.ticketIDs) {
                applyRules(to: bundle, in: id)
            }
        }
        let snapshot = publish()
        return snapshot.revision == before ? nil : snapshot
    }

    private func loadAll(_ id: String) {
        let folder = projectFolder(id)
        _ = AtomicFile.removeLeftoverTemporaryFiles(in: folder.ticketFolder)
        _ = AtomicFile.removeLeftoverTemporaryFiles(in: folder.bundleFolder)
        var names: Set<String> = []
        for name in Self.names(in: folder.ticketFolder) { names.insert("ticket/" + name) }
        for name in Self.names(in: folder.bundleFolder) { names.insert("bundle/" + name) }
        for ticket in (tickets[id] ?? [:]).keys { names.insert("ticket/\(ticket).yml") }
        for bundle in (bundles[id] ?? [:]).keys { names.insert("bundle/\(bundle).yml") }
        if tickets[id] == nil { tickets[id] = [:] }
        if bundles[id] == nil { bundles[id] = [:] }
        for path in names.sorted() { reload(path, in: id) }
    }

    /// Reads one file again, `path` relative to `.hephaestus/`: a missing file is a deletion; an invalid
    /// file keeps the version loaded and is listed in `invalidFiles`.
    private func reload(_ path: String, in id: String) {
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[1].hasSuffix(".yml") else { return }
        let entity = String(parts[1].dropLast(4))
        let url = projectFolder(id).dataFolder.appendingPathComponent(path)
        if parts[0] == "ticket" {
            guard TicketIDs.parseTicket(entity)?.project == id else { return }
            guard !YAMLFile.isMissing(url) else {
                tickets[id]?[entity] = nil
                invalidFiles[url.path] = nil
                return
            }
            do {
                let file = try YAMLFile.read(TicketFile.self, at: url)
                guard file.id == entity else { throw StorageError.invalidFile(path: url.path, reason: "its id \(file.id) differs from its name") }
                tickets[id, default: [:]][entity] = file
                invalidFiles[url.path] = nil
            } catch {
                invalidFiles[url.path] = (error as? StorageError)?.reason ?? String(describing: error)
            }
        } else if parts[0] == "bundle" {
            guard TicketIDs.parseBundle(entity)?.project == id else { return }
            guard !YAMLFile.isMissing(url) else {
                bundles[id]?[entity] = nil
                invalidFiles[url.path] = nil
                return
            }
            do {
                let file = try YAMLFile.read(BundleFile.self, at: url)
                guard file.id == entity else { throw StorageError.invalidFile(path: url.path, reason: "its id \(file.id) differs from its name") }
                bundles[id, default: [:]][entity] = file
                invalidFiles[url.path] = nil
            } catch {
                invalidFiles[url.path] = (error as? StorageError)?.reason ?? String(describing: error)
            }
        }
    }

    // MARK: Tickets

    /// What a new ticket holds.
    public struct NewTicket: Sendable, Hashable {
        public var projectID: String
        /// Empty: the provisional title, from the description.
        public var title: String
        public var description: String
        /// `todo`, or `draft` (V3) for the user.
        public var status: TicketFileStatus
        public var priority: TicketFilePriority?
        public var labels: [String]
        public var links: [TicketLinkEntry]
        /// Files copied in as the ticket's attachments.
        public var attachments: [URL]
        /// The chats the ticket is linked to: the feedback chat that created it.
        public var chats: [String]

        public init(projectID: String, title: String = "", description: String = "", status: TicketFileStatus = .todo,
                    priority: TicketFilePriority? = nil, labels: [String] = [], links: [TicketLinkEntry] = [], attachments: [URL] = [],
                    chats: [String] = []) {
            self.projectID = projectID
            self.title = title
            self.description = description
            self.status = status
            self.priority = priority
            self.labels = labels
            self.links = links
            self.attachments = attachments
            self.chats = chats
        }
    }

    /// A ticket created without a title, which `set-ticket-title` reads whole through the ticket tools: its id
    /// and project, which the run links, and its provisional title.
    public struct UntitledTicket: Sendable, Hashable {
        public let id: String
        public let projectID: String
        public let provisionalTitle: String
    }

    /// Called with each ticket created without a title, whoever created it (the windows, the feedback, Claude's
    /// `create_ticket`), once its file is written. The app gives it a title with `set-ticket-title`.
    public func onUntitled(_ handler: @escaping @Sendable (UntitledTicket) -> Void) {
        untitledHandler = handler
    }

    /// Gives a ticket the title `set-ticket-title` wrote, as the app on its own (`automatic`), while it still has
    /// the title it was created with; a title the user or Claude gave it since stays. Nil when nothing changed.
    public func setGeneratedTitle(_ title: String, of id: String, replacing provisional: String) throws(TicketError) -> TicketSnapshot? {
        let (stored, _) = try storedTicket(id)
        guard stored.title == provisional, title != provisional else { return nil }
        return try update(id, TicketChange(title: title), by: .automatic)
    }

    /// Creates a ticket: checks everything, takes its number from the project's counter, copies its
    /// attachments, then writes its file (docs/data.md › Changes that touch several files).
    public func create(_ request: NewTicket, by actor: TicketActor) async throws(TicketError) -> (id: String, snapshot: TicketSnapshot) {
        let projectID = request.projectID.uppercased()
        guard roots[projectID] != nil else { throw .notFound("Project \(projectID) not found.") }
        let description = TicketRules.normalized(request.description)
        let hasTitle = !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = hasTitle ? try TicketRules.title(request.title) : TicketRules.provisionalTitle(from: description)
        if !hasTitle, description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .invalid("The description must not be empty.")
        }
        guard request.status == .todo || request.status == .draft else { throw .invalid("A new ticket is To Do or a draft.") }
        let status: TicketFileStatus = actor.isClaude ? .todo : request.status
        let files = try checkedFiles(request.attachments)
        let links = try checkedLinks(request.links, of: nil, in: projectID, declared: [])
        let number: Int
        do {
            number = try await projects.allocateNumber(for: projectID, .ticket)
        } catch {
            throw .project(error)
        }
        let id = TicketIDs.ticket(project: projectID, number: number)
        let date = now()
        let attachments = try copy(files, into: id, in: projectID)
        let file = TicketFile(id: id, title: title, status: status, created: date, createdBy: actor.author, description: description,
                              attachments: attachments, chatIDs: request.chats, links: links,
                              history: [entry(.created, date: date, to: status.rawValue, by: actor)],
                              priority: request.priority, labels: TicketRules.labels(request.labels))
        do {
            try write(file, in: projectID)
        } catch {
            removeCopies(attachments, in: projectID)
            throw error
        }
        let snapshot = publish()
        if !hasTitle {
            untitledHandler?(UntitledTicket(id: id, projectID: projectID, provisionalTitle: title))
        }
        return (id, snapshot)
    }

    /// A change of a ticket's fields; each value set replaces the stored one.
    public struct TicketChange: Sendable, Hashable {
        public var title: String?
        public var description: String?
        /// `.some(nil)` removes the priority.
        public var priority: TicketFilePriority??
        public var labels: [String]?
        /// The whole list of links the ticket declares.
        public var links: [TicketLinkEntry]?

        public init(title: String? = nil, description: String? = nil, priority: TicketFilePriority?? = nil, labels: [String]? = nil,
                    links: [TicketLinkEntry]? = nil) {
            self.title = title
            self.description = description
            self.priority = priority
            self.labels = labels
            self.links = links
        }
    }

    /// Changes a ticket. Its history gains, in this order, the rename, the description edit, one entry per
    /// link removed, then one per link added.
    public func update(_ id: String, _ change: TicketChange, by actor: TicketActor) throws(TicketError) -> TicketSnapshot {
        let (stored, projectID) = try storedTicket(id)
        var file = stored
        let date = now()
        if let title = change.title {
            let title = try TicketRules.title(title)
            if title != file.title {
                file.history.append(entry(.title, date: date, from: file.title, to: title, by: actor))
                file.title = title
            }
        }
        if let description = change.description {
            let description = TicketRules.normalized(description)
                if description != file.description {
                file.history.append(entry(.description, date: date, by: actor))
                file.description = description
            }
        }
        if let priority = change.priority { file.priority = priority }
        if let labels = change.labels { file.labels = TicketRules.labels(labels) }
        if let links = change.links {
            let checked = try checkedLinks(links, of: file.id, in: projectID, declared: file.links)
            func same(_ a: TicketLinkEntry, _ b: TicketLinkEntry) -> Bool { a.kind == b.kind && a.ticketID == b.ticketID }
            for link in file.links where !checked.contains(where: { same($0, link) }) {
                file.history.append(entry(.linkRemoved, date: date, to: "\(link.kind.rawValue) \(link.ticketID)", by: actor))
            }
            for link in checked where !file.links.contains(where: { same($0, link) }) {
                file.history.append(entry(.linkAdded, date: date, to: "\(link.kind.rawValue) \(link.ticketID)", by: actor))
            }
            file.links = checked
        }
        guard file != stored else { return publish() }
        file.updated = date
        try write(file, in: projectID)
        return publish()
    }

    /// Sets a ticket's status. Claude never changes a done ticket, never makes a draft and never changes a
    /// draft (V3); the same status again writes nothing. Then each bundle that lists the ticket follows the
    /// automatic rules, in bundle number order.
    public func setStatus(_ id: String, to status: TicketFileStatus, by actor: TicketActor) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        if actor.isClaude {
            guard file.status != .done else { throw .forbidden("\(file.id) is done; only the user can change its status.") }
            guard file.status != .draft else { throw .forbidden("\(file.id) is a draft; only the user can change its status.") }
            guard status != .draft else { throw .forbidden("Only the user can make \(file.id) a draft.") }
        }
        guard status != file.status else { return publish() }
        let date = now()
        file.history.append(entry(.status, date: date, from: file.status.rawValue, to: status.rawValue, by: actor))
        file.status = status
        file.updated = date
        try write(file, in: projectID)
        for bundle in sortedBundles(projectID) where bundle.ticketIDs.contains(file.id) {
            applyRules(to: bundle, in: projectID)
        }
        return publish()
    }

    /// Deletes tickets: first every bundle that lists them (with the automatic rules in the same write), then
    /// every ticket that links to them, then their files and attachment folders, moved to the Trash.
    public func delete(_ ids: [String]) throws(TicketError) -> TicketSnapshot {
        var byProject: [String: [String]] = [:]
        for id in ids {
            let (file, projectID) = try storedTicket(id)
            if byProject[projectID]?.contains(file.id) != true { byProject[projectID, default: []].append(file.id) }
        }
        let date = now()
        for projectID in byProject.keys.sorted() {
            let removed = byProject[projectID] ?? []
            let gone = Set(removed)
            for var bundle in sortedBundles(projectID) where !gone.isDisjoint(with: bundle.ticketIDs) {
                bundle.ticketIDs.removeAll(where: gone.contains)
                bundle.status = ruledStatus(of: bundle, in: projectID, without: gone)
                bundle.updated = date
                try write(bundle, in: projectID)
            }
            for var ticket in sortedTickets(projectID)
            where !gone.contains(ticket.id) && ticket.links.contains(where: { gone.contains($0.ticketID) }) {
                ticket.links.removeAll { gone.contains($0.ticketID) }
                ticket.updated = date
                try write(ticket, in: projectID)
            }
            let folder = projectFolder(projectID)
            for id in removed {
                try moveToTrash(folder.ticketFolder.appendingPathComponent("\(id).yml"))
                tickets[projectID]?[id] = nil
                let attachments = folder.attachmentsFolder.appendingPathComponent(id, isDirectory: true)
                if FileManager.default.fileExists(atPath: attachments.path) { try moveToTrash(attachments) }
            }
        }
        return publish()
    }

    // MARK: Comments and attachments

    /// Adds a comment: its files first, then the ticket file. A comment has text, files, or both.
    public func addComment(to id: String, text: String, files: [URL], by actor: TicketActor) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        let text = TicketRules.normalized(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
            throw .invalid("A comment needs text or at least one attachment.")
        }
        let checked = try checkedFiles(files)
        let attachments = try copy(checked, into: file.id, in: projectID)
        let date = now()
        file.comments.append(CommentEntry(id: UUID(), author: actor.author, created: date, text: text, attachments: attachments))
        file.updated = date
        do {
            try write(file, in: projectID)
        } catch {
            removeCopies(attachments, in: projectID)
            throw error
        }
        return publish()
    }

    /// Changes a comment's text; its files stay.
    public func updateComment(_ commentID: UUID, of id: String, text: String) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
            throw .notFound("Comment \(commentID.uuidString) not found.")
        }
        let text = TicketRules.normalized(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !file.comments[index].attachments.isEmpty else {
            throw .invalid("A comment needs text or at least one attachment.")
        }
        guard text != file.comments[index].text else { return publish() }
        let date = now()
        file.comments[index].text = text
        file.comments[index].updated = date
        file.updated = date
        try write(file, in: projectID)
        return publish()
    }

    /// Deletes a comment: the ticket file first, then the comment's files, moved to the Trash.
    public func deleteComment(_ commentID: UUID, of id: String) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
            throw .notFound("Comment \(commentID.uuidString) not found.")
        }
        let removed = file.comments.remove(at: index)
        file.updated = now()
        try write(file, in: projectID)
        for attachment in removed.attachments { try trashAttachment(attachment, in: projectID) }
        return publish()
    }

    /// Adds files to a ticket: the files first, then the ticket file.
    public func addAttachments(_ files: [URL], to id: String) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        guard !files.isEmpty else { return publish() }
        let attachments = try copy(try checkedFiles(files), into: file.id, in: projectID)
        file.attachments += attachments
        file.updated = now()
        do {
            try write(file, in: projectID)
        } catch {
            removeCopies(attachments, in: projectID)
            throw error
        }
        return publish()
    }

    /// Removes one of the ticket's own files: the ticket file first, then the file, moved to the Trash. A
    /// comment's file goes only with its comment.
    public func removeAttachment(_ attachmentID: UUID, of id: String) throws(TicketError) -> TicketSnapshot {
        var (file, projectID) = try storedTicket(id)
        guard let index = file.attachments.firstIndex(where: { $0.id == attachmentID }) else {
            throw .notFound("Attachment \(attachmentID.uuidString) not found.")
        }
        let removed = file.attachments.remove(at: index)
        file.updated = now()
        try write(file, in: projectID)
        try trashAttachment(removed, in: projectID)
        return publish()
    }

    /// The file of an attachment path: `attachments/<TICKET-ID>/<file name>`, whose real path lies inside
    /// the project's `.hephaestus/` folder.
    public func attachmentURL(_ path: String, in projectID: String) throws(TicketError) -> URL {
        guard roots[projectID] != nil else { throw .notFound("Project \(projectID) not found.") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let folder = projectFolder(projectID).dataFolder
        let url = folder.appendingPathComponent(path)
        guard parts.count == 3, parts[0] == "attachments", TicketIDs.parseTicket(String(parts[1])) != nil,
              !parts[2].isEmpty, parts[2] != ".", parts[2] != "..",
              url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
            throw .forbidden("The path is outside the attachments folder.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw .notFound("Attachment file \(path) not found.") }
        return url
    }

    // MARK: Bundles

    /// Creates a bundle from at least one ticket: its number from the project's counter, then its file, with
    /// the automatic rules (a bundle of done tickets starts done).
    public func createBundle(in projectID: String, title: String = "", ticketIDs: [String]) async throws(TicketError)
        -> (id: String, snapshot: TicketSnapshot) {
        let projectID = projectID.uppercased()
        guard roots[projectID] != nil else { throw .notFound("Project \(projectID) not found.") }
        guard !ticketIDs.isEmpty else { throw .invalid("A bundle needs at least one ticket.") }
        let list = try checkedBundleTickets(ticketIDs, in: projectID, listed: [])
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let title = hasTitle ? try TicketRules.title(title)
            : TicketRules.provisionalBundleTitle(from: list.compactMap { tickets[projectID]?[$0]?.title })
        let number: Int
        do {
            number = try await projects.allocateNumber(for: projectID, .bundle)
        } catch {
            throw .project(error)
        }
        let id = TicketIDs.bundle(project: projectID, number: number)
        var bundle = BundleFile(id: id, title: title, created: now(), ticketIDs: list)
        bundle.status = ruledStatus(of: bundle, in: projectID)
        try write(bundle, in: projectID)
        return (id, publish())
    }

    /// Changes a bundle's title or tickets. A change of its set of tickets (not a reorder) applies the
    /// automatic rules in the same write. An id the bundle lists already may name a missing ticket.
    public func updateBundle(_ id: String, title: String? = nil, ticketIDs: [String]? = nil) throws(TicketError) -> TicketSnapshot {
        let (stored, projectID) = try storedBundle(id)
        var bundle = stored
        if let title { bundle.title = try TicketRules.title(title) }
        if let ticketIDs {
            bundle.ticketIDs = try checkedBundleTickets(ticketIDs, in: projectID, listed: stored.ticketIDs)
            if Set(bundle.ticketIDs) != Set(stored.ticketIDs) { bundle.status = ruledStatus(of: bundle, in: projectID) }
        }
        guard bundle != stored else { return publish() }
        bundle.updated = now()
        try write(bundle, in: projectID)
        return publish()
    }

    /// Sets a bundle's status: the user any; Claude only To Do and In Progress, never on a done bundle.
    public func setBundleStatus(_ id: String, to status: BundleFile.Status, by actor: TicketActor) throws(TicketError) -> TicketSnapshot {
        var (bundle, projectID) = try storedBundle(id)
        if actor.isClaude {
            guard bundle.status != .done else { throw .forbidden("\(bundle.id) is done; only the user can change its status.") }
            guard status != .done else { throw .forbidden("Only the user can set \(bundle.id) to done.") }
        }
        guard status != bundle.status else { return publish() }
        bundle.status = status
        bundle.updated = now()
        try write(bundle, in: projectID)
        return publish()
    }

    /// Deletes a bundle: its file moves to the Trash; its tickets stay.
    public func deleteBundle(_ id: String) throws(TicketError) -> TicketSnapshot {
        let (bundle, projectID) = try storedBundle(id)
        try moveToTrash(projectFolder(projectID).bundleFolder.appendingPathComponent("\(bundle.id).yml"))
        bundles[projectID]?[bundle.id] = nil
        return publish()
    }

    // MARK: Rules

    /// Checks the links a ticket declares, in order: a link it already declares with the same kind is kept
    /// as it is; any other follows the link rules 1 to 7 (docs/data.md › Link rules).
    private func checkedLinks(_ links: [TicketLinkEntry], of id: String?, in projectID: String,
                              declared: [TicketLinkEntry]) throws(TicketError) -> [TicketLinkEntry] {
        var result: [TicketLinkEntry] = []
        var named: Set<String> = []
        for link in links {
            let other = link.ticketID.uppercased()
            if let kept = declared.first(where: { $0.kind == link.kind && $0.ticketID == other }) {
                guard named.insert(other).inserted else { throw .invalid("\(other) is listed more than once.") }
                result.append(kept)
                continue
            }
            guard let parsed = TicketIDs.parseTicket(other) else { throw .invalid("\"\(link.ticketID)\" is not a valid ticket id.") }
            guard parsed.project == projectID else { throw .invalid("\(other) does not belong to project \(projectID).") }
            if let id, other == id { throw .invalid("\(id) cannot be linked to itself.") }
            guard named.insert(other).inserted else { throw .invalid("\(other) is listed more than once.") }
            guard let target = tickets[projectID]?[other] else { throw .notFound("Ticket \(other) not found.") }
            if let id {
                guard !target.links.contains(where: { $0.ticketID == id }) else { throw .invalid("\(id) is already linked to \(other).") }
                if link.kind == .dependsOn, dependsOn(other, on: id, in: projectID) {
                    throw .invalid("\(id) cannot depend on \(other), which depends on \(id).")
                }
            }
            result.append(TicketLinkEntry(kind: link.kind, ticketID: other))
        }
        return result
    }

    /// Whether `ticket` depends on `target`, directly or through other tickets.
    private func dependsOn(_ ticket: String, on target: String, in projectID: String) -> Bool {
        var seen: Set<String> = []
        var pending = [ticket]
        while let current = pending.popLast() {
            guard seen.insert(current).inserted else { continue }
            for link in tickets[projectID]?[current]?.links ?? [] where link.kind == .dependsOn {
                if link.ticketID == target { return true }
                pending.append(link.ticketID)
            }
        }
        return false
    }

    private func checkedBundleTickets(_ ids: [String], in projectID: String, listed: [String]) throws(TicketError) -> [String] {
        var result: [String] = []
        for raw in ids {
            let id = raw.uppercased()
            guard let parsed = TicketIDs.parseTicket(id) else { throw .invalid("\"\(raw)\" is not a valid ticket id.") }
            guard parsed.project == projectID else { throw .invalid("\(id) does not belong to project \(projectID).") }
            guard !result.contains(id) else { throw .invalid("\(id) is listed more than once.") }
            guard tickets[projectID]?[id] != nil || listed.contains(id) else { throw .notFound("Ticket \(id) not found.") }
            result.append(id)
        }
        return result
    }

    /// The status the automatic rules give a bundle. Complete: it lists tickets, all done (a missing one
    /// isn't). Reopened: done, with one that isn't. A bundle without tickets keeps its status.
    private func ruledStatus(of bundle: BundleFile, in projectID: String, without gone: Set<String> = []) -> BundleFile.Status {
        guard !bundle.ticketIDs.isEmpty else { return bundle.status }
        if isComplete(bundle, in: projectID, without: gone) { return .done }
        return bundle.status == .done ? .inProgress : bundle.status
    }

    private func applyRules(to bundle: BundleFile, in projectID: String) {
        let status = ruledStatus(of: bundle, in: projectID)
        guard status != bundle.status else { return }
        var changed = bundle
        changed.status = status
        changed.updated = now()
        try? write(changed, in: projectID)
    }

    private func isComplete(_ bundle: BundleFile, in projectID: String, without gone: Set<String> = []) -> Bool {
        !bundle.ticketIDs.isEmpty && bundle.ticketIDs.allSatisfy { !gone.contains($0) && tickets[projectID]?[$0]?.status == .done }
    }

    // MARK: Files

    private func write(_ ticket: TicketFile, in projectID: String) throws(TicketError) {
        let url = projectFolder(projectID).ticketFolder.appendingPathComponent("\(ticket.id).yml")
        do {
            try YAMLFile.write(ticket, to: url, ownWrites: ownWrites)
        } catch {
            throw .storage(error)
        }
        tickets[projectID, default: [:]][ticket.id] = ticket
        invalidFiles[url.path] = nil
    }

    private func write(_ bundle: BundleFile, in projectID: String) throws(TicketError) {
        let url = projectFolder(projectID).bundleFolder.appendingPathComponent("\(bundle.id).yml")
        do {
            try YAMLFile.write(bundle, to: url, ownWrites: ownWrites)
        } catch {
            throw .storage(error)
        }
        bundles[projectID, default: [:]][bundle.id] = bundle
        invalidFiles[url.path] = nil
    }

    /// Each file must be a readable regular file of at most 20 MiB, and all of them at most 20 MiB together.
    private func checkedFiles(_ files: [URL]) throws(TicketError) -> [(url: URL, size: Int)] {
        var result: [(url: URL, size: Int)] = []
        var total = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
            guard values?.isRegularFile == true, values?.isReadable == true, let size = values?.fileSize else {
                throw .invalid("\(url.path) is not a readable file.")
            }
            guard size <= TicketRules.attachmentLimit else { throw .invalid("\(url.lastPathComponent) is larger than 20 MB.") }
            total += size
            result.append((url, size))
        }
        guard total <= TicketRules.attachmentLimit else { throw .invalid("The attachments of one request exceed 20 MB.") }
        return result
    }

    /// Copies files into `attachments/<TICKET-ID>/<id>-<name>`, each under a new id. A failure removes the
    /// copies made.
    private func copy(_ files: [(url: URL, size: Int)], into ticketID: String, in projectID: String) throws(TicketError) -> [AttachmentEntry] {
        let folder = projectFolder(projectID)
        var result: [AttachmentEntry] = []
        for file in files {
            let id = UUID()
            let name = TicketRules.attachmentName(file.url.lastPathComponent, id: id)
            let path = "attachments/\(ticketID)/\(id.uuidString)-\(name)"
            let destination = folder.dataFolder.appendingPathComponent(path)
            do {
                let data = try Data(contentsOf: file.url)
                let digest = try AtomicFile.write(data, to: destination)
                ownWrites.recordWrite(path: AtomicFile.resolvedDestination(destination).path, sha256: digest)
                result.append(AttachmentEntry(id: id, name: name, path: path, contentType: TicketRules.contentType(of: name), size: data.count))
            } catch {
                removeCopies(result, in: projectID)
                if let error = error as? StorageError { throw .storage(error) }
                throw .invalid("\(file.url.path) is not a readable file.")
            }
        }
        return result
    }

    /// Removes the copies a failed change made; they were never referenced.
    private func removeCopies(_ attachments: [AttachmentEntry], in projectID: String) {
        let folder = projectFolder(projectID).dataFolder
        for attachment in attachments {
            let url = folder.appendingPathComponent(attachment.path)
            ownWrites.recordRemoval(path: url.path)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func trashAttachment(_ attachment: AttachmentEntry, in projectID: String) throws(TicketError) {
        guard let url = try? attachmentURL(attachment.path, in: projectID) else { return }
        try moveToTrash(url)
    }

    private func moveToTrash(_ url: URL) throws(TicketError) {
        ownWrites.recordRemoval(path: url.path)
        do {
            try trash.move(url)
        } catch let error as StorageError {
            throw .storage(error)
        } catch {
            throw .storage(.trashFailed(path: url.path, reason: String(describing: error)))
        }
    }

    // MARK: Snapshot

    private func publish() -> TicketSnapshot {
        var snapshot = TicketSnapshot(revision: last.revision, invalidFiles: invalidFiles)
        for projectID in tickets.keys {
            let sorted = sortedTickets(projectID)
            var inverse: [String: [LoadedTicket.InverseLink]] = [:]
            for other in sorted {
                for link in other.links {
                    inverse[link.ticketID, default: []].append(.init(kind: link.kind == .dependsOn ? .blocks : .related, ticketID: other.id))
                }
            }
            snapshot.tickets[projectID] = sorted.map { LoadedTicket(file: $0, projectID: projectID, inverseLinks: inverse[$0.id] ?? []) }
        }
        for projectID in bundles.keys {
            snapshot.bundles[projectID] = sortedBundles(projectID)
        }
        if snapshot != last {
            revision += 1
            snapshot.revision = revision
            last = snapshot
        }
        return last
    }

    // MARK: Helpers

    private func entry(_ kind: HistoryEntry.Kind, date: Date, from: String? = nil, to: String? = nil, by actor: TicketActor) -> HistoryEntry {
        HistoryEntry(kind: kind, date: date, from: from, to: to, author: actor.historyAuthor, device: actor.device, chat: actor.chat)
    }

    private func storedTicket(_ value: String) throws(TicketError) -> (file: TicketFile, projectID: String) {
        let id = value.uppercased()
        guard let projectID = TicketIDs.parseTicket(id)?.project else { throw .invalid("\"\(value)\" is not a valid ticket id.") }
        guard let file = tickets[projectID]?[id] else { throw .notFound("Ticket \(id) not found.") }
        return (file, projectID)
    }

    private func storedBundle(_ value: String) throws(TicketError) -> (file: BundleFile, projectID: String) {
        let id = value.uppercased()
        guard let projectID = TicketIDs.parseBundle(id)?.project else { throw .invalid("\"\(value)\" is not a valid bundle id.") }
        guard let file = bundles[projectID]?[id] else { throw .notFound("Bundle \(id) not found.") }
        return (file, projectID)
    }

    private func projectFolder(_ projectID: String) -> ProjectFolder {
        ProjectFolder(root: URL(fileURLWithPath: roots[projectID] ?? "/", isDirectory: true))
    }

    private func sortedTickets(_ projectID: String) -> [TicketFile] {
        (tickets[projectID] ?? [:]).values.sorted { (TicketIDs.parseTicket($0.id)?.number ?? 0) < (TicketIDs.parseTicket($1.id)?.number ?? 0) }
    }

    private func sortedBundles(_ projectID: String) -> [BundleFile] {
        (bundles[projectID] ?? [:]).values.sorted { (TicketIDs.parseBundle($0.id)?.number ?? 0) < (TicketIDs.parseBundle($1.id)?.number ?? 0) }
    }

    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".yml") && !AtomicFile.isTemporaryFileName($0) }.sorted()
    }
}
