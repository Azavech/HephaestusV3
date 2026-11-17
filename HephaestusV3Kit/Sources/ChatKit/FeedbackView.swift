import AppKit
import AZDesign
import ChatData
import Observation
import QuickLook
import SwiftUI
import ToolsFoundation
import UniformTypeIdentifiers

/// Whether the Claude CLI can take the feedback, as the Send Feedback sheet says.
enum FeedbackCLI: Equatable {
    case available
    case checking
    case unavailable(String)
}

/// What the Send Feedback sheet holds (docs/ui/chat.md › Feedback): the window's screenshot, the comment, the
/// files added, the chat's model and effort, and the lines that say where the feedback comes from.
///
/// Send creates a feedback chat in the feedback project, whose first message calls the internal skill
/// `report-feedback` with all of it (`ChatSession.createFeedback`), as V2's Send Feedback did.
@MainActor
@Observable
final class FeedbackModel {
    var comment = ""
    /// The window's PNG, in a temporary folder; nil when the window couldn't be captured.
    let screenshot: URL?
    /// Whether Send sends the screenshot; on each time the sheet opens.
    var includesScreenshot = true
    /// The files added, in the order they were added.
    private(set) var files: [URL] = []
    /// `App: Hephaestus V3 1.0.18 (40)`, `macOS 27.2`, `Window: Tickets`, `Project: Orders (ORD)`, `Item: ORD-142`.
    let context: [String]
    let projectID: String
    /// The feedback project's name.
    let projectName: String
    /// The chat's model and effort: Settings ▸ Chat's defaults each time the sheet opens.
    var settings: ChatSettings
    private(set) var isSending = false
    /// Why a file wasn't added, or why Send failed.
    private(set) var failure: String?

    @ObservationIgnored private let cli: @MainActor () -> FeedbackCLI
    @ObservationIgnored private let sender: @MainActor (FeedbackReport) async throws(ChatError) -> String

    init(project: Project, screenshot: URL?, context: [String], settings: ChatSettings, cli: @escaping @MainActor () -> FeedbackCLI,
         send: @escaping @MainActor (FeedbackReport) async throws(ChatError) -> String) {
        projectID = project.id
        projectName = project.name
        self.screenshot = screenshot
        self.context = context
        self.settings = settings
        self.cli = cli
        sender = send
    }

    /// The context in one line, as the sheet shows it.
    var contextLine: String { context.joined(separator: " · ") }

    /// Why Send waits for the CLI: it checks it, or it isn't there.
    var cliMessage: String? {
        switch cli() {
        case .available: nil
        case .checking: String(localized: "Checking the Claude CLI…", bundle: #bundle)
        case .unavailable(let reason): String(localized: "Claude CLI is not available: \(reason)", bundle: #bundle)
        }
    }

    /// A comment with more than spaces in it, an available CLI, nothing being sent.
    var canSend: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cli() == .available && !isSending
    }

    /// Adds files, in order, leaving out those already added. A folder, or a file larger than 20 MB, adds
    /// nothing from that call, and says why.
    func add(_ urls: [URL]) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                failure = String(localized: "Folders cannot be attached.", bundle: #bundle)
                return
            }
            if let size = values?.fileSize, size > FeedbackReport.sizeLimit {
                failure = String(localized: "\(url.lastPathComponent) is larger than 20 MB.", bundle: #bundle)
                return
            }
        }
        failure = nil
        for url in urls where !files.contains(url) {
            files.append(url)
        }
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
    }

    /// What Send sends: the screenshot unless it is left out.
    var report: FeedbackReport {
        FeedbackReport(projectID: projectID, comment: comment, context: context, screenshot: includesScreenshot ? screenshot : nil,
                       files: files, settings: settings)
    }

    /// Creates the feedback chat; returns its id, or nil with the reason in `failure`.
    func send() async -> String? {
        guard canSend else { return nil }
        isSending = true
        failure = nil
        defer { isSending = false }
        do throws(ChatError) {
            return try await sender(report)
        } catch {
            failure = error.description
            return nil
        }
    }
}

