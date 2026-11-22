import FileStorage
import Foundation
import MCPKit

/// What a workflow or an agent does (docs/data.md › Agents), as V2's `ChatAgentState`.
public enum ChatAgentState: String, Sendable, Hashable {
    case running, completed, failed, stopped
}

/// A workflow Claude runs with the Workflow tool, its agents working beside the chat (docs/data.md › Agents).
public struct ChatWorkflow: Sendable, Hashable, Identifiable {
    /// The CLI's task id.
    public var id: String
    /// The Workflow call that launched it.
    public var toolUseID: String?
    /// The run's id, which names its folder.
    public var runID: String?
    public var name: String?
    public var summary: String
    public var state: ChatAgentState
    public var started: Date
    public var ended: Date?

    public init(id: String, toolUseID: String?, runID: String? = nil, name: String?, summary: String, state: ChatAgentState = .running,
                started: Date, ended: Date? = nil) {
        self.id = id
        self.toolUseID = toolUseID
        self.runID = runID
        self.name = name
        self.summary = summary
        self.state = state
        self.started = started
        self.ended = ended
    }

    var json: JSONValue {
        ["workflow": ["id": .string(id), "toolUseID": toolUseID.map(JSONValue.string) ?? .null, "runID": runID.map(JSONValue.string) ?? .null,
                      "name": name.map(JSONValue.string) ?? .null, "summary": .string(summary), "state": .string(state.rawValue),
                      "started": .string(ISODate.string(from: started)), "ended": ended.map { .string(ISODate.string(from: $0)) } ?? .null]]
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let started = json["started"]?.stringValue.flatMap(ISODate.date(from:)) else { return nil }
        self.init(id: id, toolUseID: json["toolUseID"]?.stringValue, runID: json["runID"]?.stringValue, name: json["name"]?.stringValue,
                  summary: json["summary"]?.stringValue ?? "Workflow", state: json["state"]?.stringValue.flatMap(ChatAgentState.init(rawValue:)) ?? .stopped,
                  started: started, ended: json["ended"]?.stringValue.flatMap(ISODate.date(from:)))
    }
}

/// An agent of a chat: one of a workflow's, or a sub-agent Claude started with the Agent tool.
public struct ChatAgent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case workflow, subagent
    }

    /// A workflow agent's `agentId`, or a sub-agent's call id.
    public var id: String
    public var kind: Kind
    public var workflowID: String?
    public var title: String
    public var phase: String?
    /// A sub-agent's id for the CLI, which `SendMessage` takes to resume it.
    public var taskID: String?
    public var state: ChatAgentState
    public var started: Date
    public var ended: Date?
    /// A sub-agent started in the background: its call's result only says it started.
    public var inBackground = false

    public init(id: String, kind: Kind, workflowID: String? = nil, title: String, phase: String? = nil, taskID: String? = nil,
                state: ChatAgentState = .running, started: Date, ended: Date? = nil) {
        self.id = id
        self.kind = kind
        self.workflowID = workflowID
        self.title = title
        self.phase = phase
        self.taskID = taskID
        self.state = state
        self.started = started
        self.ended = ended
    }

    var json: JSONValue {
        ["agent": ["id": .string(id), "kind": .string(kind.rawValue), "workflowID": workflowID.map(JSONValue.string) ?? .null,
                   "title": .string(title), "phase": phase.map(JSONValue.string) ?? .null, "taskID": taskID.map(JSONValue.string) ?? .null,
                   "state": .string(state.rawValue), "started": .string(ISODate.string(from: started)),
                   "ended": ended.map { .string(ISODate.string(from: $0)) } ?? .null]]
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let started = json["started"]?.stringValue.flatMap(ISODate.date(from:)) else { return nil }
        self.init(id: id, kind: kind, workflowID: json["workflowID"]?.stringValue, title: json["title"]?.stringValue ?? "Agent",
                  phase: json["phase"]?.stringValue, taskID: json["taskID"]?.stringValue,
                  state: json["state"]?.stringValue.flatMap(ChatAgentState.init(rawValue:)) ?? .stopped, started: started,
                  ended: json["ended"]?.stringValue.flatMap(ISODate.date(from:)))
    }
}

/// A chat's workflows and agents, in the order they started.
public struct ChatAgents: Sendable, Hashable {
    public var workflows: [ChatWorkflow] = []
    public var agents: [ChatAgent] = []

    public init(workflows: [ChatWorkflow] = [], agents: [ChatAgent] = []) {
        self.workflows = workflows
        self.agents = agents
    }

