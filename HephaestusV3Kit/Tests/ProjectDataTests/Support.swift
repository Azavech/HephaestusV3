import ExternalTools
import FileStorage
import Foundation
import Synchronization
import Testing
@testable import ProjectData

/// A fixture of the test bundle.
func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Runs `body` with a new empty folder in the system's temporary folder, deleted afterwards. Tests never
/// touch the user's projects or data folders.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectDataTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder.resolvingSymlinksInPath())
}

/// Writes a project file with `id` in `folder`.
func makeProject(_ id: String, in folder: URL) throws {
    let file = folder.appendingPathComponent(".hephaestus/project.yml")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema: 1\nid: \(id)\nname: \(id)\ncreated: 2026-10-31T09:30:00Z\n".utf8).write(to: file)
}


/// Answers runs from a script, without starting any process: `git config --get remote.origin.url` with
/// `origins[folder]`, `ssh -G <alias>` with `hostNames[alias]`, the shell capture with `environment`, and
/// every other run with success.
final class FakeRunner: ProcessRunning {
    private let state: Mutex<(origins: [String: String], hostNames: [String: String], requests: [ProcessRequest])>
    let environment: String

    init(origins: [String: String] = [:], hostNames: [String: String] = [:], environment: String = "PATH=/usr/bin\0") {
        state = Mutex((origins, hostNames, []))
        self.environment = environment
    }

    func setOrigin(_ url: String?, for folder: String) {
        state.withLock { $0.origins[folder] = url }
    }

    var requests: [ProcessRequest] { state.withLock { $0.requests } }

    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        let answer: String? = state.withLock { state in
            state.requests.append(request)
            switch request.arguments.first {
            case "config": return state.origins[request.currentDirectory ?? ""]
            case "-G": return state.hostNames[request.arguments[1]].map { "user git\nhostname \($0)\n" }
            case "-lic": return environment
            default: return ""
            }
        }
        guard let answer else { return ProcessResult(termination: .exited(1)) }
        return ProcessResult(termination: .exited(0), standardOutput: Data(answer.utf8))
    }
}

/// A temporary world: a data folder and project folders, deleted afterwards.
struct World {
    let root: URL
    let data: DataFolder

    init(_ root: URL) {
        self.root = root
        data = DataFolder(url: root.appendingPathComponent("Data", isDirectory: true))
        try? data.createIfNeeded()
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    /// Writes a project file at `relative`, with the given extra YAML lines.
    @discardableResult
    func project(_ relative: String, id: String, name: String? = nil, extra: String = "") throws -> String {
        let folder = root.appendingPathComponent(relative, isDirectory: true)
        let file = folder.appendingPathComponent(".hephaestus/project.yml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("schema: 1\nid: \(id)\nname: \(name ?? id)\ncreated: 2026-10-31T09:30:00Z\n\(extra)".utf8).write(to: file)
        return folder.path
    }

    func register(_ paths: String...) throws {
        try YAMLFile.write(RegistryFile(projects: paths), to: data.registryFile)
    }

    func library(_ runner: FakeRunner = FakeRunner(), tools: Tools? = nil) async -> ProjectLibrary {
        let library = ProjectLibrary(dataFolder: data, runner: runner, now: { ISODate.date(from: "2026-11-13T10:00:00Z")! })
        if let tools { await library.setTools(tools) }
        return library
    }

    func readProject(_ folder: String) throws -> ProjectFile {
        try YAMLFile.read(ProjectFile.self, at: URL(fileURLWithPath: folder).appendingPathComponent(".hephaestus/project.yml"))
    }
}

/// The environments of a Go service, as YAML lines.
func environmentsYAML(_ entries: [(name: String, url: String?)]) -> String {
    "type: goService\nenvironments:\n" + entries.map { entry in
        "- name: \(entry.name)\n" + (entry.url.map { "  url: \($0)\n" } ?? "")
    }.joined()
}
