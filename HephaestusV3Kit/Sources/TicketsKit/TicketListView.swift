import AZDesign
import ToolsFoundation
import SwiftUI

/// What the ticket list has to show.
enum TicketListState: Hashable {
    case loading
    /// The project has no tickets at all.
    case empty
    /// The filter lets no ticket through: why, in a sentence.
    case noMatch(String)
    case failed(message: String)
    case loaded([Ticket])
    /// A parent project's tickets: one group per project, the window's project first.
    case grouped([TicketGroup])
}

/// The middle column: the tickets the sidebar let through.
struct TicketListView: View {
    let state: TicketListState
    @Binding var selection: Ticket.ID?
    var onNewTicket: () -> Void = {}
    var onShowAll: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView {
                    Text("Loading Tickets", bundle: #bundle)
                }
                .accessibilityIdentifier("tickets.list.loading")
            case .empty:
                ContentUnavailableView {
                    Label(String(localized: "No Tickets", bundle: #bundle), systemImage: "ticket")
                } description: {
                    Text("Tickets you create or draft show up here.", bundle: #bundle)
                } actions: {
                    Button(String(localized: "New Ticket", bundle: #bundle), action: onNewTicket)
                        .accessibilityIdentifier("tickets.list.empty.new")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tickets.list.empty")
            case .noMatch(let message):
                ContentUnavailableView {
                    Label(String(localized: "No Matching Tickets", bundle: #bundle), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button(String(localized: "Show All Tickets", bundle: #bundle), action: onShowAll)
                        .accessibilityIdentifier("tickets.list.noMatch.showAll")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tickets.list.noMatch")
            case .failed(let message):
                ContentUnavailableView {
                    Label(String(localized: "Couldn't Load Tickets", bundle: #bundle), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button(String(localized: "Try Again", bundle: #bundle), action: onRetry)
                        .accessibilityIdentifier("tickets.list.retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tickets.list.error")
            case .loaded(let tickets):
                List(tickets, selection: $selection) { ticket in
                    TicketRow(ticket: ticket)
                        .accessibilityIdentifier("tickets.row.\(ticket.id)")
                }
                .scrollContentBackground(.hidden)
            case .grouped(let groups):
                // The window's project first, then each sub project in tree order.
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.tickets) { ticket in
                                TicketRow(ticket: ticket)
                                    .tag(ticket.id)
                                    .accessibilityIdentifier("tickets.row.\(ticket.id)")
                            }
                        } header: {
                            Label {
                                Text(verbatim: group.project.name)
                            } icon: {
                                ProjectIcon(group.project)
                            }
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("tickets.group.\(group.project.id)")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "New Ticket", bundle: #bundle), systemImage: "plus", action: onNewTicket)
                    .help(String(localized: "New Ticket (⇧⌘N)", bundle: #bundle))
                    .accessibilityIdentifier("tickets.list.new")
            }
            // In an iPhone's layout the list is the window's only pane: the chat panel's button
            // comes last, after the list's own.
            ChatPanelToolbarItem()
        }
    }
}

/// The filter that applies, above the list when the sidebar isn't there to show it. Clicking it shows
/// every ticket again.
struct TicketFilterBar: View {
    let title: String
    let symbol: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onClear) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(.accent)
                    Text(verbatim: title)
                        .foregroundStyle(.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.textSecondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.surfaceSunken, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show All Tickets", bundle: #bundle))
            .accessibilityLabel(String(localized: "Filter", bundle: #bundle))
            .accessibilityValue(title)
            .accessibilityHint(String(localized: "Shows all tickets.", bundle: #bundle))
            .accessibilityIdentifier("tickets.filterBar")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.canvas)
    }
}

/// One ticket in the list: title and date, then its number, status and priority.
struct TicketRow: View {
    let ticket: Ticket

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: ticket.title)
                    .font(.headline)
                    .foreground(.textPrimary, onSelection: .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(ticket.updatedAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption)
                    .foreground(.textSecondary, onSelection: .secondary)
            }
            HStack(spacing: 6) {
                Text(verbatim: ticket.id)
                    .font(.caption)
                    .monospacedDigit()
                    .foreground(.textSecondary, onSelection: .secondary)
                Label(ticket.status.title, systemImage: ticket.status.symbol)
                    .labelStyle(.badge(ticket.status.color))
                Label(ticket.priority.title, systemImage: ticket.priority.symbol)
                    .labelStyle(.badge(ticket.priority.color))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Loaded", traits: .appChrome) {
    @Previewable @State var selection: Ticket.ID? = "ORD-142"
    TicketListView(state: .loaded(Ticket.samples), selection: $selection)
        .frame(width: 360, height: 620)
}

#Preview("Loaded, Dark", traits: .appChrome) {
    @Previewable @State var selection: Ticket.ID? = "ORD-142"
    TicketListView(state: .loaded(Ticket.samples), selection: $selection)
        .frame(width: 360, height: 620)
        .preferredColorScheme(.dark)
}

#Preview("Grouped", traits: .appChrome) {
    @Previewable @State var selection: Ticket.ID? = "SHOP-14"
    TicketListView(state: TicketsModel(project: Project.sample("SHOP")!, focus: nil, store: SampleTicketStore()).listState, selection: $selection)
        .frame(width: 360, height: 620)
}

#Preview("Largest Text", traits: .largestText) {
    @Previewable @State var selection: Ticket.ID? = "ORD-142"
    TicketListView(state: .loaded(Ticket.samples), selection: $selection)
        .frame(width: 420, height: 800)
}

#Preview("Loading", traits: .appChrome) {
    TicketListView(state: .loading, selection: .constant(nil))
        .frame(width: 360, height: 620)
}

#Preview("Empty", traits: .appChrome) {
    TicketListView(state: .empty, selection: .constant(nil))
        .frame(width: 360, height: 620)
}

#Preview("No Matching Tickets", traits: .appChrome) {
    TicketListView(
        state: TicketsModel(project: Project.sample("TLS")!, focus: nil, filter: .status(.done), store: SampleTicketStore()).listState,
        selection: .constant(nil)
    )
        .frame(width: 360, height: 620)
}

#Preview("Error", traits: .appChrome) {
    TicketListView(state: .failed(message: "The tickets service didn't answer."), selection: .constant(nil))
        .frame(width: 360, height: 620)
}

#Preview("Row", traits: .appChrome, .sizeThatFitsLayout) {
    TicketRow(ticket: Ticket.samples[0])
        .frame(width: 340)
        .padding()
        .background(.canvas)
}

#Preview("Filter Bar", traits: .appChrome, .sizeThatFitsLayout) {
    TicketFilterBar(title: TicketStatus.inProgress.title, symbol: TicketStatus.inProgress.symbol) {}
        .frame(width: 390)
}