    public var isEmpty: Bool { workflows.isEmpty && agents.isEmpty }

    /// V2's agents file read back: each line a whole record, the last of an id winning; a record still running
    /// was cut short by the app's end, and reads as stopped.
    static func read(_ data: Data) -> ChatAgents {
        var result = ChatAgents()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let value = try? JSONValue.parse(Data(line)) else { continue }
            if let record = value["workflow"].flatMap(ChatWorkflow.init(json:)) {
                result.put(record)
            } else if let record = value["agent"].flatMap(ChatAgent.init(json:)) {
                result.put(record)
            }
        }
        for index in result.workflows.indices where result.workflows[index].state == .running { result.workflows[index].state = .stopped }
        for index in result.agents.indices where result.agents[index].state == .running { result.agents[index].state = .stopped }
        return result
    }

    mutating func put(_ workflow: ChatWorkflow) {
        if let index = workflows.firstIndex(where: { $0.id == workflow.id }) { workflows[index] = workflow } else { workflows.append(workflow) }
    }

    mutating func put(_ agent: ChatAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
    }
}

/// The lines of a workflow agent's transcript in the CLI's folder, made items (docs/data.md › Agents).
enum AgentTranscriptLine {
    static func items(_ line: JSONValue, read: Date) -> [ChatItem] {
        let created = line["timestamp"]?.stringValue.flatMap { ISODate.date(from: String($0.prefix(19)) + "Z") } ?? read
        let message = line["message"]
        switch line["type"]?.stringValue {
        case "assistant":
            guard let id = message?["id"]?.stringValue, let blocks = message?["content"]?.arrayValue else { return [] }
            let offset = line["apiBlockIndex"]?.intValue ?? 0
            return blocks.enumerated().compactMap { index, block in
                let itemID = "\(id)#\(index + offset)"
                switch block["type"]?.stringValue {
                case "text":
                    return .assistant(AssistantItem(id: itemID, created: created, text: block["text"]?.stringValue ?? "", messageID: id))
                case "thinking":
                    guard let text = block["thinking"]?.stringValue, !text.isEmpty else { return nil }
                    return .thinking(ThinkingItem(id: itemID, created: created, text: text))
                case "tool_use":
                    guard let toolUseID = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                    let split = ToolUseItem.split(name)
                    return .toolUse(ToolUseItem(id: itemID, created: created, toolUseID: toolUseID, name: split.name, server: split.server,
                                                input: StreamMapper.truncated(block["input"] ?? [:])))
                default:
                    return nil
                }
            }
        case "user":
            guard let uuid = line["uuid"]?.stringValue else { return [] }
            if let text = message?["content"]?.stringValue {
                return line["isMeta"]?.boolValue == true ? [] : [.user(UserItem(id: uuid, created: created, text: text, sender: "Claude"))]
            }
            let blocks = message?["content"]?.arrayValue ?? []
            var items: [ChatItem] = blocks.compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let toolUseID = block["tool_use_id"]?.stringValue else { return nil }
                let text: String = switch block["content"] {
                case .string(let value)?: value
                case .array(let parts)?: parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                default: ""
                }
                return .toolResult(ToolResultItem(id: "\(toolUseID)#result", created: created, toolUseID: toolUseID,
                                                  text: StreamMapper.truncated(text), isError: block["is_error"]?.boolValue ?? false))
            }
            let texts = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
            if !texts.isEmpty { items.append(.user(UserItem(id: uuid, created: created, text: texts.joined(separator: "\n"), sender: "Claude"))) }
            return items
        default:
            return []
        }
    }
}

/// The CLI's folder of a running workflow, read every second: its journal and its agents' transcripts.
final class WorkflowFolderReader {
    let workflowID: String
    let folder: URL
    /// The bytes of each file already read.
    var offsets: [String: UInt64] = [:]
    var task: Task<Void, Never>?

    init(workflowID: String, folder: URL) {
        self.workflowID = workflowID
        self.folder = folder
    }

    /// The complete lines added to `name` since the last read; nil while it can't be read.
    func newLines(_ name: String) -> [JSONValue]? {
        let url = folder.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = offsets[name] ?? 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data[data.startIndex...end]
        offsets[name] = start + UInt64(complete.count)
        return complete.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONValue.parse(Data($0)) }
    }
}

extension ChatSession {
    /// How often a running workflow's folder is read.
    static let workflowReadInterval: Duration = .seconds(1)

