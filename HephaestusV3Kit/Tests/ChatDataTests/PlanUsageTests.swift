import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
@testable import ChatData

/// docs/data.md › Stream mapping and Plan usage file: the weekly usage the CLI reports, its file, and the session
/// that keeps it.
@Suite("Plan usage")
struct PlanUsageTests {
    private let week = "2026-11-08T20:00:00Z"

    private func map(_ line: String) -> [StreamOutput] {
        var mapper = StreamMapper()
        return mapper.map(Data(line.utf8))
    }

    private func reports(_ fixture: String) throws -> [PlanUsage] {
        var mapper = StreamMapper()
        return try Fixture.lines(fixture).flatMap { mapper.map($0) }.compactMap { if case .planUsage(let usage) = $0 { usage } else { nil } }
    }

    private func date(_ text: String) -> Date {
        ISODate.date(from: text)!
    }

    @Test("The captures' rate_limit_event lines give the weekly window, the status and the overage")
    func captures() throws {
        #expect(try reports("stream-bash-allowed.jsonl") == [
            PlanUsage(utilization: 0.68, resetsAt: date("2026-11-01T20:00:00Z"), status: "allowed", overageStatus: "rejected",
                      overageDisabledReason: "out_of_credits", isUsingOverage: false),
        ])
        #expect(try reports("stream-compact.jsonl") == [
            PlanUsage(utilization: 0.97, resetsAt: date(week), status: "allowed_warning", overageStatus: "allowed", isUsingOverage: false),
        ], "The top-level utilization and the overage's reset aren't read")
    }

    @Test("Without the weekly window's numbers or a status of one line, the line is ignored; an odd optional value is absent")
    func lines() {
        func line(_ info: String) -> String { #"{"type":"rate_limit_event","rate_limit_info":\#(info)}"# }
        let window = #""unifiedWindows":{"seven_day":{"utilization":0.5,"resetsAt":1794168000}}"#
        for info in [
            #"{"status":"allowed"}"#,
            #"{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":1794168000}}}"#,
            #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":-0.1,"resetsAt":1794168000}}}"#,
            #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":"0.5","resetsAt":1794168000}}}"#,
            #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.5,"resetsAt":"soon"}}}"#,
            #"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.5}}}"#,
            "{\(window)}",
            #"{"status":"","# + window + "}",
            #"{"status":"allowed\nnow","# + window + "}",
            #"{"status":7,"# + window + "}",
        ] {
            #expect(map(line(info)) == [.ignored("rate_limit_event")], "\(info)")
        }
        #expect(map(#"{"type":"rate_limit_event"}"#) == [.ignored("rate_limit_event")])
        #expect(map(line(#"{"status":"rejected","overageStatus":"","overageDisabledReason":3,"isUsingOverage":"yes","# + window + "}"))
            == [.planUsage(PlanUsage(utilization: 0.5, resetsAt: date(week), status: "rejected"))])
        #expect(map(line(#"{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":1,"resetsAt":1794168000.7}}}"#))
            == [.planUsage(PlanUsage(utilization: 1, resetsAt: date(week), status: "allowed"))], "An integer, and whole seconds")
    }

    @Test("The file: the example written back byte for byte, unknown keys kept, absent values written null")
    func file() throws {
        let example = """
            schema: 1
            utilization: 0.68
            resetsAt: 2026-11-22T20:00:00Z
            status: allowed
            overageStatus: rejected
            overageDisabledReason: out_of_credits
            isUsingOverage: false

            """
        let usage = try YAMLFile.decode(PlanUsage.self, from: Data(example.utf8), path: "plan-usage.yml")
        #expect(usage == PlanUsage(utilization: 0.68, resetsAt: date("2026-11-22T20:00:00Z"), status: "allowed", overageStatus: "rejected",
                                   overageDisabledReason: "out_of_credits", isUsingOverage: false))
        let written = try YAMLCoding.encode(usage)
        #expect(written == example)
        let kept = try YAMLFile.decode(PlanUsage.self, from: Data((example + "window: seven_day\n").utf8), path: "plan-usage.yml")
        #expect(kept.unknownKeys.count == 1 && kept.reports(sameAs: usage) && kept != usage)
        #expect(try YAMLCoding.encode(kept) == example + "window: seven_day\n")
        let short = try YAMLFile.decode(PlanUsage.self, from: Data("utilization: 1.04\nresetsAt: \(week)\nstatus: rejected\n".utf8), path: "plan-usage.yml")
        #expect(try YAMLCoding.encode(short) == """
            schema: 1
            utilization: 1.04
            resetsAt: \(week)
            status: rejected
            overageStatus: null
            overageDisabledReason: null
            isUsingOverage: null

            """)
        for utilization in [0, 1, 0.00001, 0.123456789, 2.5] {
            let value = PlanUsage(utilization: utilization, resetsAt: date(week), status: "allowed")
            let text = try YAMLCoding.encode(value)
            #expect(try YAMLFile.decode(PlanUsage.self, from: Data(text.utf8), path: "plan-usage.yml") == value, "\(text)")
        }
    }

    @Test("A file that breaks a read rule is invalid")
    func invalidFiles() {
        for text in [
            "resetsAt: \(week)\nstatus: allowed\n",
            "utilization: -0.5\nresetsAt: \(week)\nstatus: allowed\n",
            "utilization: 0.5\nstatus: allowed\n",
            "utilization: 0.5\nresetsAt: next week\nstatus: allowed\n",
            "utilization: 0.5\nresetsAt: \(week)\n",
            "utilization: 0.5\nresetsAt: \(week)\nstatus: ''\n",
            "utilization: 0.5\nresetsAt: \(week)\nstatus: \"allowed\\nnow\"\n",
            "utilization: 0.5\nresetsAt: \(week)\nstatus: allowed\noverageDisabledReason: ''\n",
            "schema: 2\nutilization: 0.5\nresetsAt: \(week)\nstatus: allowed\n",
        ] {
            #expect(throws: StorageError.self, "\(text)") { try YAMLFile.decode(PlanUsage.self, from: Data(text.utf8), path: "plan-usage.yml") }
        }
    }

    @Test("Hidden from the reset time on")
    func expiry() {
        let usage = PlanUsage(utilization: 0.5, resetsAt: date(week), status: "allowed")
        #expect(!usage.hasExpired(at: date(week).addingTimeInterval(-1)))
        #expect(usage.hasExpired(at: date(week)))
    }
}

@Suite("Plan usage in a session")
@MainActor
struct PlanUsageSessionTests {
    private func line(_ utilization: Double) -> Data {
        Data(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":\#(utilization),"resetsAt":1794168000}}}}"#.utf8)
    }

    @Test("A chat's report replaces the kept value and writes the file; the same report writes nothing")
    func reports() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let file = world.root.appendingPathComponent("Data/plan-usage.yml")
        #expect(world.session.planUsage == nil && !FileManager.default.fileExists(atPath: file.path))

        let id = try await world.session.send("Run it", references: [], to: nil, projectID: "ORD")
        let cli = try #require(world.launcher.chats.first)
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl"))
        try await world.until { world.session.state(of: id) == .idle && world.session.planUsage != nil }
        #expect(world.session.planUsage?.utilization == 0.68 && world.session.planUsage?.overageDisabledReason == "out_of_credits")
        #expect(try YAMLFile.read(PlanUsage.self, at: file) == world.session.planUsage)

        try FileManager.default.removeItem(at: file)
        cli.feed(try Fixture.lines("stream-bash-allowed.jsonl").filter { String(decoding: $0, as: UTF8.self).contains("rate_limit_event") }
            + [Data(#"{"type":"system","subtype":"status","status":"compacting"}"#.utf8)])
        try await world.until { world.session.compacting.contains(id) }
        #expect(!FileManager.default.fileExists(atPath: file.path), "The same report writes nothing")

        cli.feed([line(0.71)])
        try await world.until { world.session.planUsage?.utilization == 0.71 }
        let written = try YAMLFile.read(PlanUsage.self, at: file)
        #expect(written.utilization == 0.71 && written.resetsAt == ISODate.date(from: "2026-11-08T20:00:00Z") && written.overageStatus == nil)
        cli.finish(.exited(0))
    }

    @Test("A session reads the file, keeps its unknown keys when it writes, and sets an invalid one aside")
    func file() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let data = try #require(world.projects.dataFolder)
        try Data("schema: 1\nutilization: 0.4\nresetsAt: 2026-11-08T20:00:00Z\nstatus: allowed\nnote: kept\n".utf8).write(to: data.planUsageFile)
        let session = ChatSession(projects: world.projects, tokens: MCPTokens(), launcher: FakeLauncher(), runner: ChatRunner(), device: "Studio",
                                  processEnvironment: [:])
        await session.start(tools: [], port: 47999)
        #expect(session.planUsage?.utilization == 0.4 && session.planUsage?.unknownKeys.count == 1)

        let report = try #require(PlanUsage.report(try JSONValue.parse(line(0.45))["rate_limit_info"]))
        session.receive(planUsage: report)
        #expect(session.planUsage?.utilization == 0.45)
        let text = try String(contentsOf: data.planUsageFile, encoding: .utf8)
        #expect(text.contains("utilization: 0.45\n") && text.hasSuffix("isUsingOverage: null\nnote: kept\n"))

        try Data("utilization: -1\nresetsAt: 2026-11-08T20:00:00Z\nstatus: allowed\n".utf8).write(to: data.planUsageFile)
        let other = ChatSession(projects: world.projects, tokens: MCPTokens(), launcher: FakeLauncher(), runner: ChatRunner(), device: "Studio",
                                processEnvironment: [:])
        await other.start(tools: [], port: 47999)
        #expect(other.planUsage == nil)
        #expect(!FileManager.default.fileExists(atPath: data.planUsageFile.path))
        #expect(FileManager.default.fileExists(atPath: data.invalidCopy(of: data.planUsageFile).path))
    }
}
