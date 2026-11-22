import AZDesign
import SwiftUI
import ToolsFoundation

/// The Tickets window for one project: sidebar of statuses, projects and bundles, ticket list, ticket
/// detail. `TicketsModel` holds the tickets, the filter, the selection and what a route selects; the
/// view holds only how the panes are laid out.
/// What a tab keeps of Tickets while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class TicketsTabState {
    let model: TicketsModel

    public init(project: Project, focus: String? = nil, store: LiveTicketStore, directory: ProjectDirectory) {
        model = TicketsModel(project: project, focus: focus, store: store, directory: directory)
    }
}

public struct TicketsRootView: View {
    @State private var model: TicketsModel

    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.windowLayout) private var layout
    /// The sidebar folds away in an iPad's layout, behind its button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The New Ticket sheet's width in an iPhone's layout: the window's, less 12 pt on each side, up to
    /// the Mac's 480 pt.
    @State private var phoneSheetWidth: CGFloat = 480

    /// The Tickets window of `project` on the app's tickets, with `focus` (a ticket id) selected when it
    /// opens. A later route's focus arrives as a focus request.
    public init(project: Project, focus: String? = nil, store: LiveTicketStore, directory: ProjectDirectory) {
        _model = State(initialValue: TicketsModel(project: project, focus: focus, store: store, directory: directory))
    }

    init(model: TicketsModel) {
        _model = State(initialValue: model)
    }

    /// The Tickets a tab keeps.
    public init(state: TicketsTabState) {
        self.init(model: state.model)
    }

    public var body: some View {
        Group {
            if layout == .phone {
                phoneBody
            } else {
                splitBody
            }
        }
        .onGeometryChange(for: CGFloat.self) { min(480, max($0.size.width - 24, 300)) } action: { phoneSheetWidth = $0 }
        .sheet(isPresented: $model.isComposing) {
            NewTicketView(
                draft: $model.draft,
                projects: model.newTicketProjects,
                width: layout == .phone ? phoneSheetWidth : nil,
                onCancel: { model.cancelNewTicket() },
                onCreate: { Task { await model.createNewTicket() } }
            )
        }
        .sheet(item: Binding { model.linkingTicket.flatMap(model.ticket) } set: { model.linkingTicket = $0?.id }) { ticket in
            AddLinkSheet(ticket: ticket, candidates: model.linkCandidates(for: ticket), onCancel: { model.linkingTicket = nil }) { link in
                Task { if await model.addLink(link, to: ticket) { model.linkingTicket = nil } }
            }
        }
        .sheet(item: $model.bundleDraft) { draft in
            BundleSheet(draft: Binding { model.bundleDraft ?? draft } set: { model.bundleDraft = $0 },
                        candidates: model.bundleCandidates(in: draft.projectID),
                        onCancel: { model.bundleDraft = nil }, onSave: { Task { await model.saveBundle() } })
        }
        .alert(String(localized: "The Change Failed", bundle: #bundle), isPresented: Binding { model.failure != nil } set: { if !$0 { model.failure = nil } }) {
            Button(String(localized: "OK", bundle: #bundle)) { model.failure = nil }
        } message: {
            Text(verbatim: model.failure ?? "")
        }
        .alert(confirmationTitle, isPresented: Binding { model.confirmation != nil } set: { if !$0 { model.confirmation = nil } },
               presenting: model.confirmation) { confirmation in
            Button(confirmationAction(confirmation), role: .destructive) {
                Task { await model.confirm(confirmation) }
            }
            Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) {}
        } message: { confirmation in
            Text(verbatim: confirmationMessage(confirmation))
        }
        .implementAlert(model)
        // A route to a ticket of this open window selects it again, even after the user picked another.
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // File ▸ New Ticket… (⇧⌘N) opens the sheet, as the toolbar's New Ticket does.
        .newItemCommand(String(localized: "New Ticket…", bundle: #bundle, comment: "File menu item, ⇧⌘N")) {
            model.startNewTicket()
        }
        // The chat panel beside the window asks about the selected ticket.
        .onChange(of: model.selection, initial: true) {
            reportChatSubject(model.chatSubject)
        }
        .onChange(of: layout, initial: true) {
            columnVisibility = layout == .mac ? .all : .doubleColumn
        }
    }

    /// The Mac's three columns; an iPad's list and ticket, the sidebar behind its button.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TicketSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } content: {
            list
                // The filter shows above the list while the sidebar is hidden.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if columnVisibility != .all {
                        filterBar
                    }
                }
                // The ticket's column has the chat panel's button; the list's would repeat it.
                .environment(\.chatPanel, nil)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            Group {
                if let ticket = model.selectedTicket {
                    detail(of: ticket)
                } else if let id = model.missingSelection {
                    TicketNotFoundView(id: id, project: model.project)
                } else {
                    ContentUnavailableView(
                        String(localized: "No Ticket Selected", bundle: #bundle),
                        systemImage: "ticket",
                        description: Text("Pick a ticket to see its details.", bundle: #bundle)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.canvas)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tickets.detail.empty")
                }
            }
            .toolbar {
                actions(for: model.selectedTicket)
                // The ticket's actions start at the column's left edge; the button goes to its right.
                ChatPanelToolbarItem(pushesToTrailingEdge: true)
            }
        }
    }

    /// An iPhone's: the list, the sidebar's choices in a menu, then a ticket's page with Back.
    private var phoneBody: some View {
        PhoneStack(selection: $model.selection, opensSelection: model.opensSelection) {
            list
                .safeAreaInset(edge: .top, spacing: 0) {
                    filterBar
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        TicketFilterMenu(model: model)
                    }
                }
            // The list adds New Ticket and the chat panel's button after the filter.
        } page: { id in
            Group {
                if let ticket = model.ticket(id) {
                    detail(of: ticket)
                } else {
                    TicketNotFoundView(id: id, project: model.project)
                }
            }
            .toolbar {
                actions(for: model.ticket(id), isCompact: true)
                ChatPanelToolbarItem()
            }
        }
    }

    private var list: some View {
        listView
            .safeAreaInset(edge: .top, spacing: 0) {
                UnreadableFilesBar(files: model.unreadableFiles)
            }
    }

    private var listView: some View {
        TicketListView(
            state: model.listState,
            selection: $model.selection,
            onNewTicket: { model.startNewTicket() },
            onShowAll: { model.showAllTickets() },
            onRetry: { Task { await model.store.retry() } },
            onDelete: { ids in model.confirmation = .deleteTickets(ids) }
        ) { ids in
            TicketMenu(model: model, ids: ids)
        }
    }

    private func actions(for ticket: Ticket?, isCompact: Bool = false) -> TicketActions {
        TicketActions(ticket: ticket, isCompact: isCompact, isWorking: model.isWorking) {
            if let ticket { Task { await model.nextStep(of: ticket) } }
        } onChangeStatus: { status in
            if let ticket { Task { await model.setStatus(status, of: [ticket.id]) } }
        }
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case .deleteTickets(let ids)?:
            ids.count == 1 ? String(localized: "Delete \(ids[0])?", bundle: #bundle)
                : String(localized: "Delete \(ids.count) tickets?", bundle: #bundle)
        case .deleteBundle(let id)?: String(localized: "Delete \(id)?", bundle: #bundle)
        case .deleteComment?: String(localized: "Delete this comment?", bundle: #bundle)
        case .removeAttachment(_, let attachment)?: String(localized: "Remove \(attachment.name)?", bundle: #bundle)
        case nil: ""
        }
    }

    private func confirmationAction(_ confirmation: TicketConfirmation) -> String {
        if case .removeAttachment = confirmation { return String(localized: "Remove", bundle: #bundle) }
        return String(localized: "Delete", bundle: #bundle)
    }

    private func confirmationMessage(_ confirmation: TicketConfirmation) -> String {
        switch confirmation {
        case .deleteTickets: String(localized: "Their files and attachments move to the Trash.", bundle: #bundle)
        case .deleteBundle: String(localized: "Its tickets are kept.", bundle: #bundle)
        case .deleteComment: String(localized: "Its attachments move to the Trash.", bundle: #bundle)
        case .removeAttachment: String(localized: "The file moves to the Trash.", bundle: #bundle)
        }
    }

    /// The filter that applies, when it isn't All Tickets.
    @ViewBuilder private var filterBar: some View {
        if model.isFiltered, let filter = model.filter {
            TicketFilterBar(title: model.title(of: filter), symbol: model.symbol(of: filter), onClear: { model.showAllTickets() })
        }
    }

    private func detail(of ticket: Ticket) -> some View {
        TicketDetailView(ticket: ticket, model: model)
    }
}

/// The context menu of the list's selected tickets: Copy ID, Implement…, Set Status, Add to Bundle, Delete.
private struct TicketMenu: View {
    let model: TicketsModel
    let ids: Set<Ticket.ID>

    @Environment(\.implement) private var implement

    var body: some View {
        let tickets = model.tickets.filter { ids.contains($0.id) }
        if !tickets.isEmpty {
            Button(tickets.count == 1 ? String(localized: "Copy ID", bundle: #bundle) : String(localized: "Copy IDs", bundle: #bundle),
                   systemImage: "doc.on.doc") {
                TicketIDCopy.copy(tickets.map(\.id))
            }
            Divider()
            if tickets.count == 1, let ticket = tickets.first, let implement {
                Button(String(localized: "Implement…", bundle: #bundle, comment: "Starts a chat in which Claude implements the ticket"),
                       systemImage: "hammer") {
                    model.implement(ticket, with: implement)
                }
                .disabled(model.implementRefusal(of: ticket) != nil)
                Divider()
            }
            Menu(String(localized: "Set Status", bundle: #bundle)) {
                ForEach(TicketStatus.allCases) { status in
                    Button(status.title, systemImage: status.symbol) {
                        Task { await model.setStatus(status, of: tickets.map(\.id)) }
                    }
                }
            }
            if tickets.count == 1, let ticket = tickets.first {
                let projectBundles = model.store.bundles(of: [ticket.projectID])
                Menu(String(localized: "Add to Bundle", bundle: #bundle)) {
                    ForEach(projectBundles.filter { !$0.ticketIDs.contains(ticket.id) }) { bundle in
                        Button(bundle.title) { Task { await model.add(ticket, to: bundle) } }
                    }
                    Divider()
                    Button(String(localized: "New Bundle…", bundle: #bundle)) { model.startNewBundle(with: [ticket.id]) }
                }
                ForEach(projectBundles.filter { $0.ticketIDs.contains(ticket.id) }) { bundle in
                    Button(String(localized: "Remove from \(bundle.title)", bundle: #bundle)) {
                        Task { await model.remove(ticket, from: bundle) }
                    }
                }
            }
            Divider()
            Button(String(localized: "Delete…", bundle: #bundle), role: .destructive) {
                model.confirmation = .deleteTickets(tickets.map(\.id))
            }
        }
    }
}

/// The sidebar: every ticket, one row per status with its count, the projects of a parent, then the
/// bundles with their progress.
private struct TicketSidebar: View {
    @Environment(\.chatMentions) private var chatMentions
    @Environment(\.itemChats) private var itemChats
    @Environment(\.implement) private var implement
    @Environment(\.openRoute) private var openRoute
    @Bindable var model: TicketsModel

    var body: some View {
        List(selection: $model.filter) {
            Label(String(localized: "All Tickets", bundle: #bundle), systemImage: "tray.full")
                .badge(model.count(.all))
                .tag(TicketFilter.all)
                .accessibilityIdentifier("tickets.sidebar.all")

            ForEach(model.filterSections) { section in
                switch section {
                case .status: statusSection
                case .projects: projectsSection
                case .bundles: bundlesSection
                }
            }
        }
        // ⌘⌫ (Edit ▸ Delete) on a selected bundle asks as Delete Bundle… does, as V2's bundle list did; on the
        // other rows, which are filters, it does nothing.
        .onDeleteCommand {
            if case .bundle(let id)? = model.filter {
                model.confirmation = .deleteBundle(id)
            }
        }
    }

    private var statusSection: some View {
        Section {
            ForEach(TicketStatus.allCases) { status in
                Label(status.title, systemImage: status.symbol)
                    .badge(model.count(.status(status)))
                    .tag(TicketFilter.status(status))
                    .accessibilityIdentifier("tickets.sidebar.\(status.rawValue)")
            }
        } header: {
            SectionHeader(title: TicketWords.status)
        }
    }

    private var projectsSection: some View {
        Section {
            ForEach(model.family) { member in
                Label {
                    Text(verbatim: member.name)
                } icon: {
                    ProjectIcon(member)
                }
                .badge(model.count(.project(member.id)))
                .padding(.leading, CGFloat(model.indent(of: member)) * 14)
                .tag(TicketFilter.project(member.id))
                .accessibilityIdentifier("tickets.sidebar.project.\(member.id)")
            }
        } header: {
            SectionHeader(title: String(localized: "Projects", bundle: #bundle))
        }
    }

    private var bundlesSection: some View {
        Section {
            ForEach(model.bundles) { bundle in
                BundleRow(bundle: bundle, done: model.doneCount(of: bundle))
                    .tag(TicketFilter.bundle(bundle.id))
                    .accessibilityIdentifier("tickets.sidebar.bundle.\(bundle.id)")
                    .contextMenu {
                        if let implement {
                            // V2's Implement All: a bundle To Do with a ticket left (docs/ui/tickets.md › Implement).
                            Button(String(localized: "Implement All…", bundle: #bundle, comment: "Starts a chat in which Claude implements a bundle"),
                                   systemImage: "hammer") {
                                implement(TicketsModel.target(bundle))
                            }
                            .disabled(!model.canImplement(bundle))
                            .accessibilityIdentifier("tickets.sidebar.bundle.\(bundle.id).implement")
                            Divider()
                        }
                        Button(String(localized: "Edit Bundle…", bundle: #bundle)) { model.startEditing(bundle) }
                        Menu(String(localized: "Set Status", bundle: #bundle)) {
                            ForEach(BundleStatus.allCases) { status in
                                Button(status.title, systemImage: status.symbol) {
                                    Task { await model.setStatus(status, of: bundle) }
                                }
                                .disabled(status == bundle.status)
                            }
                        }
                        if let itemChats {
                            // The bundle's chats, each followed by the ticket chats it started.
                            let chats = itemChats(bundle.id)
                            Menu(String(localized: "Chats", bundle: #bundle, comment: "A ticket's own chats")) {
                                if chats.isEmpty {
                                    Text("No Chats", bundle: #bundle)
                                }
                                ForEach(chats) { chat in
                                    Button(chat.title) { openRoute(.tool(.chat, project: chat.projectID, focus: chat.id)) }
                                }
                            }
                            .accessibilityIdentifier("tickets.sidebar.bundle.\(bundle.id).chats")
                        }
                        if let chatMentions {
                            // V2's Mentioned In of a bundle: the chats that mention it, each opening in the Chat window.
                            let chats = chatMentions(bundle.id)
                            Menu(String(localized: "Mentioned In", bundle: #bundle, comment: "The chats that mention a ticket")) {
                                if chats.isEmpty {
                                    Text("No Mentions", bundle: #bundle)
                                }
                                ForEach(chats) { chat in
                                    Button(chat.title) { openRoute(.tool(.chat, project: chat.projectID, focus: chat.id)) }
                                }
                            }
                            .accessibilityIdentifier("tickets.sidebar.bundle.\(bundle.id).mentions")
                        }
                        Divider()
                        Button(String(localized: "Delete Bundle…", bundle: #bundle), role: .destructive) {
                            model.confirmation = .deleteBundle(bundle.id)
                        }
                    }
            }
        } header: {
            HStack {
                SectionHeader(title: String(localized: "Bundles", bundle: #bundle))
                Spacer()
                Button(String(localized: "New Bundle", bundle: #bundle), systemImage: "plus") { model.startNewBundle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "New Bundle", bundle: #bundle))
                    .accessibilityIdentifier("tickets.sidebar.newBundle")
            }
            .padding(.trailing, Self.headerTrailingInset)
        }
    }

    /// How much further the sidebar's section headers run than its rows' content: a header ends 2 pt from
    /// the sidebar's trailing edge, a row's content 16 pt. Taken off the Bundles header, it ends its + where
    /// the bundle rows' status symbols end, with the Status rows' badges.
    private static let headerTrailingInset: CGFloat = 14
}

/// A section's title in the sidebar or the Filter menu, a heading for VoiceOver.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A bundle, its status, and how many of its tickets are done.
private struct BundleRow: View {
    let bundle: TicketBundle
    let done: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: bundle.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: bundle.status.symbol)
                        .foregroundStyle(bundle.status.color)
                        .help(bundle.status.title)
                        .accessibilityLabel(bundle.status.title)
                }
                ProgressView(value: Double(done), total: Double(max(bundle.ticketIDs.count, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .accessibilityLabel(Text("\(done) of \(bundle.ticketIDs.count) done", bundle: #bundle))
            }
        } icon: {
            Image(systemName: "shippingbox")
        }
    }
}

/// The sidebar's choices, for an iPhone's layout, which has no room for the sidebar. Its sections come
/// in the sidebar's order, and its symbol fills while a filter other than All Tickets applies.
private struct TicketFilterMenu: View {
    @Bindable var model: TicketsModel

    var body: some View {
        Menu {
            Picker(String(localized: "Show", bundle: #bundle), selection: $model.filter) {
                Text("All Tickets", bundle: #bundle)
                    .tag(TicketFilter?.some(.all))
                    .accessibilityIdentifier("tickets.filterMenu.all")
                ForEach(model.filterSections) { section in
                    switch section {
                    case .status:
                        Section {
                            ForEach(TicketStatus.allCases) { status in
                                Text(verbatim: status.title)
                                    .tag(TicketFilter?.some(.status(status)))
                                    .accessibilityIdentifier("tickets.filterMenu.\(status.rawValue)")
                            }
                        } header: {
                            SectionHeader(title: TicketWords.status)
                        }
                    case .projects:
                        Section {
                            ForEach(model.family) { member in
                                Text(verbatim: member.name)
                                    .tag(TicketFilter?.some(.project(member.id)))
                                    .accessibilityIdentifier("tickets.filterMenu.project.\(member.id)")
                            }
                        } header: {
                            SectionHeader(title: String(localized: "Projects", bundle: #bundle))
                        }
                    case .bundles where !model.bundles.isEmpty:
                        Section {
                            ForEach(model.bundles) { bundle in
                                Text(verbatim: bundle.title)
                                    .tag(TicketFilter?.some(.bundle(bundle.id)))
                                    .accessibilityIdentifier("tickets.filterMenu.bundle.\(bundle.id)")
                            }
                        } header: {
                            SectionHeader(title: String(localized: "Bundles", bundle: #bundle))
                        }
                    case .bundles:
                        EmptyView()
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                String(localized: "Filter", bundle: #bundle),
                systemImage: model.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .help(String(localized: "Filter Tickets", bundle: #bundle))
        .accessibilityValue(model.title(of: model.filter ?? .all))
        .accessibilityIdentifier("tickets.filterMenu")
    }
}

#Preview("Loaded", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore()))
}

#Preview("Loaded, Dark", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore()))
        .preferredColorScheme(.dark)
}

#Preview("Mentioned In", traits: .appChrome, .fixedLayout(width: 1180, height: 1100)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore()))
        .environment(\.chatMentions, .samples)
}

#Preview("Implement", traits: .appChrome, .fixedLayout(width: 1180, height: 1100)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore()))
        .environment(\.chatMentions, .samples)
        .environment(\.itemChats, .samples)
        .environment(\.implement, ImplementAction { _ in })
}

#Preview("Mentioned In, None", traits: .appChrome, .fixedLayout(width: 1180, height: 1100)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-141", store: SampleTicketStore()))
        .environment(\.chatMentions, .samples)
}

#Preview("Parent Project", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("SHOP")!, focus: nil, store: SampleTicketStore()))
}

#Preview("Bundle", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-139", filter: .bundle("ORD-B3"), store: SampleTicketStore()))
}

#Preview("No Matching Tickets", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("TLS")!, focus: nil, filter: .status(.done), store: SampleTicketStore()))
}

#Preview("Ticket Not Found", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-999", store: SampleTicketStore()))
}

#Preview("Empty", traits: .appChrome, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("AZD")!, focus: nil, store: SampleTicketStore(allTickets: [], allBundles: [])))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore()))
}

#Preview("iPad, Filtered", traits: .padLayout, .fixedLayout(width: 760, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", filter: .status(.inProgress), store: SampleTicketStore()))
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("SHOP")!, focus: nil, store: SampleTicketStore()))
}

#Preview("iPhone, Filtered", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: nil, filter: .bundle("ORD-B3"), store: SampleTicketStore()))
}

#Preview("iPhone, Ticket", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore()))
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore()))
        .preferredColorScheme(.dark)
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1180, height: 760)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore()))
}

#Preview("Largest Text, iPhone", traits: .phoneLayout, .largestText, .fixedLayout(width: 420, height: 800)) {
    TicketsRootView(model: TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore()))
}

/// Ticket ids on the pasteboard, one per line: Copy ID and ⌘C in the list (V2's).
enum TicketIDCopy {
    static func text(_ ids: [Ticket.ID]) -> String {
        ids.joined(separator: "\n")
    }

    @MainActor static func copy(_ ids: [Ticket.ID]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(ids), forType: .string)
    }
}

/// Above the list, while ticket or bundle files of the window's projects can't be read: they are left out, and the
/// line names them, as V2 logged them.
private struct UnreadableFilesBar: View {
    let files: [String]

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(AttributedString(localized: "^[\(files.count) ticket file](inflect: true) can't be read", bundle: #bundle,
                                          comment: "Above the ticket list: files left out because they can't be read"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.warning)
                }
                .font(.callout)
                ForEach(files.prefix(3), id: \.self) { file in
                    Text(verbatim: file)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.surfaceSunken)
            .help(files.joined(separator: "\n"))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tickets.unreadable")
        }
    }
}