    /// The chat's workflows and agents, as read (`loadAgents`) and since changed; none before.
    public func agents(of chatID: String) -> ChatAgents {
        agentRecords[chatID] ?? ChatAgents()
    }

    /// Reads the chat's agents file, once.
    func loadAgents(_ chatID: String) {
        guard agentRecords[chatID] == nil, let folder = agentsFolder(chatID),
              let data = try? Data(contentsOf: folder.appendingPathComponent("agents.jsonl")) else { return }
        let read = ChatAgents.read(data)
        if !read.isEmpty { agentRecords[chatID] = read }
    }

    /// `chats/<CHAT-ID>/`, which holds the agents file and the workflow agents' transcripts.
    func agentsFolder(_ chatID: String) -> URL? {
        folder(of: chatID)?.chatsFolder.appendingPathComponent(chatID, isDirectory: true)
    }

    /// Stores a record: the whole record is appended to the agents file, and the session publishes it.
    func store(_ change: (inout ChatAgents) -> Void, in chatID: String, lines: [JSONValue]) {
        loadAgents(chatID)
        var records = agents(of: chatID)
        change(&records)
        agentRecords[chatID] = records
        guard !lines.isEmpty, let folder = agentsFolder(chatID) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("agents.jsonl")
        var data = Data()
        for line in lines {
            data += line.data
            data.append(UInt8(ascii: "\n"))
        }
        try? Transcript.append(data, to: url, endingLine: true)
    }

    func put(_ workflow: ChatWorkflow, in chatID: String) {
        loadAgents(chatID)
        guard agents(of: chatID).workflows.first(where: { $0.id == workflow.id }) != workflow else { return }
        store({ $0.put(workflow) }, in: chatID, lines: [workflow.json])
    }

    func put(_ agent: ChatAgent, in chatID: String) {
        loadAgents(chatID)
        guard agents(of: chatID).agents.first(where: { $0.id == agent.id }) != agent else { return }
        store({ $0.put(agent) }, in: chatID, lines: [agent.json])
    }

    // MARK: Lines of the CLI

    /// A chat item that starts or ends a sub-agent, or tells where a workflow's folder is.
    func noteAgents(of item: ChatItem, in chatID: String) {
        loadAgents(chatID)
        switch item {
        case .toolUse(let use) where use.server == nil && (use.name == "Agent" || use.name == "Task"):
            guard !agents(of: chatID).agents.contains(where: { $0.id == use.toolUseID }) else { return }
            var agent = ChatAgent(id: use.toolUseID, kind: .subagent,
                                  title: use.input["description"]?.stringValue ?? use.input["subagent_type"]?.stringValue ?? "Agent", started: now())
            agent.inBackground = use.input["run_in_background"]?.boolValue == true
            put(agent, in: chatID)
        case .toolResult(let result):
            if var agent = agents(of: chatID).agents.first(where: { $0.id == result.toolUseID && $0.kind == .subagent }) {
                if agent.taskID == nil, let id = Self.agentID(inResult: result.text) { agent.taskID = id }
                if !agent.inBackground, agent.state == .running {
                    agent.state = result.isError ? .failed : .completed
                    agent.ended = now()
                }
                put(agent, in: chatID)
            } else if let use = toolUse(result.toolUseID, inChat: chatID), use.name == "Workflow" {
                applyWorkflowLaunch(result.text, in: chatID)
            }
        default:
            break
        }
    }

    private func toolUse(_ toolUseID: String, inChat chatID: String) -> ToolUseItem? {
        for case .toolUse(let use) in (transcripts[chatID] ?? []).reversed() where use.toolUseID == toolUseID { return use }
        return nil
    }

