import AZDesign
import ChatData
import SwiftUI
import ToolsFoundation

/// A workflow, a workflow's agent or a sub-agent of a chat, as the Chat window lists it under its chat
/// (docs/ui/chat.md › Agents).
struct ChatAgentRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case workflow, workflowAgent, subagent
    }

    let id: String
    let chatID: ChatConversation.ID
    let kind: Kind
    let title: String
    let phase: String?
    let name: String?
    let state: ChatAgentState
    /// A workflow's id; for a workflow agent, its workflow's.
    let workflowID: String?
    /// A sub-agent that failed or stopped and has its id: Resume can ask Claude to go on with it.
    let canResume: Bool
    /// The workflow runs: Stop Workflow stops it.
    let workflowRuns: Bool

    /// The list's tag of the row, beside the chats' ids: `agent|<chat>|<id>` or `workflow|<chat>|<id>`.
    var tag: String { Self.tag(kind == .workflow ? "workflow" : "agent", chatID: chatID, id: id) }

    static func tag(_ kind: String, chatID: ChatConversation.ID, id: String) -> String { "\(kind)|\(chatID)|\(id)" }

    /// The chat and the row of a tag; nil for a chat's id.
    static func parse(_ tag: String) -> (isWorkflow: Bool, chatID: String, id: String)? {
        let parts = tag.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "agent" || parts[0] == "workflow" else { return nil }
        return (parts[0] == "workflow", parts[1], parts[2])
    }

    var stateTitle: String {
        switch state {
        case .running: String(localized: "Running", bundle: #bundle, comment: "An agent's state")
        case .completed: String(localized: "Completed", bundle: #bundle, comment: "An agent's state")
        case .failed: String(localized: "Failed", bundle: #bundle, comment: "An agent's state")
        case .stopped: String(localized: "Stopped", bundle: #bundle, comment: "An agent's state")
        }
    }
}

/// An agent's or a workflow's mark, as a chat row's: a spinner while it runs, a red dot when it failed.
struct AgentStateMark: View {
    let state: ChatAgentState

    var body: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(String(localized: "Running", bundle: #bundle, comment: "An agent's state"))
        case .failed:
            StatusDot(.danger)
                .accessibilityLabel(String(localized: "Failed", bundle: #bundle, comment: "An agent's state"))
        case .completed, .stopped:
            EmptyView()
        }
    }
}

/// A row of the list under its chat, indented: a workflow's summary, an agent's title and phase.
struct AgentListRow: View {
    let row: ChatAgentRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind == .workflow ? "point.3.filled.connected.trianglepath.dotted" : "person.crop.circle.badge.clock")
                .foregroundStyle(.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title)
                    .lineLimit(1)
                    .foregroundStyle(.textPrimary)
                if let phase = row.phase {
                    Text(verbatim: phase)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            AgentStateMark(state: row.state)
        }
        .padding(.leading, row.kind == .workflowAgent ? 32 : 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.list.\(row.kind == .workflow ? "workflow" : "agent").\(row.id)")
    }
}

/// V2's agent view: the agent's transcript, read-only, under its header with Stop (a running workflow's agent)
/// or Resume (a sub-agent that failed or stopped).
struct AgentDetailView: View {
    let row: ChatAgentRow
    let store: any ChatStore
    let padding: CGFloat

    @State private var resumeFailure: String?
    @State private var resuming = false

    var body: some View {
        VStack(spacing: 0) {
            AgentHeader(title: row.title, chip: row.phase.map { String(localized: "Agent · \($0)", bundle: #bundle) } ?? String(localized: "Agent", bundle: #bundle),
                        state: row.state) {
                if row.workflowRuns, let workflow = row.workflowID {
                    Button(String(localized: "Stop", bundle: #bundle), systemImage: "stop.fill") { store.stopWorkflow(workflow, in: row.chatID) }
                        .help(String(localized: "Stop the Workflow and Its Agents", bundle: #bundle))
                        .accessibilityIdentifier("chat.agent.stop")
                } else if row.canResume {
                    Button(String(localized: "Resume", bundle: #bundle), systemImage: "arrow.uturn.forward") {
                        resuming = true
                        Task {
                            do throws(ChatSendError) {
                                try await store.resumeAgent(row.id, in: row.chatID)
                                resumeFailure = nil
                            } catch {
                                resumeFailure = error.message
                                resuming = false
                            }
                        }
                    }
                    .disabled(resuming)
                    .help(String(localized: "Claude resumes the agent where it stopped, through the internal skill resume-agent.", bundle: #bundle))
                    .accessibilityIdentifier("chat.agent.resume")
                }
            }
            Divider()
            if let resumeFailure {
                ChatFailure(message: resumeFailure)
                    .padding(.horizontal, padding)
                    .padding(.top, 8)
            }
            TranscriptScrollView(conversation: store.agentConversation(row), activity: nil, padding: padding, decide: { _, _ in }, stop: nil)
                .id(row.id)
        }
        .task(id: row.id) { await store.openAgent(row.id, in: row.chatID) }
        .onChange(of: row.state) { if row.state == .running { resuming = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.agent")
    }
}

/// V2's workflow view: its agents, each opening its own view, and Stop while it runs.
struct WorkflowDetailView: View {
    let row: ChatAgentRow
    let agents: [ChatAgentRow]
    let store: any ChatStore
    let select: (ChatAgentRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentHeader(title: row.title, chip: row.name.map { String(localized: "Workflow · \($0)", bundle: #bundle) } ?? String(localized: "Workflow", bundle: #bundle),
                        state: row.state) {
                if row.state == .running {
                    Button(String(localized: "Stop", bundle: #bundle), systemImage: "stop.fill") { store.stopWorkflow(row.id, in: row.chatID) }
                        .help(String(localized: "Stop the Workflow and Its Agents", bundle: #bundle))
                        .accessibilityIdentifier("chat.workflow.stop")
                }
            }
            Divider()
            if agents.isEmpty {
                ContentUnavailableView(String(localized: "No agents yet", bundle: #bundle), systemImage: "person.crop.circle.badge.clock")
                    .accessibilityIdentifier("chat.workflow.empty")
            } else {
                List(agents) { agent in
                    Button { select(agent) } label: {
                        HStack(spacing: 8) {
                            AgentStateMark(state: agent.state)
                                .frame(width: 14)
                            Text(verbatim: agent.title)
                                .foregroundStyle(.textPrimary)
                            if let phase = agent.phase {
                                Text(verbatim: phase)
                                    .foregroundStyle(.textSecondary)
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: agent.stateTitle)
                                .foregroundStyle(.textSecondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.workflow.agent.\(agent.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.workflow")
    }
}

/// The header of an agent's or a workflow's view: its title, a chip, its mark, and its button.
private struct AgentHeader<Action: View>: View {
    let title: String
    let chip: String
    let state: ChatAgentState
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: chip)
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.surface, in: .capsule)
            AgentStateMark(state: state)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
    }
}

#Preview("Workflow", traits: .fixedLayout(width: 640, height: 360)) {
    let store = SampleChatStore.withAgents()
    let rows = store.agentRows(of: "chat-checkout")
    WorkflowDetailView(row: rows[0], agents: rows.filter { $0.kind == .workflowAgent }, store: store) { _ in }
}

#Preview("Agent", traits: .fixedLayout(width: 640, height: 480)) {
    let store = SampleChatStore.withAgents()
    AgentDetailView(row: store.agentRows(of: "chat-checkout")[1], store: store, padding: 24)
}

#Preview("Sub-agent, Failed, Dark", traits: .fixedLayout(width: 640, height: 300)) {
    let store = SampleChatStore.withAgents()
    AgentDetailView(row: store.agentRows(of: "chat-checkout")[3], store: store, padding: 24)
        .preferredColorScheme(.dark)
}

#Preview("List Rows", traits: .fixedLayout(width: 300, height: 200)) {
    List(SampleChatStore.withAgents().agentRows(of: "chat-checkout")) { AgentListRow(row: $0) }
}
