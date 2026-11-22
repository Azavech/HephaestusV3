import CoreServices
import ExternalTools
import Foundation

/// A workflow run as gh gives it.
public struct GitHubRun: Sendable, Hashable, Identifiable, Decodable {
    /// GitHub's id of the run (`databaseId`): what the app and routes name it by.
    public let id: Int
    /// Its number in its workflow, as GitHub shows it: `#641`.
    public let number: Int
    public let title: String
    public let workflow: String
    public let branch: String
    public let commit: String
    public let event: String
    public let status: String
    public let conclusion: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let updatedAt: Date?
    /// Only with the run's details.
    public let jobs: [GitHubJob]?

    enum CodingKeys: String, CodingKey {
        case id = "databaseId", number, title = "displayTitle", workflow = "workflowName", branch = "headBranch", commit = "headSha", event
        case status, conclusion, createdAt, startedAt, updatedAt, jobs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        workflow = try c.decodeIfPresent(String.self, forKey: .workflow) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        commit = try c.decodeIfPresent(String.self, forKey: .commit) ?? ""
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        conclusion = (try c.decodeIfPresent(String.self, forKey: .conclusion)).flatMap { $0.isEmpty ? nil : $0 }
        createdAt = try GitHubDates.decode(c, .createdAt)
        startedAt = try GitHubDates.decode(c, .startedAt)
        updatedAt = try GitHubDates.decode(c, .updatedAt)
        jobs = try c.decodeIfPresent([GitHubJob].self, forKey: .jobs)
    }

    /// When it started: `startedAt`, else its creation.
    public var start: Date? { startedAt ?? createdAt }
    /// How long it ran, in seconds: to its last update once completed, else to `now`.
    public func duration(now: Date = Date()) -> Int {
        guard let start else { return 0 }
        let end = status == "completed" ? (updatedAt ?? now) : now
        return max(0, Int(end.timeIntervalSince(start)))
    }
}

/// A job of a run.
public struct GitHubJob: Sendable, Hashable, Decodable {
    public let id: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let steps: [GitHubStep]

    enum CodingKeys: String, CodingKey {
        case id = "databaseId", name, status, conclusion, startedAt, completedAt, steps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        conclusion = (try c.decodeIfPresent(String.self, forKey: .conclusion)).flatMap { $0.isEmpty ? nil : $0 }
        startedAt = try GitHubDates.decode(c, .startedAt)
        completedAt = try GitHubDates.decode(c, .completedAt)
        steps = try c.decodeIfPresent([GitHubStep].self, forKey: .steps) ?? []
    }
}

/// A step of a job.
public struct GitHubStep: Sendable, Hashable, Decodable {
    public let number: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey { case number, name, status, conclusion, startedAt, completedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        conclusion = (try c.decodeIfPresent(String.self, forKey: .conclusion)).flatMap { $0.isEmpty ? nil : $0 }
        startedAt = try GitHubDates.decode(c, .startedAt)
        completedAt = try GitHubDates.decode(c, .completedAt)
    }
}

/// A job's or a step's length in seconds: from its start to its end, or to `now` while it runs; nil before it
/// starts.
public func gitHubDuration(start: Date?, end: Date?, now: Date = Date()) -> Int? {
    guard let start else { return nil }
    return max(0, Int((end ?? now).timeIntervalSince(start)))
}

/// A published release, from GitHub's REST API (`gh api`), with its notes and assets.
public struct GitHubRelease: Sendable, Hashable, Identifiable, Decodable {
    public let tag: String
    public let name: String
    public let body: String
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let createdAt: Date?
    public let publishedAt: Date?
    public let assets: [GitHubAsset]
    /// Set from `gh release list`, which knows the repository's latest release.
    public var isLatest = false

    public var id: String { tag }

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, body, isDraft = "draft", isPrerelease = "prerelease", createdAt = "created_at"
        case publishedAt = "published_at", assets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        isPrerelease = try c.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        createdAt = try GitHubDates.decode(c, .createdAt)
        publishedAt = try GitHubDates.decode(c, .publishedAt)
        assets = try c.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }
}

public struct GitHubAsset: Sendable, Hashable, Decodable {
    public let name: String
    public let size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// The lines of a job's log, by step name, from `gh run view --log`: each line is `<job>\t<step>\t<time> <text>`.
/// gh prints the steps in order, each one's lines together, so a name has one segment of lines per step of that
/// name: two steps both called `Run actions/cache@v4` keep their own lines.
public enum StepLogs {
    /// The step name gh prints for every line of a job whose log archive has no file per step: the job's whole log.
    public static let unknownStep = "UNKNOWN STEP"

    /// The lines of the step called `step`, the `occurrence`-th of its name in its job (from 0): its own, else the
    /// job's whole log when gh printed it as `unknownStep`.
    public static func lines(of step: String, occurrence: Int = 0, in steps: [String: [[String]]]) -> [String] {
        if let segments = steps[step] {
            return segments.indices.contains(occurrence) ? segments[occurrence] : []
        }
        return steps[unknownStep]?.flatMap { $0 } ?? []
    }

    public static func parse(_ output: Data) -> [String: [[String]]] {
        var steps: [String: [[String]]] = [:]
        var previous: Substring?
        // CR LF is one character in Swift: lines split on any line break.
        for raw in String(decoding: output, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            var text = Substring(fields[2])
            // The time GitHub writes first: `2026-11-07T21:27:01.1234567Z `.
            if let space = text.firstIndex(of: " "), text[..<space].hasSuffix("Z"), text.first?.isNumber == true {
                text = text[text.index(after: space)...]
            }
            let name = fields[1]
            if name != previous {
                steps[String(name), default: []].append([])
                previous = name
            }
            steps[String(name)]![steps[String(name)]!.count - 1].append(String(text))
        }
        return steps
    }
}

/// gh's dates: ISO 8601 with or without fractions; `0001-01-01T00:00:00Z`, GitHub's time not set, is none.
enum GitHubDates {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key), !text.hasPrefix("0001-01-01") else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// The gh calls of Builds (docs/data.md › Builds › gh calls).
public struct GitHubBuilds: Sendable {
    public let cli: GitHubCLI
    public let repository: GitHubRepository

