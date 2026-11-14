import AZDesign
import ToolsFoundation
import SwiftUI

/// The detail column: everything about one ticket.
///
/// When the column is wide enough, the ticket's properties move to a column of their own on the
/// right, as in an issue tracker, and the description and history take the rest of the width. A
/// narrower column stacks them. Either way the comment field stays at the bottom.
///
/// Its toolbar actions live in `TicketActions`, so they can stay in place when no ticket is selected.
/// A linked item opens in its own tool's window, through the app's routes. The comment being written
/// belongs to the ticket: the window keeps one per ticket.
struct TicketDetailView: View {
    let ticket: Ticket
    var bundle: TicketBundle? = nil
    @Binding var comment: String
    /// Not wired yet: the example leaves it empty.
    var onComment: () -> Void = {}

    @State private var isWide = false

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            description
                            linked
                            activity
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                    Divider()
                    ScrollView {
                        TicketProperties(ticket: ticket, bundle: bundle, columns: [GridItem(.flexible(), alignment: .topLeading)])
                            .padding(20)
                    }
                    .frame(width: 280)
                    .background(.surface)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        description
                        TicketProperties(ticket: ticket, bundle: bundle, columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)])
                        linked
                        activity
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .background(.canvas)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 720 } action: { isWide = $0 }
        .navigationTitle(Text(verbatim: ticket.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket.detail")
    }

    /// The ticket's number, title, status and priority.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: ticket.id)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("ticket.number")
            Text(verbatim: ticket.title)
                .font(.title.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ticket.title")
            HStack(spacing: 6) {
                Label(ticket.status.title, systemImage: ticket.status.symbol)
                    .labelStyle(.badge(ticket.status.color))
                Label(ticket.priority.title, systemImage: ticket.priority.symbol)
                    .labelStyle(.badge(ticket.priority.color))
            }
        }
    }

    private var description: some View {
        Text(verbatim: ticket.details)
            .font(.body)
            .lineSpacing(3)
            .foregroundStyle(.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("ticket.description")
    }

    @ViewBuilder private var linked: some View {
        if !ticket.links.isEmpty {
            DetailSection(String(localized: "Linked", bundle: #bundle)) {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(ticket.links) { link in
                            if link.id != ticket.links.first?.id {
                                Divider()
                            }
                            LinkRow(link: link) { openRoute(link.route(in: ticket.projectID)) }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var activity: some View {
        DetailSection(String(localized: "Activity", bundle: #bundle)) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ticket.events) { event in
                    EventRow(event: event)
                        .accessibilityIdentifier("ticket.activity.\(event.id)")
                }
            }
        }
    }

    /// The field to add a comment, kept under the history.
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField(String(localized: "Add a comment", bundle: #bundle), text: $comment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.surfaceSunken, in: .capsule)
                    .accessibilityIdentifier("ticket.comment")
                Button(String(localized: "Comment", bundle: #bundle, comment: "The button that adds a comment"), action: onComment)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(String(localized: "Add the Comment (⌘↩)", bundle: #bundle))
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ticket.comment.send")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.canvas)
    }
}

/// A titled part of the ticket.
private struct DetailSection<Content: View>: View {
    /// Already localized.
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// The ticket's properties, each name above its value: one column beside the ticket, or as many
/// as fit under its description.
private struct TicketProperties: View {
    let ticket: Ticket
    let bundle: TicketBundle?
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            Property(TicketWords.status) {
                Label(ticket.status.title, systemImage: ticket.status.symbol)
                    .labelStyle(.badge(ticket.status.color))
            }
            Property(TicketWords.priority) {
                Label(ticket.priority.title, systemImage: ticket.priority.symbol)
                    .labelStyle(.badge(ticket.priority.color))
            }
            Property(String(localized: "Reporter", bundle: #bundle, comment: "A ticket's property")) {
                Text(verbatim: ticket.reporter)
            }
            Property(String(localized: "Bundle", bundle: #bundle, comment: "A ticket's property")) {
                if let bundle {
                    Label {
                        Text(verbatim: bundle.title)
                    } icon: {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.accent)
                            .accessibilityHidden(true)
                    }
                } else {
                    Text("None", bundle: #bundle, comment: "The Bundle property of a ticket in no bundle")
                        .foregroundStyle(.textSecondary)
                }
            }
            Property(String(localized: "Created On", bundle: #bundle, comment: "A ticket's property")) {
                Text(ticket.createdAt, format: .dateTime.day().month().year())
            }
            Property(String(localized: "Last Updated", bundle: #bundle, comment: "A ticket's property")) {
                Text(ticket.updatedAt, format: .dateTime.day().month().year())
            }
            Property(String(localized: "Labels", bundle: #bundle, comment: "A ticket's property")) {
                HStack(spacing: 6) {
                    ForEach(ticket.labels, id: \.self) { label in
                        Text(verbatim: label)
                            .font(.caption)
                            .foregroundStyle(.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.surfaceSunken, in: Capsule())
                    }
                }
            }
        }
        .accessibilityIdentifier("ticket.properties")
    }
}

/// One property: its name, and its value under it.
private struct Property<Value: View>: View {
    /// Already localized.
    let title: String
    @ViewBuilder var value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textSecondary)
            value
                .foregroundStyle(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Something the ticket points to in another tool. Clicking it opens that tool's window on it.
private struct LinkRow: View {
    let link: TicketLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: link.kind.symbol)
                    .foregroundStyle(.accent)
                    .frame(minWidth: 20)
                    .accessibilityHidden(true)
                Text(verbatim: link.title)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(verbatim: link.kind.title)
                    .foregroundStyle(.textSecondary)
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ticket.link.\(link.id)")
    }
}

/// One entry of the ticket's history, with the text of a comment under it.
private struct EventRow: View {
    let event: TicketEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .foregroundStyle(.textSecondary)
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: event.text)
                        .foregroundStyle(.textPrimary)
                    Spacer(minLength: 16)
                    Text(event.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                }
                if let comment = event.comment {
                    Text(verbatim: comment)
                        .lineSpacing(2)
                        .foregroundStyle(.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.surface, in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A route asked for a ticket the window doesn't have.
struct TicketNotFoundView: View {
    let id: Ticket.ID
    let project: Project

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "Ticket Not Found", bundle: #bundle), systemImage: "ticket")
        } description: {
            Text("\(project.name) has no ticket with the id \(id).", bundle: #bundle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tickets.detail.notFound")
    }
}

#Preview("Loaded", traits: .appChrome) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0]) }
    }
    .frame(width: 980, height: 760)
}

#Preview("Narrow", traits: .appChrome) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0]) }
    }
    .frame(width: 600, height: 760)
}

#Preview("Loaded, Dark", traits: .appChrome) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0]) }
    }
    .frame(width: 640, height: 720)
    .preferredColorScheme(.dark)
}

#Preview("Draft", traits: .appChrome) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[1], bundle: TicketBundle.samples[1], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[1]) }
    }
    .frame(width: 640, height: 720)
}

#Preview("Done", traits: .appChrome) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[5], bundle: TicketBundle.samples[1], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[5]) }
    }
    .frame(width: 640, height: 720)
}

#Preview("Comment Draft", traits: .appChrome) {
    @Previewable @State var comment = "Backoff is in run 1288. Can you check the retries in tonight's batch?"
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0]) }
    }
    .frame(width: 640, height: 720)
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0], isCompact: true) }
    }
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 640, height: 800)) {
    @Previewable @State var comment = ""
    NavigationStack {
        TicketDetailView(ticket: Ticket.samples[0], bundle: TicketBundle.samples[0], comment: $comment)
            .toolbar { TicketActions(ticket: Ticket.samples[0]) }
    }
}

#Preview("Not Found", traits: .appChrome, .fixedLayout(width: 640, height: 480)) {
    TicketNotFoundView(id: "ORD-999", project: Project.sample("ORD")!)
}
