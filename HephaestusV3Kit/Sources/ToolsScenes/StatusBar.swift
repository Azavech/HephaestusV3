import AppKit
import AZDesign
import ChatData
import ChatKit
import SwiftUI
import ToolsFoundation
import UpdateData

/// Where feedback goes: the project chosen in Settings ▸ General, while it is loaded, and the chats that start
/// its feedback chats. Nil hides the status bar's ladybug and Help ▸ Send Feedback….
nonisolated struct FeedbackTarget: Sendable {
    let project: Project
    let chats: LiveChatStore
}

nonisolated extension EnvironmentValues {
    /// The feedback project of every window, from `RouteHost`.
    @Entry var feedbackTarget: FeedbackTarget? = nil
    /// The chats the status bar counts, from `RouteHost`; nil counts none.
    @Entry var chatSession: ChatSession? = nil
    /// The Updater, whose version and Update item the status bar shows, from `RouteHost`.
    @Entry var updateController: UpdateController? = nil
}

/// A chat the status bar counts: at work, or waiting for the user (docs/ui/navigation.md › Status bar).
struct StatusChat: Identifiable, Hashable {
    enum State: Hashable {
        case starting, running, waitingPermission, waitingAnswers
        /// Idle, its process's background work running: counted with the chats at work, as V2.
        case background

        var isWaiting: Bool { self == .waitingPermission || self == .waitingAnswers }

