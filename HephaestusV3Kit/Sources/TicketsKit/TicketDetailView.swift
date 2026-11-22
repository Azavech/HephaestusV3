import AppKit
import AZDesign
import QuickLook
import SwiftUI
import TicketData
import TextViews
import ToolsFoundation
import UniformTypeIdentifiers

/// The detail column: everything about one ticket, and every change made to it.
///
/// When the column is wide enough, the ticket's properties move to a column of their own on the
/// right, as in an issue tracker, and the description and history take the rest of the width. A
/// narrower column stacks them. Either way the comment field stays at the bottom.
///
/// Its toolbar actions live in `TicketActions`, so they can stay in place when no ticket is selected.
/// A linked item opens in its own window, through the app's routes. The comment being written belongs to
/// the ticket: the window keeps one per ticket, with its files.
struct TicketDetailView: View {
    let ticket: Ticket
    @Bindable var model: TicketsModel

    @State private var isWide = false
    @State private var isImporting = false
    @FocusState private var commentFocused: Bool
    /// The comment field's insertion point, for the completion of `@Claude`.
    @State private var commentSelection: TextSelection?
    /// The `@` (its UTF-16 offset) whose completion Escape closed.
    @State private var dismissedMention: Int?
    /// Where the files picked go: the ticket's own, or the next comment's.
    @State private var importsForComment = false
    @State private var preview: URL?
    /// What Quick Look steps through: an image's fellow images, or the one file opened.
    @State private var previewItems: [URL] = []

