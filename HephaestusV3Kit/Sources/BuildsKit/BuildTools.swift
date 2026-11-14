import BuildData
import ExternalTools
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// The Builds operations the MCP server offers Claude (docs/mcp.md › Build tools): gh's runs, logs and releases
/// of a project's GitHub repository, read as the Builds window reads them.
public enum BuildTools {
    @MainActor
    public static func operations(projects: ProjectSession, runner: any ProcessRunning = SystemProcessRunner.shared) -> [ToolOperation] {
        let tools = BuildToolSet(projects: projects, runner: runner)
        return [tools.listRuns, tools.getRun, tools.getRunLog, tools.rerunRun, tools.cancelRun, tools.listReleases, tools.getRelease]
    }

    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")
    static let runID = ToolSchema.integer("The run's id on GitHub, as list_runs gives it.")

    /// How a chat shows a call of the tool `name` (docs/ui/chat.md › Tool-call rows).
    static func describe(_ name: String) -> @Sendable (JSONValue) -> ToolCallText {
        { arguments in text(name, arguments) }
    }

    nonisolated static func text(_ name: String, _ arguments: JSONValue) -> ToolCallText {
        let project = (arguments["projectID"]?.stringValue ?? "").uppercased()
        let run = arguments["runID"]?.intValue.map(String.init) ?? ""
        let tag = arguments["tag"]?.stringValue ?? ""
        let runItem = ToolItem(tool: "builds", projectID: project, focus: run, title: run)
        let list = ToolItem(tool: "builds", projectID: project, focus: "", title: project)
        switch name {
        case "list_runs": return ToolCallText(action: String(localized: "Listed the runs of \(project)", bundle: #bundle), item: list)
        case "get_run": return ToolCallText(action: String(localized: "Read a run of \(project)", bundle: #bundle), item: runItem)
        case "get_run_log": return ToolCallText(action: String(localized: "Read the log of a run of \(project)", bundle: #bundle), item: runItem)
        case "rerun_run":
            let failed = arguments["failedOnly"]?.boolValue == true
            return ToolCallText(action: failed ? String(localized: "Re-ran the failed jobs of a run of \(project)", bundle: #bundle)
                                               : String(localized: "Re-ran a run of \(project)", bundle: #bundle),
                                request: failed ? String(localized: "Claude wants to re-run the failed jobs of a run of \(project)", bundle: #bundle)
                                                : String(localized: "Claude wants to re-run a run of \(project)", bundle: #bundle),
                                item: runItem)
        case "cancel_run":
            return ToolCallText(action: String(localized: "Cancelled a run of \(project)", bundle: #bundle),
                                request: String(localized: "Claude wants to cancel a run of \(project)", bundle: #bundle), item: runItem)
        case "list_releases": return ToolCallText(action: String(localized: "Listed the releases of \(project)", bundle: #bundle), item: list)
        case "get_release":
            return ToolCallText(action: String(localized: "Read release \(tag)", bundle: #bundle),
                                item: ToolItem(tool: "builds", projectID: project, focus: BuildsFocus.release(tag).focus, title: tag))
        default: return ToolCallText(action: name)
        }
    }
}

@MainActor
private struct BuildToolSet {
    let projects: ProjectSession
    let runner: any ProcessRunning

    /// The gh calls of the project's repository.
    func builds(_ arguments: JSONValue) throws(ToolError) -> GitHubBuilds {
        let id = try arguments.string("projectID").uppercased()
        guard let project = projects.snapshot.project(id) else { throw ToolError(.notFound, "Project \(id) not found.") }
        guard let repository = project.resolved.githubPage.flatMap(GitHubRepository.init(page:)) else {
            throw ToolError(.unavailable, BuildError.noPage(id).description)
        }
        let tools = projects.tools
        return GitHubBuilds(cli: GitHubCLI(gh: tools.gh, environment: tools.environment, runner: runner), repository: repository)
    }

    func call<T>(_ work: () async throws(BuildError) -> T) async throws(ToolError) -> T {
        do {
            return try await work()
        } catch {
            switch error {
            case .unavailable(let message): throw ToolError(.unavailable, message)
            case .unexpected(let message), .storage(let message): throw ToolError(.internal, message)
            }
        }
    }

    func runID(_ arguments: JSONValue) throws(ToolError) -> Int {
        guard let id = arguments["runID"]?.intValue else { throw ToolError(.invalid, "runID: required.") }
        return id
    }

    var listRuns: ToolOperation {
        ToolOperation(
            name: "list_runs",
            description: "Returns the newest 50 workflow runs of the project's GitHub repository, of every branch and workflow, newest first: id, number, title, workflow, branch, commit, event, status, conclusion and dates. A sub project on its parent's settings has its parent's repository.",
            inputSchema: .object(properties: [("projectID", BuildTools.projectID)], required: ["projectID"]),
            permission: .read, describe: BuildTools.describe("list_runs")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            return .array(try await call { () throws(BuildError) in try await builds.runs() }.map { Self.json($0) })
        }
    }

    var getRun: ToolOperation {
        ToolOperation(
            name: "get_run",
            description: "Returns one workflow run with its jobs and their steps, each with its status, conclusion and dates.",
            inputSchema: .object(properties: [("projectID", BuildTools.projectID), ("runID", BuildTools.runID)], required: ["projectID", "runID"]),
            permission: .read, describe: BuildTools.describe("get_run")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            let id = try runID(arguments)
            return Self.json(try await call { () throws(BuildError) in try await builds.run(id) })
        }
    }

    var getRunLog: ToolOperation {
        ToolOperation(
            name: "get_run_log",
            description: "Returns the log of one job of a completed run, step by step; with step, that step's only. At most the last 2000 lines of each step. The log exists once the job has completed.",
            inputSchema: .object(properties: [
                ("projectID", BuildTools.projectID), ("runID", BuildTools.runID),
                ("job", .string("The job's name, as get_run gives it.")),
                ("step", .string("A step's name, as get_run gives it.")),
            ], required: ["projectID", "runID", "job"]),
            permission: .read, describe: BuildTools.describe("get_run_log")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            let id = try runID(arguments)
            let jobName = try arguments.string("job")
            let run = try await call { () throws(BuildError) in try await builds.run(id) }
            guard let job = run.jobs?.first(where: { $0.name == jobName }) else { throw ToolError(.notFound, "Job \(jobName) not found in run \(id).") }
            let logs = try await call { () throws(BuildError) in try await builds.log(job: job.id) }
            let step = arguments["step"]?.stringValue
            let steps = job.steps.filter { step == nil || $0.name == step }
            guard !steps.isEmpty else { throw ToolError(.notFound, "Step \(step ?? "") not found in job \(jobName).") }
            return .array(steps.map { step in
                let lines = logs[step.name] ?? []
                return ["step": .string(step.name), "lines": .array(lines.suffix(2000).map(JSONValue.string)),
                        "truncated": .bool(lines.count > 2000)]
            })
        }
    }

    var rerunRun: ToolOperation {
        ToolOperation(
            name: "rerun_run",
            description: "Runs every job of a completed workflow run again, or with failedOnly only its failed jobs.",
            inputSchema: .object(properties: [
                ("projectID", BuildTools.projectID), ("runID", BuildTools.runID),
                ("failedOnly", .boolean("Only the jobs that failed.")),
            ], required: ["projectID", "runID"]),
            permission: .startBuilds, describe: BuildTools.describe("rerun_run")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            let id = try runID(arguments)
            try await call { () throws(BuildError) in try await builds.rerun(id, failedOnly: arguments["failedOnly"]?.boolValue == true) }
            return ["rerun": .int(id)]
        }
    }

    var cancelRun: ToolOperation {
        ToolOperation(
            name: "cancel_run",
            description: "Cancels a queued or running workflow run.",
            inputSchema: .object(properties: [("projectID", BuildTools.projectID), ("runID", BuildTools.runID)], required: ["projectID", "runID"]),
            permission: .startBuilds, describe: BuildTools.describe("cancel_run")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            let id = try runID(arguments)
            try await call { () throws(BuildError) in try await builds.cancel(id) }
            return ["cancelled": .int(id)]
        }
    }

    var listReleases: ToolOperation {
        ToolOperation(
            name: "list_releases",
            description: "Returns the newest 50 published releases of the project's GitHub repository, newest first: tag, name, whether it is the latest or a pre-release, dates and the names and sizes of its files, without notes.",
            inputSchema: .object(properties: [("projectID", BuildTools.projectID)], required: ["projectID"]),
            permission: .read, describe: BuildTools.describe("list_releases")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            return .array(try await call { () throws(BuildError) in try await builds.releases() }.map { Self.json($0, notes: false) })
        }
    }

    var getRelease: ToolOperation {
        ToolOperation(
            name: "get_release",
            description: "Returns one published release with its notes and its files.",
            inputSchema: .object(properties: [("projectID", BuildTools.projectID), ("tag", .string("The release's tag, such as v1.4.0."))],
                                 required: ["projectID", "tag"]),
            permission: .read, describe: BuildTools.describe("get_release")
        ) { @MainActor arguments throws(ToolError) in
            let builds = try builds(arguments)
            let tag = try arguments.string("tag")
            guard let release = try await call({ () throws(BuildError) in try await builds.releases() }).first(where: { $0.tag == tag }) else {
                throw ToolError(.notFound, "Release \(tag) not found.")
            }
            return Self.json(release, notes: true)
        }
    }

    // MARK: JSON

    static func date(_ date: Date?) -> JSONValue {
        date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
    }

    static func json(_ run: GitHubRun) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .int(run.id), "number": .int(run.number), "title": .string(run.title), "workflow": .string(run.workflow),
            "branch": .string(run.branch), "commit": .string(run.commit), "event": .string(run.event), "status": .string(run.status),
            "conclusion": run.conclusion.map(JSONValue.string) ?? .null, "created": date(run.createdAt), "started": date(run.startedAt),
            "updated": date(run.updatedAt),
        ]
        if let jobs = run.jobs {
            object["jobs"] = .array(jobs.map { job in
                ["name": .string(job.name), "status": .string(job.status), "conclusion": job.conclusion.map(JSONValue.string) ?? .null,
                 "started": date(job.startedAt), "completed": date(job.completedAt),
                 "steps": .array(job.steps.map { step in
                     ["number": .int(step.number), "name": .string(step.name), "status": .string(step.status),
                      "conclusion": step.conclusion.map(JSONValue.string) ?? .null, "started": date(step.startedAt), "completed": date(step.completedAt)]
                 })]
            })
        }
        return .object(object).removingNullMembers
    }

    static func json(_ release: GitHubRelease, notes: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "tag": .string(release.tag), "name": .string(release.name), "latest": .bool(release.isLatest),
            "prerelease": .bool(release.isPrerelease), "created": date(release.createdAt), "published": date(release.publishedAt),
            "assets": .array(release.assets.map { ["name": .string($0.name), "size": .int($0.size)] }),
        ]
        if notes { object["notes"] = .string(release.body) }
        return .object(object).removingNullMembers
    }
}
