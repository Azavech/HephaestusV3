import AZDesign
import ChatData
import SwiftUI

/// How much of the context the conversation uses, in the composer, as V2's indicator: a ring filled to the part
/// used, then "98% left"; green from 20 % left, orange under 20 %, red under 10 %. While the CLI compacts, the
/// ring fades in and out. The tooltip gives the tokens and the compactions.
struct ContextIndicator: View {
    let usage: ContextUsage
    let compactions: Int
    let isCompacting: Bool

    @State private var faded = false

    var body: some View {
        if let percent = usage.percentLeft {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.divider, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: 1 - Double(percent) / 100)
                        .stroke(color(percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .opacity(isCompacting && faded ? 0.3 : 1)
                .animation(isCompacting ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: faded)
                .onChange(of: isCompacting, initial: true) { faded = isCompacting }
                .accessibilityHidden(true)
                Text("\(percent)% left", bundle: #bundle, comment: "The part of the context left before compaction")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .monospacedDigit()
            }
            .help(Self.tooltip(usage, compactions: compactions))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.tooltip(usage, compactions: compactions))
            .accessibilityIdentifier("chat.context")
        }
    }

    private func color(_ percent: Int) -> Color {
        percent < 10 ? .danger : percent < 20 ? .warning : .success
    }

    /// "18.6K of 1M tokens used · 948.4K left before compaction", then "Compacted 2 times" after compactions.
    static func tooltip(_ usage: ContextUsage, compactions: Int) -> String {
        let used = tokens(usage.usedTokens), window = tokens(usage.windowTokens), left = tokens(usage.left)
        let first = String(localized: "\(used) of \(window) tokens used · \(left) left before compaction", bundle: #bundle,
                           comment: "The context indicator's tooltip: tokens used, the window, tokens left")
        switch compactions {
        case 0: return first
        case 1: return first + "\n" + String(localized: "Compacted once", bundle: #bundle)
        default: return first + "\n" + String(localized: "Compacted \(compactions) times", bundle: #bundle)
        }
    }

    /// `850`, `17.7K`, `120K`, `1M`, `1.5M`: at most one decimal, none when it is 0.
    static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return text + suffix
        }
        if count >= 1_000_000 { return short(Double(count) / 1_000_000, "M") }
        if count >= 1_000 { return short(Double(count) / 1_000, "K") }
        return String(count)
    }
}

/// Over the composer after an error, as V2's status line: "Claude stopped with an error", then Resume.
struct ResumeLine: View {
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Claude stopped with an error", bundle: #bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.danger)
            Spacer(minLength: 8)
            Button(String(localized: "Resume", bundle: #bundle, comment: "Has Claude go on after an error"), systemImage: "arrow.uturn.forward", action: resume)
                .help(String(localized: "Claude goes on from where it stopped, through the internal skill resume-chat.", bundle: #bundle))
                .accessibilityIdentifier("chat.resume")
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.resumeLine")
    }
}

/// In place of the composer of a closed chat, as V2's: "This conversation is over", and Reopen.
struct ClosedNotice: View {
    let reopen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("This conversation is over", bundle: #bundle)
                .foregroundStyle(.textSecondary)
            Spacer(minLength: 8)
            Button(String(localized: "Reopen", bundle: #bundle, comment: "Reopens a closed chat"), systemImage: "arrow.uturn.backward", action: reopen)
                .accessibilityIdentifier("chat.reopen")
        }
        .font(.callout)
        .padding(12)
        .background(.surfaceSunken, in: .field)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.closed")
    }
}

/// A chat row's mark of its state: a spinner while Claude works, an orange dot while a card or questions wait,
/// a red dot after an error; nothing when idle.
struct ChatMarkView: View {
    let mark: ChatMark?

    var body: some View {
        switch mark {
        case .working?:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(String(localized: "Working", bundle: #bundle, comment: "A chat where Claude works"))
        case .waiting?:
            StatusDot(.warning)
                .accessibilityLabel(String(localized: "Waiting for you", bundle: #bundle, comment: "A chat waiting for the user's answer"))
        case .error?:
            StatusDot(.danger)
                .accessibilityLabel(String(localized: "Stopped with an error", bundle: #bundle))
        case nil:
            EmptyView()
        }
    }
}

extension View {
    /// Tells the store which conversation the view shows, and whether its window is the key window: a chat
    /// shown in the key window gets no notification, and loses the one it had (docs/ui/chat.md › Notifications).
    func reportsShownChat(_ id: ChatConversation.ID?, store: any ChatStore) -> some View {
        modifier(ShownChatReporter(id: id, store: store))
    }
}

private struct ShownChatReporter: ViewModifier {
    let id: ChatConversation.ID?
    let store: any ChatStore

    @Environment(\.controlActiveState) private var activeState
    @State private var view = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { report() }
            .onChange(of: id) { report() }
            .onChange(of: activeState) { report() }
            .onDisappear { store.showing(nil, inKeyWindow: false, view: view) }
    }

    private func report() {
        store.showing(id, inKeyWindow: activeState == .key, view: view)
    }
}

/// V2's line over the composer while the Claude CLI is checked, and its banner, with Open Settings, while it
/// can't be used (docs/ui/chat.md › Claude CLI line). Nothing once the CLI is found.
struct ClaudeCLILine: View {
    let status: ClaudeStatus

    @Environment(\.openRoute) private var openRoute

    /// Whether the line has something to say.
    static func shows(_ status: ClaudeStatus?) -> Bool {
        guard let status else { return false }
        return status.checking || !status.isAvailable
    }

    var body: some View {
        if status.checking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the Claude CLI…", bundle: #bundle)
            }
            .font(.callout)
            .foregroundStyle(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.cliChecking")
        } else if !status.isAvailable {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(verbatim: status.error ?? String(localized: "The Claude CLI isn't available.", bundle: #bundle))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "Open Settings", bundle: #bundle, comment: "Opens Settings ▸ Chat, where the Claude CLI is set")) {
                    openRoute(.settings(.chat))
                }
                .accessibilityIdentifier("chat.cliUnavailable.openSettings")
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.cliUnavailable")
        }
    }
}

#Preview("Claude CLI Line, Checking", traits: .fixedLayout(width: 420, height: 60)) {
    ClaudeCLILine(status: .checking)
        .padding()
}

#Preview("Claude CLI Line, Not Found", traits: .fixedLayout(width: 420, height: 80)) {
    ClaudeCLILine(status: ClaudeStatus(error: "Claude CLI not found. Install Claude Code, or set its path in Settings ▸ Chat."))
        .padding()
}
