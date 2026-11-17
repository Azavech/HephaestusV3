import AZDesign
import Observation
import QuickLook
import SwiftUI
import ToolsFoundation
import UniformTypeIdentifiers

/// What the Send Feedback sheet holds: a new ticket, as New Ticket makes it, with the window's screenshot, the
/// files added, and a line saying where the feedback comes from (docs/ui/tickets.md › Feedback).
///
/// Send creates a regular ticket in the feedback project: the title, the description followed by the context
/// line, the priority and the draft choice of New Ticket. Then the screenshot, unless it is left out, and the
/// added files become the ticket's attachments, in one request.
@MainActor
@Observable
final class FeedbackTicketModel {
    var draft: NewTicketDraft
    /// The window's PNG, in a temporary folder; nil when the window couldn't be captured.
    let screenshot: URL?
    /// Whether Send attaches the screenshot; on each time the sheet opens.
    var includesScreenshot = true
    /// The files added, in the order they were added.
    private(set) var files: [URL] = []
    /// "App: Hephaestus V3 1.0.18 (40) · macOS 27.2 · Window: Tickets · Project: Orders (ORD) · Item: ORD-12".
    let context: String
    /// The feedback project's name.
    let projectName: String
    private(set) var isSending = false
    /// Why a file wasn't added, or why Send failed.
    private(set) var message: String?
    /// The ticket Send created when its files couldn't be attached: the sheet then offers to show it.
    private(set) var createdWithoutFiles: String?

    @ObservationIgnored private let store: any TicketStore

    init(project: Project, screenshot: URL?, context: String, store: any TicketStore) {
        draft = NewTicketDraft(projectID: project.id)
        projectName = project.name
        self.screenshot = screenshot
        self.context = context
        self.store = store
    }

    /// The largest file a ticket takes, and the most one request takes together (docs/data.md › Attachments).
    static let attachmentLimit = 20 * 1024 * 1024

    var canSend: Bool {
        draft.canCreate && !isSending && createdWithoutFiles == nil
    }

    /// Adds files, in order, leaving out those already added. A folder, or a file larger than 20 MB, adds
    /// nothing from that call, and says why.
    func add(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                message = String(localized: "Folders cannot be attached.", bundle: #bundle)
                return
            }
            if let size = values?.fileSize, size > Self.attachmentLimit {
                message = String(localized: "\(url.lastPathComponent) is larger than 20 MB.", bundle: #bundle)
                return
            }
        }
        message = nil
        for url in urls where !files.contains(url) {
            files.append(url)
        }
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
    }

    /// The description of the ticket: what was typed, then the context line.
    static func details(_ text: String, context: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? context : "\(text)\n\n\(context)"
    }

