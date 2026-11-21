import Foundation
import Observation
import TicketData
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
struct NewTicketDraft: Hashable, Sendable {
    var title = ""
    var details = ""
    /// Medium by default; none leaves the ticket without a priority.
    var priority: TicketPriority? = .medium
    var startsAsDraft = true
    /// The project the ticket goes to: the window's project or one of its sub projects.
    var projectID: Project.ID

    /// A ticket needs a title with more than spaces in it.
    var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the ticket editor holds while the title, description, priority and labels are being changed.
struct TicketEdit: Hashable {
    let ticketID: Ticket.ID
    var title: String
    var details: String
    var priority: TicketPriority?
    /// The labels, comma separated.
    var labels: String

    init(_ ticket: Ticket) {
        ticketID = ticket.id
        title = ticket.title
        details = ticket.details
        priority = ticket.priority
        labels = ticket.labels.joined(separator: ", ")
    }

    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var labelList: [String] {
        labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// What asks for a confirmation before it happens.
enum TicketConfirmation: Hashable, Identifiable {
    case deleteTickets([Ticket.ID])
    case deleteBundle(TicketBundle.ID)
    case deleteComment(Ticket.ID, UUID)
    case removeAttachment(Ticket.ID, TicketAttachment)

    var id: Self { self }
}

/// The sheet that picks tickets: a new bundle's, or a bundle's tickets.
struct BundleDraft: Hashable, Identifiable {
    /// The bundle being changed; nil for a new one.
    let bundleID: TicketBundle.ID?
    let projectID: Project.ID
    var title: String
    var ticketIDs: [Ticket.ID]

    var id: String { bundleID ?? "new-\(projectID)" }
}

/// The Tickets window: its tickets, the sidebar's filter, the selection, what a route's focus selects,
/// the sheets, and every change the window makes through its store.
///
/// A project with sub projects also lists their tickets, at any depth, grouped by project.
/// Its bundles stay its own: a bundle never spans projects.
@Observable
final class TicketsModel {
    /// The window's project.
    let project: Project
    @ObservationIgnored let store: any TicketStore
    @ObservationIgnored let directory: ProjectDirectory
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
    /// The files waiting to go with each ticket's next comment.
    private(set) var commentFiles: [Ticket.ID: [URL]] = [:]
    /// The ticket being edited, with what the editor holds.
    var edit: TicketEdit?
    /// The comment being edited and its text.
    var commentEdit: (ticketID: Ticket.ID, commentID: UUID, text: String)?
    /// The Add Link sheet's ticket.
    var linkingTicket: Ticket.ID?
    /// The bundle sheet, while open.
    var bundleDraft: BundleDraft?
    /// What waits for a confirmation.
    var confirmation: TicketConfirmation?
    /// The ticket whose Implement waits for the answer to the dependencies alert, and the action it then calls.
    var implementPending: (ticket: Ticket, action: ImplementAction)?
    /// The message of the last change that failed, shown in an alert.
    var failure: String?
    /// True while a change runs.
    private(set) var isWorking = false

    /// The window of `project`, with `focus` (a ticket id) selected; without one, the first ticket of
    /// the list.
    init(project: Project, focus: String?, filter: TicketFilter = .all, store: any TicketStore,
         directory: ProjectDirectory = .previewSamples) {
        self.project = project
        self.store = store
        self.directory = directory
        self.opensSelection = focus != nil
        self.filter = filter
        self.draft = NewTicketDraft(projectID: project.id)
        self.selection = nil
        selection = focus ?? visibleTickets.first?.id
    }

    /// The project and its sub projects, in tree order.
    var family: [Project] {
        let family = directory.tree.family(of: project.id)
        return family.isEmpty ? [project] : family
    }

    /// The tickets of the project and its sub projects, in the store's order.
    var tickets: [Ticket] {
        store.tickets(of: Set(family.map(\.id)))
    }

    /// The window's own bundles, for the sidebar: a parent lists only its own (the user's choice).
    var bundles: [TicketBundle] {
        store.bundles(of: [project.id])
    }

    /// The bundles of the whole family, for the Bundle property of a sub project's ticket.
    private var familyBundles: [TicketBundle] {
        store.bundles(of: Set(family.map(\.id)))
    }

    // MARK: The list

    /// Whether the list groups the tickets by project: for a project with sub projects.
    var isGrouped: Bool {
        family.count > 1
    }

    /// The depth of a family member under the window's project, for the sidebar's indent.
    func indent(of member: Project) -> Int {
        directory.tree.depth(of: member.id) - directory.tree.depth(of: project.id)
    }

    /// The sidebar's sections, in order. The Projects section only for a project with sub projects; the
    /// Bundles section always, with its New Bundle button.
    var filterSections: [TicketFilterSection] {
        [.status] + (isGrouped ? [.projects] : []) + [.bundles]
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
        switch store.phase {
        case .loading: return .loading
        case .failed(let message): return .failed(message: message)
        case .ready: break
        }
        let tickets = tickets
        if tickets.isEmpty { return .empty }
        if isGrouped {
            let groups = groups
            return groups.isEmpty ? .noMatch(noMatchMessage) : .grouped(groups)
        }
        let visible = tickets.filter(passesFilter)
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
            directory.tree.family(of: id).contains { $0.id == ticket.projectID } || id == ticket.projectID
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
        selection.flatMap(ticket)
    }

    /// One of the window's tickets.
    func ticket(_ id: Ticket.ID) -> Ticket? {
        tickets.first { $0.id == id }
    }

    /// The id a route asked for that names none of the window's tickets.
    var missingSelection: Ticket.ID? {
        selectedTicket == nil && store.phase == .ready ? selection : nil
    }

    /// Selects the ticket a route asked for, even when it was selected before and the user has picked
    /// another since. A filter that hides it gives way to All Tickets, so its row shows.
    func select(focus: String) {
        if TicketIDs.parseBundle(focus) != nil, bundles.contains(where: { $0.id == focus }) {
            filter = .bundle(focus)
            return
        }
        selection = focus
        if let ticket = ticket(focus), !passesFilter(ticket) {
            filter = .all
        }
    }

    /// The bundles `ticket` is in: its own project's, so a sub project's ticket shows them in a parent's
    /// window too.
    func bundles(of ticket: Ticket) -> [TicketBundle] {
        familyBundles.filter { $0.projectID == ticket.projectID && $0.ticketIDs.contains(ticket.id) }
    }

    /// The selected ticket, as the chat panel asks about it.
    var chatSubject: ChatReference? {
        selectedTicket.map(TicketsReader.reference)
    }

    // MARK: Changes

    /// Makes a change through the store; a failure shows its message. Returns what the change created.
    @discardableResult
    func perform(_ change: TicketChangeRequest) async -> String? {
        isWorking = true
        defer { isWorking = false }
        do {
            return try await store.perform(change) ?? ""
        } catch {
            failure = error.message
            return nil
        }
    }

    /// Sets the status of the selected ticket.
    func setStatus(_ status: TicketStatus, of ids: [Ticket.ID]) async {
        await perform(.setStatus(ids, status))
    }

    /// Moves a ticket one step forward: Draft to Created, then In Progress, In Review and Done.
    func nextStep(of ticket: Ticket) async {
        guard let next = ticket.status.next else { return }
        await perform(.setStatus([ticket.id], next))
    }

    /// Deletes once confirmed: tickets, a bundle, a comment or an attachment.
    func confirm(_ confirmation: TicketConfirmation) async {
        switch confirmation {
        case .deleteTickets(let ids):
            if await perform(.delete(ids)) != nil, let selection, ids.contains(selection) {
                self.selection = visibleTickets.first?.id
            }
        case .deleteBundle(let id):
            if await perform(.deleteBundle(id)) != nil, filter == .bundle(id) { filter = .all }
        case let .deleteComment(ticketID, commentID):
            await perform(.deleteComment(ticketID, commentID))
        case let .removeAttachment(ticketID, attachment):
            await perform(.removeAttachment(ticketID, attachment.id))
        }
    }

    // MARK: Editing

    func startEditing(_ ticket: Ticket) {
        edit = TicketEdit(ticket)
    }

    func cancelEditing() {
        edit = nil
    }

    /// Saves the editor's values; the editor stays open with them when a rule fails.
    func saveEditing() async {
        guard let edit, edit.canSave else { return }
        if await perform(.edit(edit.ticketID, title: edit.title, details: edit.details, priority: edit.priority, labels: edit.labelList)) != nil {
            self.edit = nil
        }
    }

    func setPriority(_ priority: TicketPriority?, of ticket: Ticket) async {
        await perform(.setPriority(ticket.id, priority))
    }

    // MARK: Links

    /// The links `ticket` declares, as the store takes them.
    func declaredLinks(of ticket: Ticket) -> [TicketLinkDraft] {
        ticket.links.filter(\.isDeclared).map { TicketLinkDraft(kind: $0.kind == .dependsOn ? .dependsOn : .related, ticketID: $0.target) }
    }

    /// The tickets `ticket` can link to: the others of its project it isn't linked to yet.
    func linkCandidates(for ticket: Ticket) -> [Ticket] {
        let linked = Set(ticket.links.filter(\.kind.isTicket).map(\.target))
        return store.tickets(of: [ticket.projectID]).filter { $0.id != ticket.id && !linked.contains($0.id) }
    }

    func addLink(_ link: TicketLinkDraft, to ticket: Ticket) async -> Bool {
        await perform(.setLinks(ticket.id, declaredLinks(of: ticket) + [link])) != nil
    }

    func removeLink(_ link: TicketLink, from ticket: Ticket) async {
        await perform(.setLinks(ticket.id, declaredLinks(of: ticket).filter { $0.ticketID != link.target }))
    }

    // MARK: Comments

    /// What is typed in `ticket`'s comment field. Each ticket keeps its own.
    func commentDraft(for ticket: Ticket.ID) -> String {
        commentDrafts[ticket, default: ""]
    }

    func setCommentDraft(_ text: String, for ticket: Ticket.ID) {
        commentDrafts[ticket] = text.isEmpty ? nil : text
    }

    /// The files waiting to go with `ticket`'s next comment.
    func files(for ticket: Ticket.ID) -> [URL] {
        commentFiles[ticket, default: []]
    }

    func attach(_ files: [URL], to ticket: Ticket.ID) {
        commentFiles[ticket, default: []] += files.filter { !commentFiles[ticket, default: []].contains($0) }
    }

    func detach(_ file: URL, from ticket: Ticket.ID) {
        commentFiles[ticket]?.removeAll { $0 == file }
        if commentFiles[ticket]?.isEmpty == true { commentFiles[ticket] = nil }
    }

    /// Whether `ticket`'s comment can be sent: text with more than spaces, or a file.
    func canComment(on ticket: Ticket.ID) -> Bool {
        !commentDraft(for: ticket).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files(for: ticket).isEmpty
    }

    /// Sends the comment; the field and its files empty once it is added, and keep it when it fails.
    func sendComment(on ticket: Ticket.ID) async {
        guard canComment(on: ticket) else { return }
        if await perform(.addComment(ticket, text: commentDraft(for: ticket), files: files(for: ticket))) != nil {
            commentDrafts[ticket] = nil
            commentFiles[ticket] = nil
        }
    }

    func startEditingComment(_ event: TicketEvent, of ticket: Ticket.ID) {
        guard let commentID = event.commentID else { return }
        commentEdit = (ticket, commentID, event.comment ?? "")
    }

    func saveComment() async {
        guard let commentEdit else { return }
        if await perform(.editComment(commentEdit.ticketID, commentEdit.commentID, text: commentEdit.text)) != nil {
            self.commentEdit = nil
        }
    }

    // MARK: Attachments

    func addAttachments(_ files: [URL], to ticket: Ticket.ID) async {
        guard !files.isEmpty else { return }
        await perform(.addAttachments(ticket, files))
    }

    /// The file of an attachment of `ticket`, to open it.
    func url(of attachment: TicketAttachment, in ticket: Ticket) async -> URL? {
        await store.url(of: attachment, in: ticket.projectID)
    }

    // MARK: Bundles

    /// Opens the bundle sheet for a new bundle, with `tickets` checked.
    func startNewBundle(with tickets: [Ticket.ID] = []) {
        bundleDraft = BundleDraft(bundleID: nil, projectID: project.id, title: "", ticketIDs: tickets)
    }

    /// Opens the bundle sheet on a bundle's title and tickets.
    func startEditing(_ bundle: TicketBundle) {
        bundleDraft = BundleDraft(bundleID: bundle.id, projectID: bundle.projectID, title: bundle.title, ticketIDs: bundle.ticketIDs)
    }

    /// The tickets a bundle can hold: its project's.
    func bundleCandidates(in projectID: Project.ID) -> [Ticket] {
        store.tickets(of: [projectID])
    }

    func saveBundle() async {
        guard let draft = bundleDraft else { return }
        let done: Bool
        if let id = draft.bundleID {
            done = await perform(.editBundle(id, title: draft.title, tickets: draft.ticketIDs)) != nil
        } else if let id = await perform(.createBundle(draft.projectID, title: draft.title, tickets: draft.ticketIDs)) {
            done = true
            filter = .bundle(id)
        } else {
            done = false
        }
        if done { bundleDraft = nil }
    }

    /// Adds a ticket to a bundle, after its other tickets.
    func add(_ ticket: Ticket, to bundle: TicketBundle) async {
        guard !bundle.ticketIDs.contains(ticket.id) else { return }
        await perform(.editBundle(bundle.id, title: nil, tickets: bundle.ticketIDs + [ticket.id]))
    }

    func remove(_ ticket: Ticket, from bundle: TicketBundle) async {
        await perform(.editBundle(bundle.id, title: nil, tickets: bundle.ticketIDs.filter { $0 != ticket.id }))
    }

    func setStatus(_ status: BundleStatus, of bundle: TicketBundle) async {
        await perform(.setBundleStatus(bundle.id, status))
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

    /// Creates the ticket; the sheet closes and the new ticket is selected, with the filters that would hide
    /// it cleared. A failure keeps the sheet open with what was typed.
    func createNewTicket() async {
        guard draft.canCreate else { return }
        guard let id = await perform(.create(draft)) else { return }
        isComposing = false
        if let ticket = ticket(id), !passesFilter(ticket) { filter = .all }
        selection = id
    }
}
