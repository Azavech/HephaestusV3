import AZDesign
import ChatData
import Observation
import SwiftUI
import ToolsFoundation

/// What the Implement sheet holds (docs/ui/tickets.md › Implement sheet): the ticket or bundle, and the settings of
/// the chat that Start creates, as V2's Implement sheet.
@MainActor
@Observable
final class ImplementModel {
    let target: ImplementTarget
    /// Settings ▸ Chat's model and effort, the other settings' defaults, each time the sheet opens.
    var settings: ChatSettings
    private(set) var isStarting = false
    /// Why Start failed.
    private(set) var failure: String?

    @ObservationIgnored private let cli: @MainActor () -> FeedbackCLI
    @ObservationIgnored private let starter: @MainActor (ChatSettings) async throws(ChatError) -> String

    init(target: ImplementTarget, settings: ChatSettings, cli: @escaping @MainActor () -> FeedbackCLI,
         start: @escaping @MainActor (ChatSettings) async throws(ChatError) -> String) {
        self.target = target
        self.settings = settings
        self.cli = cli
        starter = start
    }

    /// "Implement ORD-142", "Implement All ORD-B3".
    var heading: String {
        switch target.kind {
        case .ticket: String(localized: "Implement \(target.id)", bundle: #bundle, comment: "The Implement sheet's heading; the value is a ticket id")
        case .bundle: String(localized: "Implement All \(target.id)", bundle: #bundle, comment: "The Implement sheet's heading for a bundle; the value is a bundle id")
        }
    }

    /// Why Start waits for the CLI: it checks it, or it isn't there.
    var cliMessage: String? {
        switch cli() {
        case .available: nil
        case .checking: String(localized: "Checking the Claude CLI…", bundle: #bundle)
        case .unavailable(let reason): String(localized: "Claude CLI is not available: \(reason)", bundle: #bundle)
        }
    }

    var canStart: Bool { cli() == .available && !isStarting }

    /// Starts the chat; its id, or nil when it failed, with the reason kept.
    func start() async -> String? {
        guard canStart else { return nil }
        isStarting = true
        failure = nil
        defer { isStarting = false }
        do throws(ChatError) {
            return try await starter(settings)
        } catch {
            failure = error.description
            return nil
        }
    }
}

/// The Implement sheet: the settings of the chat that implements a ticket, or a bundle (docs/ui/tickets.md ›
/// Implement sheet). Start creates the chat; the window then opens it.
public struct ImplementView: View {
    @State private var model: ImplementModel
    private let models: [ClaudeModel]
    /// Called with the chat's id once it is started, or nil on Cancel.
    private let onFinish: (String?) -> Void

    /// `start` creates the chat with the settings chosen, and returns its id.
    public init(target: ImplementTarget, chats: LiveChatStore, start: @escaping @MainActor (ChatSettings) async throws(ChatError) -> String,
                onFinish: @escaping (String?) -> Void) {
        let session = chats.session
        _model = State(initialValue: ImplementModel(
            target: target, settings: session.defaults,
            cli: {
                let status = session.status
                if status.isAvailable { return .available }
                if status.checking || status.error == nil { return .checking }
                return .unavailable(status.error ?? "")
            },
            start: start
        ))
        models = session.models.isEmpty ? ClaudeModel.fallback : session.models
        self.onFinish = onFinish
    }

    init(model: ImplementModel, models: [ClaudeModel] = ClaudeModel.fallback, onFinish: @escaping (String?) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.models = models
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.heading)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: model.target.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])

            Form {
                Section {
                    ReplySettingsRows(models: models, settings: model.settings, identifier: "implement", isChat: true) { model.settings = $0 }
                } footer: {
                    if model.target.kind == .bundle {
                        Text("The ticket chats this chat starts take its settings.", bundle: #bundle)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                            .accessibilityIdentifier("implement.note")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isStarting)

            if let message = model.failure ?? model.cliMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(model.failure == nil ? .textSecondary : .danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("implement.message")
            }

            Divider()

            HStack {
                Spacer()
                if model.isStarting {
                    ProgressView().controlSize(.small)
                }
                Button(String(localized: "Cancel", bundle: #bundle), role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isStarting)
                    .accessibilityIdentifier("implement.cancel")
                Button(String(localized: "Start", bundle: #bundle, comment: "Starts the chat that implements a ticket or a bundle")) {
                    Task {
                        if let id = await model.start() {
                            onFinish(id)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .accessibilityIdentifier("implement.start")
            }
            .padding()
        }
        .background(.canvas)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("implement.sheet")
    }
}

#Preview("Ticket") {
    ImplementView(model: ImplementModel(
        target: ImplementTarget(.ticket, id: "ORD-142", projectID: "ORD", title: "Retry storm between checkout and payments"),
        settings: ChatSettings(), cli: { .available }, start: { _ in "chat" }
    ))
}

#Preview("Bundle, Dark") {
    ImplementView(model: ImplementModel(
        target: ImplementTarget(.bundle, id: "ORD-B3", projectID: "ORD", title: "Checkout reliability"),
        settings: ChatSettings(), cli: { .available }, start: { _ in "chat" }
    ))
    .preferredColorScheme(.dark)
}

#Preview("Failed") {
    let model = ImplementModel(
        target: ImplementTarget(.ticket, id: "ORD-130", projectID: "ORD", title: "Show the order's total in the receipt"),
        settings: ChatSettings(), cli: { .available },
        start: { _ throws(ChatError) in throw .conflict("ORD-130 is done; set another status to implement it.") }
    )
    ImplementView(model: model)
        .task { _ = await model.start() }
}
