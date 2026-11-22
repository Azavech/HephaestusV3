import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Agents, on V2's captures.
@Suite("Agents and workflows")
@MainActor
struct ChatAgentsTests {
    @Test("A workflow: its record, its run's folder read for its agents and their transcripts, its end; the agents file read back")
    func workflow() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        // The run's folder, named after its run id, as the CLI writes it.
        let folder = world.root.appendingPathComponent("runs/wf_0afd7514-9e5")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try #require(Bundle.module.url(forResource: "stream-workflow-folder", withExtension: nil, subdirectory: "Fixtures")), to: folder)
        let id = try await world.session.send("Run the probe workflow", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let capture = "/Users/example/.claude/projects/-tmp-example/1EADA864-B5CE-4D35-9071-C2FBF075F979/subagents/workflows/wf_0afd7514-9e5"
        let lines = try Fixture.lines("stream-workflow.jsonl").map { Data(String(decoding: $0, as: UTF8.self).replacing(capture, with: folder.path).utf8) }
        cli.feed(Array(lines[0..<30]))
        try await world.until { world.session.agents(of: id).workflows.first?.runID == "wf_0afd7514-9e5" }
        let workflow = try #require(world.session.agents(of: id).workflows.first)
        #expect(workflow.id == "wflx39ys6" && workflow.name == "probe" && workflow.summary == "Two probe agents" && workflow.state == .running)
        try await world.until { world.session.agents(of: id).agents.count == 2 }
        cli.feed(Array(lines[30...]))
        try await world.until { world.session.agents(of: id).workflows.first?.state == .completed }
        let agents = world.session.agents(of: id).agents
        #expect(agents.map(\.id) == ["abd107d9822b6600d", "afa76c5ae2246d66b"] && agents.map(\.title) == ["probe-a", "probe-b"])
        #expect(agents.allSatisfy { $0.kind == .workflow && $0.workflowID == "wflx39ys6" && $0.phase == "Probe" && $0.state == .completed })
        #expect(world.session.agentTranscripts.isEmpty, "No agent's items stay in memory until its view opens")
        await world.session.openAgent("abd107d9822b6600d", in: id)
        let transcript = world.session.agentTranscript("abd107d9822b6600d", in: id)
        #expect(transcript.contains { if case .toolUse(let use) = $0 { use.name == "Bash" } else { false } })
        #expect(transcript.contains { if case .assistant(let text) = $0 { text.text == "ok" } else { false } })
        let stored = world.repo.appendingPathComponent(".hephaestus/chats/\(id)")
        let read = ChatAgents.read(try Data(contentsOf: stored.appendingPathComponent("agents.jsonl")))
        #expect(read.workflows.map(\.state) == [.completed] && read.agents.map(\.state) == [.completed, .completed])
        #expect(FileManager.default.fileExists(atPath: stored.appendingPathComponent("agents/abd107d9822b6600d.jsonl").path))
        cli.finish(.exited(0))
    }

    @Test("A sub-agent in the background: its record, its id from task_started, its transcript of the chat's items, its end")
    func backgroundAgent() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Start an agent", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let lines = try Fixture.lines("stream-background-agent.jsonl")
        cli.feed(Array(lines[0..<33]))
        try await world.until { world.session.state(of: id) == .idle }
        var agent = try #require(world.session.agents(of: id).agents.first)
        #expect(agent.id == "toolu_01P13PE4h122VQc4ctmUmWLB" && agent.kind == .subagent && agent.title == "Sleep 15 seconds")
        #expect(agent.taskID == "a20896a2a89380e93" && agent.state == .running, "A background agent goes on after the turn")
        cli.feed(Array(lines[33...]))
        try await world.until { world.session.agents(of: id).agents.first?.state == .completed }
        agent = try #require(world.session.agents(of: id).agents.first)
        #expect(agent.ended != nil)
        let transcript = world.session.agentTranscript(agent.id, in: id)
        guard case .user(let prompt)? = transcript.first else { Issue.record("No prompt"); return }
        #expect(prompt.id == "\(agent.id)#prompt" && prompt.sender == "Claude" && !prompt.text.isEmpty)
        #expect(transcript.contains { if case .toolUse(let use) = $0 { use.name == "Bash" } else { false } })
        #expect(transcript.contains { if case .toolResult(let result) = $0 { result.toolUseID == "toolu_015RLF2zoV76K9UNqrMgjxjE" } else { false } })
        cli.finish(.exited(0))
    }

    @Test("Stop Workflow writes stop_task; the CLI's kill stops the workflow and its agents")
    func stop() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let lines = try Fixture.lines("stream-workflow-stop.jsonl")
        cli.feed(Array(lines[0..<44]))
        try await world.until { world.session.agents(of: id).workflows.first?.state == .running }
        let workflow = try #require(world.session.agents(of: id).workflows.first)
        world.session.stopWorkflow(workflow.id, in: id)
        let request = try #require(cli.written.last)
        #expect(request["request"]?["subtype"] == "stop_task" && request["request"]?["task_id"]?.stringValue == workflow.id)
        cli.feed(Array(lines[44...]))
        try await world.until { world.session.agents(of: id).workflows.first?.state == .stopped }
        #expect(world.session.agents(of: id).agents.allSatisfy { $0.state != .running })
        #expect(!world.items(id).contains { if case .system(let line) = $0 { line.text.contains("was not stopped") } else { false } })
        // The CLI owes no turn for a workflow Stop Workflow stopped: the chat's background work ends with its tasks.
        try await world.until { world.session.state(of: id) == .idle && !world.session.backgroundWork.contains(id) }
        cli.finish(.exited(0))
    }

    @Test("A sub-agent Claude resumes runs in the background: its turn's result doesn't stop it, its notification ends it")
    func resumedAgent() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Resume it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        let lines = try Fixture.lines("stream-background-agent-resume.jsonl")
        let task = "a4f36739c9911397a"
        cli.feed(Array(lines[0..<111]))
        try await world.until { world.session.agents(of: id).agents.contains { $0.taskID == task && $0.state != .running } }
        // As read back from the agents file after a relaunch: not marked as in the background.
        var agent = try #require(world.session.agents(of: id).agents.first { $0.taskID == task })
        agent.inBackground = false
        world.session.put(agent, in: id)
        cli.feed(Array(lines[111..<122]))
        try await world.until { world.session.agents(of: id).agents.first { $0.taskID == task }?.state == .running }
        try await world.until { world.session.state(of: id) == .idle }
        #expect(world.session.agents(of: id).agents.first { $0.taskID == task }?.state == .running, "The result doesn't stop it")
        cli.feed(Array(lines[122...]))
        try await world.until { world.session.agents(of: id).agents.first { $0.taskID == task }?.state == .completed }
        cli.finish(.exited(0))
    }

    @Test("A sub-agent's id is the last well-formed agentId line of its call's result")
    func agentIDs() {
        #expect(ChatSession.agentID(inResult: "Async agent launched.\nagentId: a20896a2a89380e93 (internal ID - x)\nmore") == "a20896a2a89380e93")
        #expect(ChatSession.agentID(inResult: "agentId: bad/id") == nil)
        #expect(ChatSession.agentID(inResult: "no id") == nil)
    }
}