    /// Creates the ticket, then attaches its files. Returns the ticket's id once both are done; nil when
    /// either failed, with the reason in `message`.
    func send() async -> String? {
        guard canSend else { return nil }
        isSending = true
        message = nil
        defer { isSending = false }
        var ticket = draft
        ticket.details = Self.details(draft.details, context: context)
        let id: String
        do throws(TicketStoreError) {
            guard let created = try await store.perform(.create(ticket)) else {
                message = String(localized: "The ticket couldn't be created.", bundle: #bundle)
                return nil
            }
            id = created
        } catch {
            message = error.message
            return nil
        }
        let attachments = (includesScreenshot ? [screenshot].compactMap { $0 } : []) + files
        guard !attachments.isEmpty else { return id }
        do throws(TicketStoreError) {
            try await store.perform(.addAttachments(id, attachments))
            return id
        } catch {
            createdWithoutFiles = id
            message = String(localized: "\(id) was created without its files: \(error.message)", bundle: #bundle)
            return nil
        }
    }
}

/// The Send Feedback sheet: the window's screenshot, then New Ticket's fields, the added files and where the
/// feedback comes from. Send creates a regular ticket in the feedback project (docs/ui/tickets.md › Feedback).
public struct FeedbackTicketView: View {
    @State private var model: FeedbackTicketModel
    /// Called with the ticket's id once it is created, or nil on Cancel.
    private let onFinish: (String?) -> Void

    /// `screenshot` is the window's PNG; `context` the line that says where the feedback comes from.
    public init(project: Project, store: LiveTicketStore, screenshot: URL?, context: String, onFinish: @escaping (String?) -> Void) {
        _model = State(initialValue: FeedbackTicketModel(project: project, screenshot: screenshot, context: context, store: store))
        self.onFinish = onFinish
    }

    init(model: FeedbackTicketModel, onFinish: @escaping (String?) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    @State private var previewed: URL?
    @State private var choosesFiles = false
    @State private var hovers = false

    public var body: some View {
        VStack(spacing: 0) {
            Text("Send Feedback", bundle: #bundle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
                .accessibilityAddTraits(.isHeader)

            Form {
                Section {
                    screenshot
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField(String(localized: "Title", bundle: #bundle), text: $model.draft.title, prompt: Text("Title", bundle: #bundle))
                        .labelsHidden()
                        .accessibilityIdentifier("feedback.title")
                    TextField(
                        String(localized: "Description", bundle: #bundle), text: $model.draft.details,
                        prompt: Text("What happened, and what did you expect?", bundle: #bundle), axis: .vertical
                    )
                    .lineLimit(4...8)
                    .labelsHidden()
                    .accessibilityIdentifier("feedback.description")
                    files
                }

                Section {
                    LabeledContent(String(localized: "Project", bundle: #bundle)) {
                        Text(verbatim: model.projectName)
                    }
                    .accessibilityIdentifier("feedback.project")
                    Picker(TicketWords.priority, selection: $model.draft.priority) {
                        Text(verbatim: TicketWords.none).tag(TicketPriority?.none)
                        ForEach(TicketPriority.allCases) { priority in
                            Text(verbatim: priority.title).tag(TicketPriority?.some(priority))
                        }
                    }
                    .accessibilityIdentifier("feedback.priority")
                    Toggle(String(localized: "Save as Draft", bundle: #bundle), isOn: $model.draft.startsAsDraft)
                        .accessibilityIdentifier("feedback.draft.toggle")
                } footer: {
                    Text(verbatim: model.context)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("feedback.context")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isSending)

            if let message = model.message {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("feedback.message")
            }

            Divider()

            HStack {
                Button(String(localized: "Attach Files…", bundle: #bundle), systemImage: "paperclip") {
                    choosesFiles = true
                }
                .disabled(model.isSending || model.createdWithoutFiles != nil)
                .accessibilityIdentifier("feedback.attach")
                Spacer()
                if model.isSending {
                    ProgressView().controlSize(.small)
                }
                if let created = model.createdWithoutFiles {
                    Button(String(localized: "Show Ticket", bundle: #bundle)) { onFinish(created) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("feedback.show")
                } else {
                    Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) { onFinish(nil) }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("feedback.cancel")
                    Button(String(localized: "Send", bundle: #bundle)) {
                        Task {
                            if let id = await model.send() {
                                onFinish(id)
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("feedback.send")
                }
            }
            .padding()
        }
        .background(.canvas)
        .frame(minWidth: 520, idealWidth: 520, minHeight: 600, idealHeight: 680)
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.add(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isSending, model.createdWithoutFiles == nil else { return false }
            model.add(urls)
            return true
        }
        .quickLookPreview($previewed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedback.sheet")
    }

    /// The PNG scaled to fit 480 × 300 points, dimmed while left out; the eye in its top-right corner leaves it
    /// out or puts it back, and a click elsewhere opens it in Quick Look.
    @ViewBuilder private var screenshot: some View {
        if let url = model.screenshot, let image = NSImage(contentsOf: url) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480, maxHeight: 300)
                    .frame(maxWidth: .infinity)
                    .opacity(model.includesScreenshot ? 1 : 0.4)
                    .contentShape(.rect)
                    .onTapGesture { previewed = url }
                    .accessibilityLabel(Text("Screenshot of the window", bundle: #bundle))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Opens it in Quick Look.", bundle: #bundle))
                    .accessibilityIdentifier("feedback.screenshot")
                Button {
                    model.includesScreenshot.toggle()
                } label: {
                    Image(systemName: model.includesScreenshot ? "eye" : "eye.slash")
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(8)
                .opacity(hovers || !model.includesScreenshot ? 1 : 0)
                .help(model.includesScreenshot ? Text("Exclude Screenshot", bundle: #bundle) : Text("Include Screenshot", bundle: #bundle))
                .accessibilityLabel(model.includesScreenshot ? Text("Exclude Screenshot", bundle: #bundle) : Text("Include Screenshot", bundle: #bundle))
                .accessibilityIdentifier("feedback.screenshot.toggle")
            }
            .padding(.vertical, 8)
            .onHover { hovers = $0 }
        } else {
            Label {
                Text("The window could not be captured.", bundle: #bundle)
            } icon: {
                Image(systemName: "eye.slash")
            }
            .foregroundStyle(.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .accessibilityIdentifier("feedback.screenshot.missing")
        }
    }

    /// A chip per added file: its icon, name and size, and a button that takes it out.
    @ViewBuilder private var files: some View {
        if !model.files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.files, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(verbatim: url.lastPathComponent)
                                .lineLimit(1)
                            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                Text(Int64(size), format: .byteCount(style: .file))
                                    .foregroundStyle(.textSecondary)
                            }
                            Button {
                                model.remove(url)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isSending)
                            .accessibilityLabel(Text("Remove \(url.lastPathComponent)", bundle: #bundle))
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.surface))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("feedback.file.\(url.lastPathComponent)")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: Previews

/// A sample screenshot for the previews: a gradient the size of a small window.
@MainActor private func previewScreenshot() -> URL? {
    let size = NSSize(width: 960, height: 600)
    let image = NSImage(size: size, flipped: false) { rect in
        NSGradient(colors: [.systemPurple, .systemIndigo])?.draw(in: rect, angle: -45)
        return true
    }
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        return nil
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackPreview-screenshot.png")
    try? png.write(to: url)
    return url
}

private let previewContext = "App: Hephaestus V3 1.0.18 (40) · macOS 27.2 · Window: Tickets · Project: Orders (ORD) · Item: ORD-142"

#Preview("Empty", traits: .appChrome, .sizeThatFitsLayout) {
    FeedbackTicketView(model: FeedbackTicketModel(project: Project.sample("ORD")!, screenshot: previewScreenshot(), context: previewContext,
                                                  store: SampleTicketStore()))
}

#Preview("Filled, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    let model = FeedbackTicketModel(project: Project.sample("ORD")!, screenshot: previewScreenshot(), context: previewContext,
                                    store: SampleTicketStore())
    model.draft.title = "The ladybug hides behind the chat panel"
    model.draft.details = "With the chat panel open, the status bar's ladybug sits under the panel's divider."
    return FeedbackTicketView(model: model)
        .preferredColorScheme(.dark)
}

#Preview("Screenshot Left Out", traits: .appChrome, .sizeThatFitsLayout) {
    let model = FeedbackTicketModel(project: Project.sample("ORD")!, screenshot: previewScreenshot(), context: previewContext,
                                    store: SampleTicketStore())
    model.includesScreenshot = false
    return FeedbackTicketView(model: model)
}

#Preview("Not Captured", traits: .appChrome, .sizeThatFitsLayout) {
    FeedbackTicketView(model: FeedbackTicketModel(project: Project.sample("ORD")!, screenshot: nil, context: previewContext,
                                                  store: SampleTicketStore()))
}