    /// The `agentId: <id>` line of a sub-agent call's result: the CLI's id of the agent.
    static func agentID(inResult text: String) -> String? {
        let ids = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("agentId: ") else { return nil }
            let id = line.dropFirst("agentId: ".count).prefix { $0 != " " }
            return id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) == nil ? nil : String(id)
        }
        return ids.last
    }

    /// The Workflow call's result: its task id, run id and folder, which the session then reads every second.
    func applyWorkflowLaunch(_ text: String, in chatID: String) {
        // "Workflow launched in background. Task ID: <id>", then lines "Run ID: <id>", "Transcript dir: <path>".
        func value(_ label: String) -> String? {
            for line in text.split(whereSeparator: \.isNewline) {
                if let range = line.range(of: label) { return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        guard let taskID = value("Task ID: "), let runID = value("Run ID: "), let dir = value("Transcript dir: "),
              dir.hasPrefix("/"), URL(fileURLWithPath: dir).lastPathComponent == runID else { return }
        workflowFolders[taskID] = (chatID, URL(fileURLWithPath: dir, isDirectory: true))
        if var workflow = agents(of: chatID).workflows.first(where: { $0.id == taskID }) {
            workflow.runID = runID
            put(workflow, in: chatID)
            followWorkflow(taskID, in: chatID)
        }
    }

    /// A `system` line about tasks: workflows start, progress and end; sub-agents get their id, end, and run again.
    func applyTaskLine(_ line: JSONValue, in chatID: String) {
        loadAgents(chatID)
        let taskID = line["task_id"]?.stringValue ?? ""
        let toolUseID = line["tool_use_id"]?.stringValue
        let records = agents(of: chatID)
        switch line["subtype"]?.stringValue {
        case "task_started":
            switch line["task_type"]?.stringValue {
            case "local_workflow":
                guard !records.workflows.contains(where: { $0.id == taskID }) else { return }
                let summary = line["description"]?.stringValue ?? "Workflow"
                put(ChatWorkflow(id: taskID, toolUseID: toolUseID, name: line["workflow_name"]?.stringValue, summary: summary, started: now()), in: chatID)
                if workflowFolders[taskID] != nil {
                    if var workflow = agents(of: chatID).workflows.first(where: { $0.id == taskID }) {
                        workflow.runID = workflowFolders[taskID]?.folder.lastPathComponent
                        put(workflow, in: chatID)
                    }
                    followWorkflow(taskID, in: chatID)
                }
            case "local_agent":
                if var agent = records.agents.first(where: { $0.kind == .subagent && $0.id == toolUseID && $0.taskID == nil }) {
                    agent.taskID = taskID
                    put(agent, in: chatID)
                } else if var agent = records.agents.first(where: { $0.kind == .subagent && $0.taskID == taskID && $0.state != .running }) {
                    // Claude resumed it with SendMessage.
                    agent.state = .running
                    agent.ended = nil
                    put(agent, in: chatID)
                }
            default:
                break
            }
        case "task_progress":
            guard var workflow = records.workflows.first(where: { $0.id == taskID }), workflow.state == .running else { return }
            if let summary = line["summary"]?.stringValue, summary != workflow.summary {
                workflow.summary = summary
                put(workflow, in: chatID)
            }
            for entry in line["workflow_progress"]?.arrayValue ?? [] where entry["type"]?.stringValue == "workflow_agent" {
                guard let id = entry["agentId"]?.stringValue else { continue }
                var agent = agents(of: chatID).agents.first { $0.id == id }
                    ?? ChatAgent(id: id, kind: .workflow, workflowID: taskID, title: entry["label"]?.stringValue ?? "Agent", started: now())
                guard agent.state == .running else { continue }
                agent.title = entry["label"]?.stringValue ?? agent.title
                agent.phase = entry["phaseTitle"]?.stringValue ?? agent.phase
                switch entry["state"]?.stringValue {
                case "done": agent.state = .completed
                case "error": agent.state = .failed
                default: break
                }
                if agent.state != .running { agent.ended = now() }
                put(agent, in: chatID)
            }
        case "task_updated":
            let status = line["patch"]?["status"]?.stringValue
            endWorkflow(taskID, status: status == "killed" ? "stopped" : status, in: chatID)
        case "task_notification":
            let status = line["status"]?.stringValue
            if records.workflows.contains(where: { $0.id == taskID }) {
                endWorkflow(taskID, status: status, in: chatID)
            } else if var agent = records.agents.first(where: { $0.kind == .subagent && ($0.id == toolUseID || ($0.taskID != nil && $0.taskID == taskID)) }),
                      agent.state == .running, let state = status.flatMap(Self.endState) {
                agent.state = state
                agent.ended = now()
                put(agent, in: chatID)
            }
        default:
            break
        }
    }

    private static func endState(_ status: String) -> ChatAgentState? {
        switch status {
        case "completed": .completed
        case "failed": .failed
        case "stopped", "killed": .stopped
        default: nil
        }
    }

    private func endWorkflow(_ id: String, status: String?, in chatID: String) {
        guard var workflow = agents(of: chatID).workflows.first(where: { $0.id == id }), workflow.state == .running,
              let state = status.flatMap(Self.endState) else { return }
        workflow.state = state
        workflow.ended = now()
        put(workflow, in: chatID)
        // A last read of the folder, then its agents still running stop.
        readWorkflowFolder(id, in: chatID)
        for var agent in agents(of: chatID).agents where agent.workflowID == id && agent.state == .running {
            agent.state = .stopped
            agent.ended = now()
            put(agent, in: chatID)
        }
        workflowReaders[id]?.task?.cancel()
        workflowReaders[id] = nil
    }

    /// A result line ends the sub-agents of the turn that weren't started in the background.
    func stopForegroundAgents(in chatID: String) {
        for var agent in agents(of: chatID).agents where agent.kind == .subagent && agent.state == .running && !agent.inBackground {
            agent.state = .stopped
            agent.ended = now()
            put(agent, in: chatID)
        }
    }

    /// The process ended: whatever runs stops.
    func stopAllAgents(in chatID: String) {
        let records = agents(of: chatID)
        for var workflow in records.workflows where workflow.state == .running {
            workflow.state = .stopped
            workflow.ended = now()
            put(workflow, in: chatID)
            workflowReaders[workflow.id]?.task?.cancel()
            workflowReaders[workflow.id] = nil
        }
        for var agent in records.agents where agent.state == .running {
            agent.state = .stopped
            agent.ended = now()
            put(agent, in: chatID)
        }
    }

    // MARK: Workflow folders

    private func followWorkflow(_ id: String, in chatID: String) {
        guard workflowReaders[id] == nil, let folder = workflowFolders[id]?.folder else { return }
        let reader = WorkflowFolderReader(workflowID: id, folder: folder)
        workflowReaders[id] = reader
        readWorkflowFolder(id, in: chatID)
        reader.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.workflowReadInterval)
                guard !Task.isCancelled, let self else { return }
                self.readWorkflowFolder(id, in: chatID)
            }
        }
    }

    /// Reads what the CLI added to the workflow's folder: agents started and ended, their transcripts' items.
    func readWorkflowFolder(_ id: String, in chatID: String) {
        guard let reader = workflowReaders[id] else { return }
        for entry in reader.newLines("journal.jsonl") ?? [] {
            guard let agentID = entry["agentId"]?.stringValue else { continue }
            switch entry["type"]?.stringValue {
            case "started":
                guard !agents(of: chatID).agents.contains(where: { $0.id == agentID }) else { continue }
                put(ChatAgent(id: agentID, kind: .workflow, workflowID: id, title: entry["label"]?.stringValue ?? "Agent",
                              phase: entry["phase"]?.stringValue, started: now()), in: chatID)
            case "result":
                guard var agent = agents(of: chatID).agents.first(where: { $0.id == agentID }), agent.state == .running else { continue }
                agent.state = .completed
                agent.ended = now()
                put(agent, in: chatID)
            default:
                break
            }
        }
        for agent in agents(of: chatID).agents where agent.workflowID == id {
            guard let lines = reader.newLines("agent-\(agent.id).jsonl"), !lines.isEmpty else { continue }
            let items = lines.flatMap { AgentTranscriptLine.items($0, read: now()) }
            addAgentItems(items, agent: agent.id, in: chatID)
        }
    }

    /// Adds items to a workflow agent's file, and to its transcript in memory when a view read it; one it has is
    /// skipped.
    func addAgentItems(_ items: [ChatItem], agent: String, in chatID: String) {
        var known = agentItemIDs[agent] ?? knownItemIDs(of: agent, in: chatID)
        var new: [ChatItem] = []
        for item in items where known.insert(item.id).inserted {
            new.append(item)
        }
        guard !new.isEmpty, let folder = agentsFolder(chatID)?.appendingPathComponent("agents", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(agent).jsonl")
        try? Transcript.append(new.reduce(into: Data()) { $0 += Transcript.line(.add, $1) }, to: url, endingLine: true)
        agentItemIDs[agent] = known
        agentTranscripts[agent]?.append(contentsOf: new)
    }

    /// The ids of a workflow agent's items: from its transcript in memory, else from its file.
    private func knownItemIDs(of agent: String, in chatID: String) -> Set<String> {
        if let items = agentTranscripts[agent] { return Set(items.map(\.id)) }
        let data = agentsFolder(chatID).flatMap { try? Data(contentsOf: $0.appendingPathComponent("agents/\(agent).jsonl")) } ?? Data()
        return Set(Transcript.replay(data).map(\.id))
    }

    /// An agent's transcript: a workflow agent's from its file; a sub-agent's from the chat's own items, its
    /// prompt first, then every item of its call, at any depth (docs/data.md › Agents).
    public func agentTranscript(_ agentID: String, in chatID: String) -> [ChatItem] {
        guard let agent = agents(of: chatID).agents.first(where: { $0.id == agentID }) else { return [] }
        if agent.kind == .workflow {
            return agentTranscripts[agentID] ?? []
        }
        let items = transcripts[chatID] ?? []
        var calls: Set<String> = [agentID]
        var result: [ChatItem] = []
        var prompt: UserItem?
        for item in items {
            switch item {
            case .toolUse(let use) where use.toolUseID == agentID:
                prompt = UserItem(id: "\(agentID)#prompt", created: use.created, text: use.input["prompt"]?.stringValue ?? "", sender: "Claude")
            case .toolUse(let use) where use.parentToolUseID.map(calls.contains) == true:
                if use.name == "Agent" || use.name == "Task" { calls.insert(use.toolUseID) }
                result.append(item)
            case .assistant(let text) where text.parentToolUseID.map(calls.contains) == true:
                result.append(item)
            case .thinking(let thinking) where thinking.parentToolUseID.map(calls.contains) == true:
                result.append(item)
            default:
                break
            }
        }
        let uses = Set(result.compactMap { if case .toolUse(let use) = $0 { use.toolUseID } else { nil } })
        let kept = Set(result.map(\.id))
        var withResults: [ChatItem] = []
        for item in items {
            if kept.contains(item.id) {
                withResults.append(item)
            } else if case .toolResult(let end) = item, uses.contains(end.toolUseID) {
                withResults.append(item)
            }
        }
        return (prompt.map { [.user($0)] } ?? []) + withResults
    }

    /// Reads a workflow agent's transcript file, once, for its view; a sub-agent's is the chat's.
    public func openAgent(_ agentID: String, in chatID: String) async {
        if agents(of: chatID).agents.first(where: { $0.id == agentID })?.kind == .subagent {
            await open(chatID)
        } else {
            loadAgentTranscript(agentID, in: chatID)
        }
    }

    private func loadAgentTranscript(_ agentID: String, in chatID: String) {
        openedAgents.removeAll { $0 == agentID }
        openedAgents.append(agentID)
        while openedAgents.count > Self.keptTranscripts {
            agentTranscripts[openedAgents.removeFirst()] = nil
        }
        guard agentTranscripts[agentID] == nil else { return }
        let data = agentsFolder(chatID).flatMap { try? Data(contentsOf: $0.appendingPathComponent("agents/\(agentID).jsonl")) } ?? Data()
        agentTranscripts[agentID] = Transcript.replay(data)
    }

    // MARK: The user's actions

    /// Stop Workflow: the `stop_task` control request for the workflow; the CLI stops it and its agents.
    public func stopWorkflow(_ id: String, in chatID: String) {
        guard let run = runs[chatID], let workflow = agents(of: chatID).workflows.first(where: { $0.id == id }), workflow.state == .running else { return }
        let requestID = run.controlID()
        run.stopRequests[requestID] = id
        run.stoppedTasks.insert(id)
        run.connection.write(ClaudeInput.control(requestID, ["subtype": "stop_task", "task_id": .string(id)]))
        expectAnswer(requestID, of: run)
    }

    /// The CLI's answer to Stop Workflow: an error leaves it running, with a line saying so.
    func stopAnswered(_ requestID: String, success: Bool, error: String?, run: ChatRun) -> Bool {
        guard let id = run.stopRequests.removeValue(forKey: requestID) else { return false }
        if !success {
            run.stoppedTasks.remove(id)
        }
        if !success, let workflow = agents(of: run.chatID).workflows.first(where: { $0.id == id }) {
            record(.system(SystemItem(created: now(), text: "The workflow “\(workflow.summary)” was not stopped: \(error ?? "no answer").",
                                      level: .warning)), in: run.chatID)
        }
        return true
    }

    /// Resume, on a sub-agent that failed or stopped: the internal skill `resume-agent`, with the agent's title and id.
    public func resumeAgent(_ agentID: String, in chatID: String) async throws(ChatError) {
        guard let agent = agents(of: chatID).agents.first(where: { $0.id == agentID }), agent.kind == .subagent,
              agent.state == .failed || agent.state == .stopped, let taskID = agent.taskID,
              let projectID = chats[chatID]?.projectID else { throw .invalid("This agent can't be resumed.") }
        _ = try await send("\(InternalSkill.resumeAgent.command) \(agent.title) (agent id \(taskID))", references: [], to: chatID, projectID: projectID,
                           origin: nil, title: nil, images: [], files: [], fromUser: false)
    }
}