    public init(cli: GitHubCLI, repository: GitHubRepository) {
        self.cli = cli
        self.repository = repository
    }

    static let runFields = "conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,number,startedAt,status,updatedAt,workflowName"

    /// The newest 50 runs, of every branch and workflow, newest first.
    public func runs() async throws(BuildError) -> [GitHubRun] {
        try decode("run list", [GitHubRun].self, await cli.run("run list", ["run", "list", "--repo=\(repository.repoArgument)", "--limit=50",
                                                                             "--json=\(Self.runFields)"]))
    }

    /// One run with its jobs and their steps.
    public func run(_ id: Int) async throws(BuildError) -> GitHubRun {
        try decode("run view", GitHubRun.self, await cli.run("run view", ["run", "view", "--repo=\(repository.repoArgument)",
                                                                           "--json=\(Self.runFields),jobs", "--", String(id)]))
    }

    /// A job's log, by step name. gh gives it once the job has completed.
    public func log(job: Int) async throws(BuildError) -> [String: [[String]]] {
        StepLogs.parse(try await cli.run("run view", ["run", "view", "--repo=\(repository.repoArgument)", "--log", "--job=\(job)"],
                                         timeout: .seconds(60)))
    }

    /// Runs every job of a completed run again, or only its failed jobs.
    public func rerun(_ id: Int, failedOnly: Bool) async throws(BuildError) {
        _ = try await cli.run("run rerun", ["run", "rerun", "--repo=\(repository.repoArgument)"] + (failedOnly ? ["--failed"] : []) + ["--", String(id)])
    }

    /// Cancels a queued or running run.
    public func cancel(_ id: Int) async throws(BuildError) {
        _ = try await cli.run("run cancel", ["run", "cancel", "--repo=\(repository.repoArgument)", "--", String(id)])
    }

    /// The newest 50 published releases with their notes and assets, newest first; the latest marked.
    public func releases() async throws(BuildError) -> [GitHubRelease] {
        let all = try decode("api", [GitHubRelease].self, await cli.run("api", ["api", "repos/\(repository.owner)/\(repository.name)/releases?per_page=50"]))
        struct Listed: Decodable { let tagName: String; let isLatest: Bool }
        let listed = try decode("release list", [Listed].self, await cli.run("release list", [
            "release", "list", "--repo=\(repository.repoArgument)", "--limit=50", "--exclude-drafts", "--json=tagName,isLatest",
        ]))
        let latest = listed.first { $0.isLatest }?.tagName
        return all.filter { !$0.isDraft }.map { release in
            var marked = release
            marked.isLatest = release.tag == latest
            return marked
        }
    }

    /// Saves an asset in `downloads` under a free name, with the quarantine of a web download, and returns
    /// its file. gh downloads it into a folder of `temporary` first, removed afterwards.
    public func download(asset: String, tag: String, into downloads: URL, temporary: URL) async throws(BuildError) -> URL {
        let folder = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .storage("Download failed: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await cli.run("release download", ["release", "download", "--repo=\(repository.repoArgument)",
                                                   "--pattern=\(Self.pattern(forAsset: asset))", "--dir=\(folder.path)", "--", tag],
                              timeout: .seconds(30 * 60))
        let expected = folder.appendingPathComponent(asset)
        guard FileManager.default.fileExists(atPath: expected.path) else { throw .unexpected("gh release download saved no file.") }
        let destination: URL
        do {
            destination = try Self.move(expected, named: asset, into: downloads)
        } catch {
            throw .storage("Download failed: \(error.localizedDescription)")
        }
        quarantine(destination, tag: tag, asset: asset)
        return destination
    }

    /// The asset's name with `\` before each `\`, `*`, `?` and `[`, so that gh's pattern matches it only.
    public static func pattern(forAsset name: String) -> String {
        var pattern = ""
        for character in name {
            if "\\*?[".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        return pattern
    }

    /// Moves the file into `folder` with its name made safe (`/` and `:` replaced by `_`), adding ` (1)`, ` (2)`…
    /// before the extension when the name is taken.
    static func move(_ file: URL, named name: String, into folder: URL) throws -> URL {
        let safe = name.replacing("/", with: "_").replacing(":", with: "_").trimmingCharacters(in: .whitespaces)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var index = 0
        while true {
            let candidate = index == 0 ? safe : (ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            let destination = folder.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                index += 1
            }
        }
    }

    /// The quarantine of a web download, with the asset's URL and the release's page, so that Gatekeeper checks
    /// the file when it opens.
    func quarantine(_ file: URL, tag: String, asset: String) {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        func encoded(_ part: String) -> String { part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part }
        let releases = "https://github.com/\(repository.owner)/\(repository.name)/releases"
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        properties[kLSQuarantineDataURLKey as String] = URL(string: "\(releases)/download/\(encoded(tag))/\(encoded(asset))")
        properties[kLSQuarantineOriginURLKey as String] = URL(string: "\(releases)/tag/\(encoded(tag))")
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = file
        try? url.setResourceValues(values)
    }

    private func decode<T: Decodable>(_ command: String, _ type: T.Type, _ data: Data) throws(BuildError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .unexpected("gh \(command) returned unexpected output: \(error).")
        }
    }
}