        var label: String {
            switch self {
            case .starting: String(localized: "Starting", bundle: #bundle, comment: "A chat's state in the status bar's popover")
            case .running: String(localized: "Running", bundle: #bundle, comment: "A chat's state in the status bar's popover")
            case .waitingPermission: String(localized: "Waiting for permission", bundle: #bundle, comment: "A chat's state in the status bar's popover")
            case .waitingAnswers: String(localized: "Waiting for answers", bundle: #bundle, comment: "A chat's state in the status bar's popover")
            case .background: String(localized: "Running in background", bundle: #bundle, comment: "A chat's state in the status bar's popover")
            }
        }
    }

    let id: String
    let title: String
    let projectID: String
    let state: State
    let updated: Date

    /// The chats of the session at work or waiting: waiting first, then at work, each the latest first.
    @MainActor
    static func list(_ session: ChatSession?) -> [StatusChat] {
        guard let session else { return [] }
        let chats = session.states.compactMap { id, state -> StatusChat? in
            let shown: State
            switch state {
            case .starting: shown = .starting
            case .running: shown = .running
            case .waitingPermission: shown = .waitingPermission
            case .waitingAnswers: shown = .waitingAnswers
            case .idle where session.backgroundWork.contains(id): shown = .background
            default: return nil
            }
            guard let chat = session.chats[id] else { return nil }
            return StatusChat(id: id, title: chat.file.title, projectID: chat.projectID, state: shown, updated: chat.file.updated)
        }
        return chats.sorted {
            $0.state.isWaiting != $1.state.isWaiting ? $0.state.isWaiting : ($0.updated, $0.id) > ($1.updated, $1.id)
        }
    }
}

/// What a window shows, for the line that says where feedback comes from.
nonisolated struct FeedbackSource: Hashable, Sendable {
    /// The window's name: a tool's title, Projects, Project Settings or Virtual Machines.
    let window: String
    /// The window's project, or the one selected in the Projects window.
    let project: Project?
    /// The item the window has selected, as the chat panel names it: `ORD-142`, `payments-api`, `Run 1288`.
    var item: String? = nil

    /// `App: Hephaestus V3 1.0.18 (40)`, `macOS 27.2`, `Window: Tickets`, `Project: Orders (ORD)`, `Item: ORD-142`:
    /// the sheet joins them with ` · `, the feedback chat's first message lists them (docs/ui/chat.md › Feedback).
    /// The window's name in the app's words; the rest as written here.
    func context(
        version: String = Self.appVersion, build: String = Self.appBuild,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [String] {
        var macOS = "\(system.majorVersion).\(system.minorVersion)"
        if system.patchVersion > 0 {
            macOS += ".\(system.patchVersion)"
        }
        var parts = ["App: Hephaestus V3 \(version) (\(build))", "macOS \(macOS)", "Window: \(window)"]
        if let project {
            parts.append("Project: \(project.name) (\(project.id))")
        }
        if let item {
            parts.append("Item: \(item)")
        }
        return parts
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
}

/// Starts feedback for the key window: Help ▸ Send Feedback… (⇧⌘B).
nonisolated struct SendFeedbackAction: Sendable {
    let start: @MainActor @Sendable () -> Void

    @MainActor
    func callAsFunction() {
        start()
    }
}

nonisolated extension FocusedValues {
    /// The key window's feedback; nil while there is no feedback project.
    @Entry var sendFeedback: SendFeedbackAction?
}

extension View {
    /// The status bar at the bottom of the window: the chats, the app's version and its update, the Claude plan's weekly
    /// usage, and the ladybug that sends feedback about the window while a feedback project is set
    /// (docs/ui/navigation.md › Status bar).
    func statusBar(_ source: FeedbackSource, countsChats: Bool = true) -> some View {
        modifier(StatusBarModifier(source: source, countsChats: countsChats))
    }
}

/// The window's content above the status bar; the Send Feedback sheet on the window.
private struct StatusBarModifier: ViewModifier {
    let source: FeedbackSource
    /// Whether the bar counts the chats and offers the update: not in a chat window, as V2's chat windows didn't.
    let countsChats: Bool
    @Environment(\.feedbackTarget) private var target
    @Environment(\.chatSession) private var chatSession
    @Environment(\.updateController) private var updates
    @Environment(\.openRoute) private var openRoute
    @State private var feedback = FeedbackStarter()

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarSlot(session: chatSession, countsChats: countsChats, updates: updates, start: feedbackStart, openChat: openChat)
        }
        .background {
            WindowReader { [feedback] window in feedback.window = window }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .focusedSceneValue(\.sendFeedback, target == nil ? nil : startAction)
        .sheet(item: Binding(get: { feedback.request }, set: { feedback.request = $0 })) { request in
            if let target {
                FeedbackView(project: target.project, chats: target.chats, screenshot: request.screenshot, context: request.context) { id in
                    feedback.finish(request)
                    // The feedback project's Chat tab shows the new chat (the user's choice).
                    if let id {
                        openRoute(.tool(.chat, project: target.project.id, focus: id))
                    }
                }
            }
        }
    }

    private var feedbackStart: (() -> Void)? {
        guard target != nil else { return nil }
        let action = startAction
        return { action() }
    }

    private func openChat(_ chat: StatusChat) {
        openRoute(.tool(.chat, project: chat.projectID, focus: chat.id))
    }

    private var startAction: SendFeedbackAction {
        SendFeedbackAction { [feedback, source, isOn = target != nil] in
            feedback.start(source, isOn: isOn)
        }
    }
}

/// The status bar: a view of its own, the only one of the window that reads the chats' states, the weekly usage and
/// the Updater's state, so that their changes draw the bar and not the window's content.
private struct StatusBarSlot: View {
    /// The chats, and the weekly usage their CLI reports; nil shows neither.
    let session: ChatSession?
    /// Whether the bar counts the chats and may show the Update item: not in a chat window.
    let countsChats: Bool
    let updates: UpdateController?
    let start: (() -> Void)?
    let openChat: (StatusChat) -> Void

    var body: some View {
        StatusBar(chats: StatusChat.list(countsChats ? session : nil),
                  version: (updates?.appVersion ?? AppVersion.running(Bundle.main.infoDictionary ?? [:])).display,
                  update: countsChats ? updates?.updateItem : nil, usage: session?.planUsage, install: { updates?.install() }, start: start,
                  openChat: openChat)
    }
}

/// The feedback of one window: the window, read without making it state, and the sheet it shows.
@MainActor
@Observable
final class FeedbackStarter {
    var request: FeedbackRequest?
    @ObservationIgnored weak var window: NSWindow?

    /// Captures the window, then opens the sheet on it, so that the sheet is never in the screenshot. Nothing
    /// without a feedback project, while the window shows a sheet, or while feedback is open.
    func start(_ source: FeedbackSource, isOn: Bool) {
        guard isOn, request == nil, let window, window.attachedSheet == nil, window.sheetParent == nil else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusV3-Feedback-\(UUID().uuidString)", isDirectory: true)
        var screenshot: URL?
        if let png = WindowCapture.capture(window) {
            let url = folder.appendingPathComponent("screenshot.png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: url)
                screenshot = url
            } catch {
                screenshot = nil
            }
        }
        request = FeedbackRequest(folder: folder, screenshot: screenshot, context: source.context())
    }

    /// Closes the sheet and deletes its screenshot.
    func finish(_ finished: FeedbackRequest) {
        request = nil
        try? FileManager.default.removeItem(at: finished.folder)
    }
}

/// One Send Feedback sheet: its temporary folder, the window's PNG in it, and the context lines.
struct FeedbackRequest: Identifiable {
    let id = UUID()
    let folder: URL
    let screenshot: URL?
    let context: [String]
}

/// The bar at the bottom of a window: 26 points high under a hairline, the chats at work and waiting in its
/// middle; the version, the Update item, the weekly usage and the ladybug at its right end.
struct StatusBar: View {
    let chats: [StatusChat]
    /// The app's version and build: `v1.0.43(78)`.
    let version: String
    /// The Update item; nil hides it.
    let update: UpdateItem?
    /// The Claude plan's weekly usage; hidden when nil, and from its reset time on.
    let usage: PlanUsage?
    /// A click on the Update item.
    let install: () -> Void
    /// Starts feedback; nil hides the ladybug.
    let start: (() -> Void)?
    let openChat: (StatusChat) -> Void

    @State private var showsChats = false
    /// The time the weekly usage is shown for, set again at its reset time, which hides it without waiting for a chat.
    @State private var usageClock = Date()

    init(chats: [StatusChat] = [], version: String = "v1.0.43(78)", update: UpdateItem? = nil, usage: PlanUsage? = nil,
         install: @escaping () -> Void = {}, start: (() -> Void)?, openChat: @escaping (StatusChat) -> Void = { _ in }) {
        self.chats = chats
        self.version = version
        self.update = update
        self.usage = usage
        self.install = install
        self.start = start
        self.openChat = openChat
    }

    var body: some View {
        let running = chats.filter { !$0.state.isWaiting }.count
        let waiting = chats.count - running
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if running > 0 {
                    Button { showsChats = true } label: {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("^[\(running) chat](inflect: true) running", bundle: #bundle, comment: "The status bar's count of the chats at work")
                        }
                    }
                    .accessibilityIdentifier("statusBar.runningChats")
                }
                if waiting > 0 {
                    Button { showsChats = true } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(.warning)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text("^[\(waiting) chat](inflect: true) waiting", bundle: #bundle, comment: "The status bar's count of the chats waiting for the user")
                        }
                    }
                    .accessibilityIdentifier("statusBar.waitingChats")
                }
                Spacer(minLength: 0)
                Text(verbatim: version)
                    .accessibilityLabel(Text("Version \(version)", bundle: #bundle, comment: "The status bar's version, for VoiceOver"))
                    .accessibilityIdentifier("statusBar.version")
                if let update {
                    updateItem(update)
                }
                if let weekly = WeeklyUsage(usage, now: usageClock) {
                    WeeklyUsageItem(usage: weekly)
                }
                if let start {
                    Button(action: start) {
                        Image(systemName: "ladybug")
                            .foregroundStyle(.textSecondary)
                    }
                    .help(Text("Send Feedback (⇧⌘B)", bundle: #bundle))
                    .accessibilityLabel(Text("Send Feedback", bundle: #bundle))
                    .accessibilityIdentifier("statusBar.feedback")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .popover(isPresented: $showsChats, arrowEdge: .top) {
                StatusChatsPopover(chats: chats) { chat in
                    showsChats = false
                    openChat(chat)
                }
            }
        }
        .background(.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusBar")
        .onChange(of: chats.isEmpty) { if chats.isEmpty { showsChats = false } }
        .task(id: usage?.resetsAt) {
            // The ring goes at the reset time, without waiting for a chat (docs/ui/navigation.md › Weekly usage).
            usageClock = Date()
            guard let resetsAt = usage?.resetsAt, resetsAt > usageClock else { return }
            guard (try? await Task.sleep(for: .seconds(resetsAt.timeIntervalSince(usageClock)))) != nil else { return }
            usageClock = Date()
        }
    }
}

extension StatusBar {
    /// `Update available…` in the accent color, a click installing the update; `Installing…` with a mini spinner,
    /// not clickable (docs/ui/updates.md › Update item).
    @ViewBuilder
    fileprivate func updateItem(_ item: UpdateItem) -> some View {
        switch item {
        case .available(let tooltip):
            Button(action: install) {
                Text("Update available…", bundle: #bundle, comment: "The status bar's Update item")
                    .foregroundStyle(.accent)
            }
            .help(UpdateTexts.tooltip(tooltip))
            .accessibilityIdentifier("statusBar.update")
        case .installing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Installing…", bundle: #bundle, comment: "An update installs")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("statusBar.update")
        }
    }
}

/// The status bar's chats: waiting first, then at work, each the latest first; a click opens the chat.
struct StatusChatsPopover: View {
    let chats: [StatusChat]
    let open: (StatusChat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(chats) { chat in
                Button { open(chat) } label: {
                    HStack(spacing: 8) {
                        Group {
                            if chat.state.isWaiting {
                                Circle()
                                    .fill(.warning)
                                    .frame(width: 7, height: 7)
                            } else {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .frame(width: 14)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: chat.title)
                                .foregroundStyle(.textPrimary)
                                .lineLimit(1)
                            Text(verbatim: "\(chat.projectID) · \(chat.state.label)")
                                .font(.caption)
                                .foregroundStyle(.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("statusBar.chats.\(chat.id)")
            }
        }
        .padding(6)
        .frame(minWidth: 260, maxWidth: 360, alignment: .leading)
        .accessibilityIdentifier("statusBar.chats")
    }
}

/// Help ▸ Send Feedback… (⇧⌘B): feedback about the key window; absent while no feedback project is set.
struct FeedbackCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            SendFeedbackMenuItem()
        }
    }
}

private struct SendFeedbackMenuItem: View {
    @FocusedValue(\.sendFeedback) private var sendFeedback

    var body: some View {
        if let sendFeedback {
            Button(String(localized: "Send Feedback…", bundle: #bundle, comment: "Help menu item, ⇧⌘B")) {
                sendFeedback()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}

private let previewChats = [
    StatusChat(id: "C2", title: "Refund rules", projectID: "ORD", state: .waitingPermission, updated: Date(timeIntervalSince1970: 1_800_000_200)),
    StatusChat(id: "C1", title: "Fix the totals", projectID: "ORD", state: .running, updated: Date(timeIntervalSince1970: 1_800_000_100)),
    StatusChat(id: "C3", title: "Retry the payment", projectID: "PAY", state: .starting, updated: Date(timeIntervalSince1970: 1_800_000_000)),
    StatusChat(id: "C4", title: "Watch the nightly batch", projectID: "PAY", state: .background, updated: Date(timeIntervalSince1970: 1_799_999_000)),
]

#Preview("Status Bar", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(start: {})
    }
}

#Preview("Status Bar, Dark", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(start: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Status Bar, Chats", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(chats: previewChats, start: {})
    }
}

#Preview("Status Bar, Chats Without Feedback", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(chats: Array(previewChats.prefix(1)), start: nil)
    }
}

#Preview("Status Bar, Update Available", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(update: .available(.ready(AppVersion(version: "1.0.44", build: 80), restartsWhenIdle: true)), start: {})
    }
}

#Preview("Status Bar, Installing, Dark", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(chats: Array(previewChats.prefix(1)), update: .installing, start: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Status Bar, Weekly Usage", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(chats: Array(previewChats.dropFirst().prefix(1)), usage: previewPlanUsage(0.34), start: {})
    }
}

#Preview("Status Bar, Weekly Usage Near the Limit, Dark", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(usage: previewPlanUsage(0.93, status: "allowed_warning"), start: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Status Bar, Weekly Usage Limited", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar(usage: previewPlanUsage(1, status: "rejected"), start: {})
    }
}

#Preview("Chats Popover", traits: .sizeThatFitsLayout) {
    StatusChatsPopover(chats: previewChats) { _ in }
}
