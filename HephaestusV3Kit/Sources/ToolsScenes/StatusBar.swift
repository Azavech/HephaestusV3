import AppKit
import AZDesign
import ChatKit
import SwiftUI
import ToolsFoundation

/// Where feedback goes: the project chosen in Settings ▸ General, while it is loaded, and the chats that start
/// its feedback chats. Nil hides the status bar and Help ▸ Send Feedback….
nonisolated struct FeedbackTarget: Sendable {
    let project: Project
    let chats: LiveChatStore
}

nonisolated extension EnvironmentValues {
    /// The feedback project of every window, from `RouteHost`.
    @Entry var feedbackTarget: FeedbackTarget? = nil
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
    /// The status bar at the bottom of the window, with the ladybug that sends feedback about it; nothing while
    /// no feedback project is set (docs/ui/navigation.md › Status bar).
    func statusBar(_ source: FeedbackSource) -> some View {
        modifier(StatusBarModifier(source: source))
    }
}

/// The window's content above the status bar; the Send Feedback sheet on the window.
private struct StatusBarModifier: ViewModifier {
    let source: FeedbackSource
    @Environment(\.feedbackTarget) private var target
    @Environment(\.openRoute) private var openRoute
    @State private var feedback = FeedbackStarter()

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if target != nil {
                StatusBar(start: startAction.start)
            }
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

    private var startAction: SendFeedbackAction {
        SendFeedbackAction { [feedback, source, isOn = target != nil] in
            feedback.start(source, isOn: isOn)
        }
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

/// The bar at the bottom of a window: 26 points high under a hairline, with the ladybug at its right end.
struct StatusBar: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: start) {
                    Image(systemName: "ladybug")
                        .foregroundStyle(.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Send Feedback (⇧⌘B)", bundle: #bundle))
                .accessibilityLabel(Text("Send Feedback", bundle: #bundle))
                .accessibilityIdentifier("statusBar.feedback")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        .background(.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusBar")
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

#Preview("Status Bar", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar {}
    }
}

#Preview("Status Bar, Dark", traits: .fixedLayout(width: 600, height: 60)) {
    VStack(spacing: 0) {
        Color.clear
        StatusBar {}
    }
    .preferredColorScheme(.dark)
}