    @Environment(\.openRoute) private var openRoute
    @Environment(\.chatMentions) private var chatMentions
    @Environment(\.itemChats) private var itemChats
    @Environment(\.implement) private var implement

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            mainParts(properties: false)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                    Divider()
                    ScrollView {
                        properties(columns: [GridItem(.flexible(), alignment: .topLeading)])
                            .padding(20)
                    }
                    .frame(width: 280)
                    .background(.surface)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        mainParts(properties: true)
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
        // Files dropped on the ticket, outside the comment field, become its own.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addAttachments(urls, to: ticket.id) }
            return !urls.isEmpty
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if importsForComment {
                model.attach(urls, to: ticket.id)
            } else {
                Task { await model.addAttachments(urls, to: ticket.id) }
            }
        }
        .quickLookPreview($preview, in: previewItems)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket.detail")
    }

    @ViewBuilder private func mainParts(properties showsProperties: Bool) -> some View {
        if let edit = model.edit, edit.ticketID == ticket.id {
            TicketEditor(edit: model.editBinding(edit), projectID: ticket.projectID, onCancel: { model.cancelEditing() },
                         onSave: { Task { await model.saveEditing() } })
        } else {
            header
            description
        }
        if showsProperties {
            properties(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)])
        }
        attachments
        linked
        if let itemChats {
            TicketChatsSection(chats: itemChats(ticket.id)) { implementButton(identifier: "ticket.chats.implement", shortcut: false) }
        }
        if let chatMentions {
            MentionedInSection(chats: chatMentions(ticket.id), emptyText: String(localized: "Chats that mention this ticket appear here.", bundle: #bundle))
        }
        activity
    }

    /// Implement… (docs/ui/tickets.md › Implement): the dependencies alert first when some aren't done, then the
    /// sheet. Disabled for a done ticket or a draft, saying why; absent where the window can't implement.
    @ViewBuilder private func implementButton(identifier: String, shortcut: Bool) -> some View {
        if let implement {
            let refusal = model.implementRefusal(of: ticket)
            Button(String(localized: "Implement…", bundle: #bundle, comment: "Starts a chat in which Claude implements the ticket"),
                   systemImage: "hammer") {
                model.implement(ticket, with: implement)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .keyboardShortcut(shortcut ? KeyboardShortcut("i", modifiers: [.command, .shift]) : nil)
            .disabled(refusal != nil)
            .help(refusal ?? String(localized: "Implement the Ticket with Claude (⇧⌘I)", bundle: #bundle))
            .accessibilityIdentifier(identifier)
        }
    }

    /// The ticket's number, title, status and priority, Implement… and Edit.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: ticket.id)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ticket.number")
                Spacer()
                implementButton(identifier: "ticket.implement", shortcut: true)
                Button(String(localized: "Edit", bundle: #bundle, comment: "Edits a ticket's title, description, priority and labels"), systemImage: "pencil") {
                    model.startEditing(ticket)
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .keyboardShortcut("e", modifiers: .command)
                .help(String(localized: "Edit the Ticket (⌘E)", bundle: #bundle))
                .accessibilityIdentifier("ticket.edit")
            }
            Text(verbatim: ticket.title)
                .font(.title.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ticket.title")
            HStack(spacing: 6) {
                Label(ticket.status.title, systemImage: ticket.status.symbol)
                    .labelStyle(.badge(ticket.status.color))
                if let priority = ticket.priority {
                    Label(priority.title, systemImage: priority.symbol)
                        .labelStyle(.badge(priority.color))
                }
                if ticket.isBlocked {
                    Label(TicketWords.blocked, systemImage: "hand.raised")
                        .labelStyle(.badge(.danger))
                        .help(TicketWords.blockedHelp(ticket))
                        .accessibilityIdentifier("ticket.blocked")
                }
            }
        }
    }

    @ViewBuilder private var description: some View {
        if ticket.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description.", bundle: #bundle)
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("ticket.description")
        } else {
            TicketText(ticket.details, projectID: ticket.projectID)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ticket.description")
        }
    }

    private func properties(columns: [GridItem]) -> some View {
        TicketProperties(ticket: ticket, bundles: model.bundles(of: ticket), columns: columns, onBundle: { bundle in
            if model.family.contains(where: { $0.id == bundle.projectID }) {
                model.select(focus: bundle.id)
            } else {
                openRoute(.tool(.tickets, project: bundle.projectID, focus: bundle.id))
            }
        }) { priority in
            Task { await model.setPriority(priority, of: ticket) }
        }
    }

    /// The ticket's own files, and Add Files….
    private var attachments: some View {
        TicketSection(String(localized: "Attachments (\(ticket.attachments.count))", bundle: #bundle)) {
            Button(String(localized: "Add Files…", bundle: #bundle), systemImage: "paperclip") {
                importsForComment = false
                isImporting = true
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("ticket.attachments.add")
        } content: {
            if ticket.attachments.isEmpty {
                Text("Drop files here or click Add Files…", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            } else {
                AttachmentStrip(attachments: ticket.attachments, projectID: ticket.projectID, model: model, ticket: ticket,
                                removable: true, onOpen: open)
            }
        }
        .accessibilityIdentifier("ticket.attachments")
    }

    /// The tickets it depends on, blocks or relates to, and the items it links to in other tools.
    private var linked: some View {
        TicketSection(String(localized: "Linked", bundle: #bundle)) {
            Button(String(localized: "Add Link…", bundle: #bundle), systemImage: "plus") {
                model.linkingTicket = ticket.id
            }
            .buttonStyle(.borderless)
            .disabled(model.linkCandidates(for: ticket).isEmpty)
            .accessibilityIdentifier("ticket.links.add")
        } content: {
            if ticket.links.isEmpty {
                Text("No linked tickets.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(ticket.links) { link in
                            if link.id != ticket.links.first?.id {
                                Divider()
                            }
                            LinkRow(link: link) { openRoute(link.route(in: ticket.projectID)) }
                                .contextMenu {
                                    if link.isDeclared {
                                        Button(String(localized: "Remove Link", bundle: #bundle), role: .destructive) {
                                            Task { await model.removeLink(link, from: ticket) }
                                        }
                                    }
                                }
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
                    if let edit = model.commentEdit, edit.ticketID == ticket.id, edit.commentID == event.commentID {
                        CommentEditor(text: Binding { model.commentEdit?.text ?? "" } set: { model.commentEdit?.text = $0 },
                                      onCancel: { model.commentEdit = nil }, onSave: { Task { await model.saveComment() } })
                    } else {
                        EventRow(event: event, projectID: ticket.projectID, model: model, ticket: ticket, onOpen: open)
                            .accessibilityIdentifier("ticket.activity.\(event.id)")
                            .contextMenu {
                                if let commentID = event.commentID {
                                    Button(String(localized: "Edit", bundle: #bundle)) {
                                        model.startEditingComment(event, of: ticket.id)
                                    }
                                    Button(String(localized: "Copy Text", bundle: #bundle)) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(event.comment ?? "", forType: .string)
                                    }
                                    Divider()
                                    Button(String(localized: "Delete…", bundle: #bundle), role: .destructive) {
                                        model.confirmation = .deleteComment(ticket.id, commentID)
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    /// The comment field's insertion point (UTF-16 offset in the draft), while nothing is selected.
    private var insertionPoint: Int? {
        guard let commentSelection, case .selection(let range) = commentSelection.indices, range.isEmpty else { return nil }
        let text = model.commentDraft(for: ticket.id)
        // The selection may still be the last draft's, after another ticket was selected.
        guard range.lowerBound >= text.startIndex, range.lowerBound <= text.endIndex else { return nil }
        return range.lowerBound.utf16Offset(in: text)
    }

    /// The `@Claude` being typed in the focused comment field.
    private var typedMention: Range<Int>? {
        guard commentFocused, let insertionPoint else { return nil }
        return CommentMentions.completion(in: model.commentDraft(for: ticket.id), at: insertionPoint)
    }

    /// The `@Claude` being typed, while its list shows: Escape closes it for that `@`.
    private var mentionBeingTyped: Range<Int>? {
        guard let typedMention, typedMention.lowerBound != dismissedMention else { return nil }
        return typedMention
    }

    /// Replaces the `@` and its letters with `@Claude `, the insertion point after it.
    private func complete(_ mention: Range<Int>) {
        let completed = CommentMentions.complete(model.commentDraft(for: ticket.id), range: mention)
        model.setCommentDraft(completed.text, for: ticket.id)
        commentSelection = TextSelection(insertionPoint: String.Index(utf16Offset: completed.insertionPoint, in: completed.text))
    }

    /// The field to add a comment, kept under the history, with the files waiting to go with it.
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                let files = model.files(for: ticket.id)
                if !files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(files, id: \.self) { file in
                                PendingFileChip(url: file) { model.detach(file, from: ticket.id) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Button(String(localized: "Attach Files", bundle: #bundle), systemImage: "paperclip") {
                        importsForComment = true
                        isImporting = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "Attach Files to the Comment", bundle: #bundle))
                    .accessibilityIdentifier("ticket.comment.attach")
                    let mention = mentionBeingTyped
                    TextField(String(localized: "Add a comment", bundle: #bundle), text: Binding {
                        model.commentDraft(for: ticket.id)
                    } set: {
                        model.setCommentDraft($0, for: ticket.id)
                    }, selection: $commentSelection, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($commentFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.surfaceSunken, in: .capsule)
                    .background {
                        // ⌘V of files or an image attaches them, as V2's comment composer did; text pastes as text.
                        if commentFocused {
                            PasteWatcher { model.paste(into: ticket.id) }
                        }
                        // Return and Tab complete the mention, Escape closes the list (docs/ui/tickets.md › Mentioning Claude).
                        if let mention {
                            KeyWatcher { key in
                                switch key {
                                case .return, .tab: complete(mention)
                                case .escape: dismissedMention = mention.lowerBound
                                }
                                return true
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let mention {
                            MentionSuggestion { complete(mention) }
                                .alignmentGuide(.top) { $0[.bottom] + 4 }
                        }
                    }
                    .onChange(of: ticket.id) {
                        commentSelection = nil
                        dismissedMention = nil
                    }
                    .onChange(of: typedMention?.lowerBound) { _, start in
                        // Another `@`, or none, ends what Escape closed: a new `@` shows the list again.
                        if start != dismissedMention { dismissedMention = nil }
                    }
                    .accessibilityIdentifier("ticket.comment")
                    Button(String(localized: "Comment", bundle: #bundle, comment: "The button that adds a comment")) {
                        Task { await model.sendComment(on: ticket.id) }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(String(localized: "Add the Comment (⌘↩)", bundle: #bundle))
                    .disabled(!model.canComment(on: ticket.id) || model.isWorking)
                    .accessibilityIdentifier("ticket.comment.send")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // Files dropped on the comment field go with the next comment.
            .dropDestination(for: URL.self) { urls, _ in
                model.attach(urls, to: ticket.id)
                return !urls.isEmpty
            }
        }
        .background(.canvas)
    }

    /// Opens an attachment with Quick Look. On an image, Quick Look steps through the ticket's images, then each
    /// comment's, as V2's image viewer did; another file shows alone.
    private func open(_ attachment: TicketAttachment) {
        let ticket = ticket
        Task {
            guard let url = await model.url(of: attachment, in: ticket) else { return }
            var items = [url]
            if Self.isImage(attachment) {
                var images: [URL] = []
                for image in (ticket.attachments + ticket.events.flatMap(\.attachments)) where Self.isImage(image) {
                    if let imageURL = await model.url(of: image, in: ticket) { images.append(imageURL) }
                }
                if images.contains(url) { items = images }
            }
            previewItems = items
            preview = url
        }
    }

    private static func isImage(_ attachment: TicketAttachment) -> Bool {
        FileTile.isImage(UTType(mimeType: attachment.contentType))
    }
}

/// A part of the ticket under a title, as `DetailSection`, with a button at the title's trailing end.
private struct TicketSection<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory
            }
            content
        }
        .accessibilityElement(children: .contain)
    }
}

/// A description or a comment, as Markdown with the ids of the loaded projects linked and its relative links
/// opening the files of the ticket's project.
struct TicketText: View {
    let text: String
    var projectID: Project.ID?
    /// A comment's: its mentions of Claude in the accent color (docs/ui/tickets.md › Mentioning Claude).
    var isComment = false
    @Environment(\.projectDirectory) private var directory

    init(_ text: String, projectID: Project.ID? = nil, isComment: Bool = false) {
        self.text = text
        self.projectID = projectID
        self.isComment = isComment
    }

    var body: some View {
        MarkdownView(text, projects: Set(directory.projects.map(\.id)), root: directory.project(projectID)?.path,
                     highlightsMentions: isComment)
    }
}

/// The editor of a ticket's title, description, priority and labels.
extension TicketsModel {
    /// The editor's binding, from the edit it opened with. It reads the open edit of that ticket, or `opened`
    /// once Save or Cancel cleared it (or another ticket's edit replaced it), since SwiftUI updates the closing
    /// editor's fields once more; a force-unwrapped binding crashed there. It writes only while that ticket's
    /// edit is open, so a field that commits its text as the editor closes doesn't open it again.
    func editBinding(_ opened: TicketEdit) -> Binding<TicketEdit> {
        Binding {
            if let edit = self.edit, edit.ticketID == opened.ticketID {
                return edit
            }
            return opened
        } set: { value in
            guard self.edit?.ticketID == opened.ticketID else { return }
            self.edit = value
        }
    }
}

private struct TicketEditor: View {
    @Binding var edit: TicketEdit
    /// The ticket's project, for Generate Title's link.
    let projectID: Project.ID
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeneratedTitleField(title: $edit.title, description: edit.details,
                                ticket: GenerateTitleAction.Ticket(id: edit.ticketID, projectID: projectID), identifier: "ticket.edit") {
                TextField(String(localized: "Title", bundle: #bundle), text: $edit.title, prompt: Text("Title", bundle: #bundle))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("ticket.edit.title")
            }
            TextEditor(text: $edit.details)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                .accessibilityLabel(Text("Description", bundle: #bundle))
                .accessibilityIdentifier("ticket.edit.description")
            HStack(spacing: 16) {
                Picker(TicketWords.priority, selection: $edit.priority) {
                    Text(verbatim: TicketWords.none).tag(TicketPriority?.none)
                    ForEach(TicketPriority.allCases) { priority in
                        Text(verbatim: priority.title).tag(TicketPriority?.some(priority))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("ticket.edit.priority")
                TextField(String(localized: "Labels", bundle: #bundle), text: $edit.labels,
                          prompt: Text("Labels, separated by commas", bundle: #bundle))
                    .accessibilityIdentifier("ticket.edit.labels")
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ticket.edit.cancel")
                Button(String(localized: "Save", bundle: #bundle), action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!edit.canSave)
                    .accessibilityIdentifier("ticket.edit.save")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ticket.editor")
    }
}

/// A comment's text being edited, in place of the comment.
private struct CommentEditor: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.surfaceSunken, in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                .accessibilityIdentifier("ticket.commentEditor.text")
            HStack {
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", bundle: #bundle), action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ticket.commentEditor.save")
            }
        }
    }
}

/// The ticket's properties, each name above its value: one column beside the ticket, or as many
/// as fit under its description.
private struct TicketProperties: View {
    let ticket: Ticket
    let bundles: [TicketBundle]
    let columns: [GridItem]
    /// Shows a bundle of the ticket.
    let onBundle: (TicketBundle) -> Void
    let onPriority: (TicketPriority?) -> Void

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            LabeledContent(TicketWords.status) {
                Label(ticket.status.title, systemImage: ticket.status.symbol)
                    .labelStyle(.badge(ticket.status.color))
            }
            LabeledContent(TicketWords.priority) {
                Menu {
                    Picker(TicketWords.priority, selection: Binding(get: { ticket.priority }, set: onPriority)) {
                        Text(verbatim: TicketWords.none).tag(TicketPriority?.none)
                        ForEach(TicketPriority.allCases) { priority in
                            Label(priority.title, systemImage: priority.symbol).tag(TicketPriority?.some(priority))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    if let priority = ticket.priority {
                        Label(priority.title, systemImage: priority.symbol)
                            .labelStyle(.badge(priority.color))
                    } else {
                        Text(verbatim: TicketWords.none)
                            .foregroundStyle(.textSecondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("ticket.priority")
            }
            LabeledContent(String(localized: "Reporter", bundle: #bundle, comment: "A ticket's property")) {
                Text(verbatim: ticket.reporter)
            }
            LabeledContent(String(localized: "Bundle", bundle: #bundle, comment: "A ticket's property")) {
                if bundles.isEmpty {
                    Text(verbatim: TicketWords.none)
                        .foregroundStyle(.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(bundles) { bundle in
                            // A click shows the bundle, as V2's ids did: its row in this window, or its project's Tickets.
                            Button {
                                onBundle(bundle)
                            } label: {
                                Label {
                                    Text(verbatim: bundle.title)
                                } icon: {
                                    Image(systemName: "shippingbox")
                                        .foregroundStyle(.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Show \(bundle.id)", bundle: #bundle, comment: "Shows a bundle of the ticket"))
                            .accessibilityIdentifier("ticket.bundle.\(bundle.id)")
                        }
                    }
                }
            }
            LabeledContent(String(localized: "Created On", bundle: #bundle, comment: "A ticket's property")) {
                Text(ticket.createdAt, format: .dateTime.day().month().year())
            }
            LabeledContent(String(localized: "Last Updated", bundle: #bundle, comment: "A ticket's property")) {
                Text(ticket.updatedAt, format: .dateTime.day().month().year())
            }
            LabeledContent(String(localized: "Labels", bundle: #bundle, comment: "A ticket's property")) {
                if ticket.labels.isEmpty {
                    Text(verbatim: TicketWords.none)
                        .foregroundStyle(.textSecondary)
                } else {
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
        }
        .labeledContentStyle(.stacked)
        .accessibilityIdentifier("ticket.properties")
    }
}

/// Something the ticket points to: another ticket, or an item in another tool. Clicking it opens its
/// window on it.
/// V2's Mentioned In: the chats of every project that mention the ticket, the latest updated first, closed ones
/// included (docs/ui/tickets.md › Mentioned In). A row opens its chat in the Chat window; its menu also opens it
/// in a window of its own.
struct MentionedInSection: View {
    let chats: [MentioningChat]
    let emptyText: String

    var body: some View {
        ChatListSection(title: String(localized: "Mentioned In", bundle: #bundle, comment: "The chats that mention a ticket"),
                        identifier: "ticket.mentions", chats: chats, emptyText: emptyText) {
            EmptyView()
        }
    }
}

/// The ticket's own chats (docs/ui/tickets.md › Chats), with Implement… at the heading's trailing edge.
struct TicketChatsSection<Trailing: View>: View {
    let chats: [MentioningChat]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ChatListSection(title: String(localized: "Chats", bundle: #bundle, comment: "A ticket's own chats"), identifier: "ticket.chats",
                        chats: chats,
                        emptyText: String(localized: "Implement starts a chat in which Claude implements this ticket.", bundle: #bundle),
                        trailing: trailing)
    }
}

/// Chats in a group box, each opening its chat in the Chat window: Mentioned In's and Chats' rows.
private struct ChatListSection<Trailing: View>: View {
    let title: String
    /// `ticket.mentions`, `ticket.chats`: the section's, `<identifier>.<chat id>` a row's, `<identifier>.empty`.
    let identifier: String
    let chats: [MentioningChat]
    let emptyText: String
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        TicketSection(title) {
            trailing()
        } content: {
            if chats.isEmpty {
                Text(verbatim: emptyText)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("\(identifier).empty")
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(chats) { chat in
                            if chat.id != chats.first?.id {
                                Divider()
                            }
                            MentionRow(chat: chat, identifier: identifier) { openRoute(.tool(.chat, project: chat.projectID, focus: chat.id)) }
                                .contextMenu {
                                    Button(String(localized: "Open in Chat Window", bundle: #bundle)) {
                                        openRoute(.tool(.chat, project: chat.projectID, focus: chat.id))
                                    }
                                    Button(String(localized: "Open in New Window", bundle: #bundle, comment: "Opens a chat in a window of its own")) {
                                        openRoute(.chatWindow(chat: chat.id))
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A chat of the ticket, or one that mentions it: its kind's symbol, title, project, last update and mark.
private struct MentionRow: View {
    let chat: MentioningChat
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.accent)
                    .frame(minWidth: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: chat.title)
                        .foregroundStyle(chat.closed ? Color.textSecondary : Color.textPrimary)
                        .lineLimit(1)
                    Text("\(chat.projectID) · \(chat.updated, format: Self.dateFormat)", bundle: #bundle,
                         comment: "A chat that mentions a ticket: its project's identifier, then its last date")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
                Spacer(minLength: 16)
                mark
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifier).\(chat.id)")
    }

    private var symbol: String {
        switch chat.kind {
        case .implement: "hammer"
        case .ci: "checklist"
        case .feedback: "ladybug"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }

    @ViewBuilder private var mark: some View {
        switch chat.state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(String(localized: "Working", bundle: #bundle, comment: "A chat where Claude works"))
        case .waiting:
            StatusDot(.warning)
                .accessibilityLabel(String(localized: "Waiting for you", bundle: #bundle, comment: "A chat waiting for the user's answer"))
        case .error:
            StatusDot(.danger)
                .accessibilityLabel(String(localized: "Stopped with an error", bundle: #bundle))
        case .idle:
            EmptyView()
        }
    }

    private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
}

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
                if link.isMissing {
                    Label(String(localized: "Not found", bundle: #bundle, comment: "A linked ticket whose file is missing"),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.warning)
                        .font(.callout)
                }
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
        .disabled(link.isMissing)
        .accessibilityIdentifier("ticket.link.\(link.id)")
    }
}

/// One entry of the ticket's history, with a comment's text and files under it.
private struct EventRow: View {
    let event: TicketEvent
    let projectID: Project.ID
    let model: TicketsModel
    let ticket: Ticket
    let onOpen: (TicketAttachment) -> Void

    @Environment(\.commentAnswers) private var answers

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
                    if let edited = event.editedAt {
                        Text("(edited)", bundle: #bundle)
                            .foregroundStyle(.textSecondary)
                            .help(Text(edited, format: .dateTime.day().month(.abbreviated).hour().minute()))
                    }
                    Spacer(minLength: 16)
                    Text(event.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.callout)
                        .foregroundStyle(.textSecondary)
                }
                if let comment = event.comment, !comment.isEmpty {
                    TicketText(comment, projectID: projectID, isComment: true)
                        .lineSpacing(2)
                        .foregroundStyle(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.surface, in: .rect(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                }
                if !event.attachments.isEmpty {
                    AttachmentStrip(attachments: event.attachments, projectID: projectID, model: model, ticket: ticket,
                                    removable: false, onOpen: onOpen)
                }
                if let id = event.commentID, let answers, let state = answers.state(id) {
                    CommentAnswerRow(state: state) { answers.retry(id) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Files of a ticket or a comment: images as thumbnails, others as chips. A click opens Quick Look.
private struct AttachmentStrip: View {
    let attachments: [TicketAttachment]
    let projectID: Project.ID
    let model: TicketsModel
    let ticket: Ticket
    /// Only a ticket's own files are removed one by one; a comment's go with it.
    let removable: Bool
    let onOpen: (TicketAttachment) -> Void
    /// The file Save As… writes elsewhere, while its panel shows.
    @State private var saving: AttachmentCopy?

    var body: some View {
        FlowStack(spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentView(attachment: attachment, url: { await model.url(of: attachment, in: ticket) })
                    .onTapGesture { onOpen(attachment) }
                    .contextMenu {
                        Button(String(localized: "Open", bundle: #bundle)) { onOpen(attachment) }
                        Button(String(localized: "Open With Default App", bundle: #bundle)) {
                            Task { if let url = await model.url(of: attachment, in: ticket) { NSWorkspace.shared.open(url) } }
                        }
                        Button(String(localized: "Show in Finder", bundle: #bundle)) {
                            Task {
                                if let url = await model.url(of: attachment, in: ticket) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                        Button(String(localized: "Save As…", bundle: #bundle)) {
                            Task {
                                if let url = await model.url(of: attachment, in: ticket) {
                                    saving = AttachmentCopy(url: url, name: attachment.name)
                                } else {
                                    model.failure = String(localized: "\(attachment.name) can't be found.", bundle: #bundle)
                                }
                            }
                        }
                        if removable {
                            Divider()
                            Button(String(localized: "Remove…", bundle: #bundle), role: .destructive) {
                                model.confirmation = .removeAttachment(ticket.id, attachment)
                            }
                        }
                    }
                    .accessibilityIdentifier("ticket.attachment.\(attachment.id.uuidString)")
            }
        }
        .fileExporter(isPresented: Binding { saving != nil } set: { if !$0 { saving = nil } }, document: saving,
                      contentType: .data, defaultFilename: saving?.name) { result in
            if case .failure(let error) = result {
                model.failure = error.localizedDescription
            }
            saving = nil
        }
    }
}

/// An attachment's file as Save As… writes it: a copy of the stored file, under the name the user picks. Its type
/// is `data`, which every file's conforms to, so the name keeps its own extension.
private struct AttachmentCopy: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.data]

    let url: URL
    let name: String

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

/// One attachment as AZDesign's file tile: a thumbnail at most 96 pt high and 192 pt wide with its name, or a
/// chip with its type's icon, its name and its size. Its file is found when it shows.
private struct AttachmentView: View {
    let attachment: TicketAttachment
    let url: () async -> URL?
    @State private var file: URL?

    var body: some View {
        FileTile(name: attachment.name, contentType: UTType(mimeType: attachment.contentType), size: Int64(attachment.size), url: file)
            .task(id: attachment.id) {
                if FileTile.isImage(UTType(mimeType: attachment.contentType)) { file = await url() }
            }
            .accessibilityAddTraits(.isButton)
    }
}

/// A file waiting to go with the next comment, with a button that takes it off.
private struct PendingFileChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc")
                .accessibilityHidden(true)
            Text(verbatim: url.lastPathComponent)
                .lineLimit(1)
            Button(String(localized: "Remove", bundle: #bundle), systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.textSecondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.surfaceSunken, in: .capsule)
        .accessibilityIdentifier("ticket.comment.file")
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
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 980, height: 760)
}

#Preview("Narrow", traits: .appChrome) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 600, height: 760)
}

#Preview("Loaded, Dark", traits: .appChrome) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 640, height: 720)
    .preferredColorScheme(.dark)
}

#Preview("Draft", traits: .appChrome) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-141", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 640, height: 720)
}

#Preview("Done", traits: .appChrome) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-130", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 640, height: 720)
}

#Preview("Editing", traits: .appChrome) {
    @Previewable @State var model = {
        let model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
        model.startEditing(model.selectedTicket!)
        return model
    }()
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 980, height: 760)
    .environment(\.generateTitle, GenerateTitleAction { _, _ in "Retry storm between checkout and payments" })
}

#Preview("Comment Draft", traits: .appChrome) {
    @Previewable @State var model = {
        let model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
        model.setCommentDraft("Backoff is in run 1288. Can you check the retries in tonight's batch?", for: "ORD-142")
        model.attach([URL(fileURLWithPath: "/tmp/batch.log")], to: "ORD-142")
        return model
    }()
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .frame(width: 640, height: 720)
}

#Preview("iPhone", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket, isCompact: true) }
    }
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 640, height: 800)) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
}

#Preview("Chats", traits: .appChrome) {
    @Previewable @State var model = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-142", store: SampleTicketStore())
    NavigationStack {
        TicketDetailView(ticket: model.selectedTicket!, model: model)
            .toolbar { TicketActions(ticket: model.selectedTicket) }
    }
    .environment(\.chatMentions, .samples)
    .environment(\.itemChats, .samples)
    .environment(\.implement, ImplementAction { _ in })
    .frame(width: 980, height: 900)
}

#Preview("Not Found", traits: .appChrome, .fixedLayout(width: 640, height: 480)) {
    TicketNotFoundView(id: "ORD-999", project: Project.sample("ORD")!)
}