/// The Send Feedback sheet: the window's screenshot, the comment and the files added, the chat's model and
/// effort, and where the feedback comes from. Send starts a feedback chat in the feedback project
/// (docs/ui/chat.md › Feedback).
public struct FeedbackView: View {
    @State private var model: FeedbackModel
    private let models: [ClaudeModel]
    /// Called with the chat's id once it is created, or nil on Cancel.
    private let onFinish: (String?) -> Void

    /// `screenshot` is the window's PNG; `context` the lines that say where the feedback comes from.
    public init(project: Project, chats: LiveChatStore, screenshot: URL?, context: [String], onFinish: @escaping (String?) -> Void) {
        let session = chats.session
        _model = State(initialValue: FeedbackModel(
            project: project, screenshot: screenshot, context: context, settings: session.defaults,
            cli: {
                let status = session.status
                if status.isAvailable { return .available }
                if status.checking || status.error == nil { return .checking }
                return .unavailable(status.error ?? "")
            },
            send: { report throws(ChatError) in try await session.createFeedback(report) }
        ))
        models = session.models.isEmpty ? ClaudeModel.fallback : session.models
        self.onFinish = onFinish
    }

    init(model: FeedbackModel, models: [ClaudeModel] = ClaudeModel.fallback, onFinish: @escaping (String?) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.models = models
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
                    TextField(
                        String(localized: "Comment", bundle: #bundle), text: $model.comment,
                        prompt: Text("What happened, and what did you expect?", bundle: #bundle), axis: .vertical
                    )
                    .lineLimit(4...8)
                    .labelsHidden()
                    .accessibilityIdentifier("feedback.comment")
                    files
                }

                Section {
                    LabeledContent(String(localized: "Project", bundle: #bundle)) {
                        Text(verbatim: model.projectName)
                    }
                    .accessibilityIdentifier("feedback.project")
                    ReplySettingsRows(models: models, settings: model.settings, identifier: "feedback") { model.settings = $0 }
                } footer: {
                    Text(verbatim: model.contextLine)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("feedback.context")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isSending)

            if let message = model.failure ?? model.cliMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(model.failure == nil ? .textSecondary : .danger)
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
                .disabled(model.isSending)
                .accessibilityIdentifier("feedback.attach")
                Spacer()
                if model.isSending {
                    ProgressView().controlSize(.small)
                }
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
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .help(Text("Send (⌘↩)", bundle: #bundle))
                .accessibilityIdentifier("feedback.send")
            }
            .padding()
        }
        .background(.canvas)
        .frame(minWidth: 520, idealWidth: 520, minHeight: 600, idealHeight: 700)
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.add(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isSending else { return false }
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

private let previewContext = ["App: Hephaestus V3 1.0.30 (51)", "macOS 27.2", "Window: Tickets", "Project: Orders (ORD)", "Item: ORD-142"]

@MainActor private func previewModel(screenshot: URL? = previewScreenshot(), cli: FeedbackCLI = .available) -> FeedbackModel {
    FeedbackModel(project: Project.sample("SHOP")!, screenshot: screenshot, context: previewContext, settings: ChatSettings(),
                  cli: { cli }, send: { _ throws(ChatError) in "PREVIEW" })
}

#Preview("Empty", traits: .appChrome, .sizeThatFitsLayout) {
    FeedbackView(model: previewModel())
}

#Preview("Filled, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    let model = previewModel()
    model.comment = "The ladybug hides behind the chat panel\n\nWith the chat panel open, the status bar's ladybug sits under the panel's divider."
    return FeedbackView(model: model)
        .preferredColorScheme(.dark)
}

#Preview("Screenshot Left Out", traits: .appChrome, .sizeThatFitsLayout) {
    let model = previewModel()
    model.includesScreenshot = false
    return FeedbackView(model: model)
}

#Preview("Not Captured", traits: .appChrome, .sizeThatFitsLayout) {
    FeedbackView(model: previewModel(screenshot: nil))
}

#Preview("No Claude CLI", traits: .appChrome, .sizeThatFitsLayout) {
    let model = previewModel(cli: .unavailable("Claude CLI not found."))
    model.comment = "Tabs close on click."
    return FeedbackView(model: model)
}
