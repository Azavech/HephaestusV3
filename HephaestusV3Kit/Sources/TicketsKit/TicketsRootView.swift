import AZDesign
import SwiftUI
import ToolsFoundation

/// The Tickets window for one project: sidebar of statuses, projects and bundles, ticket list, ticket
/// detail. `TicketsModel` holds the tickets, the filter, the selection and what a route selects; the
/// view holds only how the panes are laid out.
public struct TicketsRootView: View {
    @State private var model: TicketsModel

    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.toolLayout) private var layout
    /// The sidebar folds away in an iPad's layout, behind its button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The New Ticket sheet's width in an iPhone's layout: the window's, less 12 pt on each side, up to
    /// the Mac's 480 pt.
    @State private var phoneSheetWidth: CGFloat = 480

    /// The Tickets window of `project`, with `focus` (a ticket id) selected when it opens. A later
    /// route's focus arrives as a focus request.
    public init(project: Project, focus: String? = nil) {
        _model = State(initialValue: TicketsModel(project: project, focus: focus, store: SampleTicketStore()))
    }

    init(model: TicketsModel) {
        _model = State(initialValue: model)
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
                onCreate: { model.createNewTicket() }
            )
        }
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
                TicketActions(ticket: model.selectedTicket)
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
                if let ticket = model.tickets.first(where: { $0.id == id }) {
                    detail(of: ticket)
                } else {
                    TicketNotFoundView(id: id, project: model.project)
                }
            }
            .toolbar {
                TicketActions(ticket: model.tickets.first { $0.id == id }, isCompact: true)
                ChatPanelToolbarItem()
            }
        }
    }

    private var list: some View {
        TicketListView(
            state: model.listState,
            selection: $model.selection,
            onNewTicket: { model.startNewTicket() },
            onShowAll: { model.showAllTickets() }
        )
    }

    /// The filter that applies, when it isn't All Tickets.
    @ViewBuilder private var filterBar: some View {
        if model.isFiltered, let filter = model.filter {
            TicketFilterBar(title: model.title(of: filter), symbol: model.symbol(of: filter), onClear: { model.showAllTickets() })
        }
    }

    private func detail(of ticket: Ticket) -> some View {
        TicketDetailView(
            ticket: ticket,
            bundle: model.bundle(of: ticket),
            comment: Binding {
                model.commentDraft(for: ticket.id)
            } set: { text in
                model.setCommentDraft(text, for: ticket.id)
            }
        )
    }
}

/// The sidebar: every ticket, one row per status with its count, the projects of a parent, then the
/// bundles with their progress.
private struct TicketSidebar: View {
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
                .padding(.leading, CGFloat(Project.tree.depth(of: member.id) - Project.tree.depth(of: model.project.id)) * 14)
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
            }
        } header: {
            SectionHeader(title: String(localized: "Bundles", bundle: #bundle))
        }
    }
}

/// A section's title in the sidebar or the Filter menu, a heading for VoiceOver.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A bundle, with how many of its tickets are done.
private struct BundleRow: View {
    let bundle: TicketBundle
    let done: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: bundle.title)
                    .lineLimit(1)
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
                    case .bundles:
                        Section {
                            ForEach(model.bundles) { bundle in
                                Text(verbatim: bundle.title)
                                    .tag(TicketFilter?.some(.bundle(bundle.id)))
                                    .accessibilityIdentifier("tickets.filterMenu.bundle.\(bundle.id)")
                            }
                        } header: {
                            SectionHeader(title: String(localized: "Bundles", bundle: #bundle))
                        }
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
