import Foundation

/// Where Claude's memories are (docs/data.md › Memories), as V2 found them: the memory folder the Claude CLI uses for a
/// project, one per repository, and the global memories folder every chat gets. The CLI's own rules, checked by V2 with
/// Claude Code 2.1.309.
public struct MemoryLocations: Sendable {
    /// The home folder.
    public var home: String
    /// The chats' environment: `CLAUDE_CONFIG_DIR` moves the CLI's configuration folder.
    public var environment: [String: String]
    /// The folder of the managed settings, `/Library/Application Support/ClaudeCode`; tests give another.
    public var managedFolder: String

    public init(home: String = NSHomeDirectory(), environment: [String: String],
                managedFolder: String = "/Library/Application Support/ClaudeCode") {
        self.home = home
        self.environment = environment
        self.managedFolder = managedFolder
    }

    /// The CLI's configuration folder: `CLAUDE_CONFIG_DIR` when set and not empty, a relative one under the home
    /// folder; otherwise `~/.claude`.
    public var configFolder: String {
        if let value = environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            return value.hasPrefix("/") ? value : (home as NSString).appendingPathComponent(value)
        }
        return (home as NSString).appendingPathComponent(".claude")
    }

    /// The global memories folder: `<config folder>/memory`. `autoMemoryDirectory` doesn't move it.
    public var globalFolder: String {
        (configFolder as NSString).appendingPathComponent("memory")
    }

    /// The memory folder of a project whose root is `root`: the `autoMemoryDirectory` setting's folder, else
    /// `<config folder>/projects/<folder name>/memory`.
    public func projectFolder(root: String) -> String {
        let start = Self.startPath(root)
        let repository = Self.repositoryRoot(from: start)
        let base = repository.map(Self.base(ofRepository:)) ?? start
        switch autoMemoryDirectory(root: root, mainTree: repository.map(Self.base(ofRepository:))) {
        case .folder(let folder): return folder
        case .refused, .none: break
        }
        return ((configFolder as NSString).appendingPathComponent("projects") as NSString)
            .appendingPathComponent(Self.folderName(base) + "/memory")
    }

    // MARK: Steps

    /// Step 1: the root with its symbolic links resolved, in Unicode normalization form C.
    static func startPath(_ root: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let resolved = realpath(root, &buffer).map { _ in String(cString: buffer) } ?? root
        return resolved.precomposedStringWithCanonicalMapping
    }

    /// Step 2: going up to `/`, the first folder holding a `.git` folder or file.
    static func repositoryRoot(from start: String) -> String? {
        var folder = start
        while true {
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { return folder }
            guard folder != "/", !folder.isEmpty else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// Step 3: the main working tree of a linked worktree, or the common folder of a bare repository; the root itself
    /// in every other case.
    static func base(ofRepository root: String) -> String {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isFolder), !isFolder.boolValue,
              let text = try? String(contentsOfFile: gitPath, encoding: .utf8) else { return root }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return root }
        let written = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty, !written.contains("\\") else { return root }
        let gitFolder = absolute(written, relativeTo: root)
        guard !isSpecial(gitFolder),
              let commonText = try? String(contentsOfFile: (gitFolder as NSString).appendingPathComponent("commondir"), encoding: .utf8)
        else { return root }
        let commonWritten = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonWritten.isEmpty, !commonWritten.contains("\\") else { return root }
        let common = absolute(commonWritten, relativeTo: gitFolder)
        // The common folder's `worktrees` holds the git folder, and the git folder's `gitdir` points back at the root's `.git`.
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        guard (gitFolder as NSString).deletingLastPathComponent == worktrees,
              let backText = try? String(contentsOfFile: (gitFolder as NSString).appendingPathComponent("gitdir"), encoding: .utf8)
        else { return root }
        let back = backText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !back.contains("\\"), absolute(back, relativeTo: gitFolder) == gitPath || startPath(absolute(back, relativeTo: gitFolder)) == startPath(gitPath)
        else { return root }
        return (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
    }

    /// Step 4: every UTF-16 unit but an ASCII letter or digit becomes `-`; a name over 200 units keeps its first 200,
    /// then `-` and the base-36 absolute value of the base's Java `String.hashCode`.
    public static func folderName(_ base: String) -> String {
        let units = base.utf16.map { unit -> UInt16 in
            let isLetterOrDigit = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            return isLetterOrDigit ? unit : 0x2D
        }
        guard units.count > 200 else { return String(decoding: units, as: UTF16.self) }
        var hash: Int32 = 0
        for unit in base.utf16 { hash = hash &* 31 &+ Int32(unit) }
        let magnitude = String(abs(Int64(hash)), radix: 36)
        return String(decoding: units.prefix(200), as: UTF16.self) + "-" + magnitude
    }

    // MARK: autoMemoryDirectory

    enum Setting: Equatable {
        case folder(String)
        /// A string the CLI refuses: the default folder, without trying the next source.
        case refused
    }

    /// Step 6: the first settings source whose `autoMemoryDirectory` is a string gives it.
    func autoMemoryDirectory(root: String, mainTree: String?) -> Setting? {
        for source in settingsSources(root: root, mainTree: mainTree) {
            switch source {
            case .string(let value): return validated(value).map(Setting.folder) ?? .refused
            case .null, .absent: continue
            }
        }
        return nil
    }

    enum SourceValue { case string(String), null, absent }

    private func settingsSources(root: String, mainTree: String?) -> [SourceValue] {
        var sources: [SourceValue] = []
        // Managed: managed-settings.json, then the drop-ins sorted by name, the last holding the key giving it.
        var managed = Self.value(inFile: (managedFolder as NSString).appendingPathComponent("managed-settings.json"))
        let dropIns = (managedFolder as NSString).appendingPathComponent("managed-settings.d")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        for name in names {
            let value = Self.value(inFile: (dropIns as NSString).appendingPathComponent(name))
            if case .absent = value { continue }
            managed = value
        }
        sources.append(managed)
        // Local: the main working tree's wins over the project root's own.
        let ownLocal = Self.value(inFile: (root as NSString).appendingPathComponent(".claude/settings.local.json"))
        if let mainTree, mainTree != root {
            let mainLocal = Self.value(inFile: (mainTree as NSString).appendingPathComponent(".claude/settings.local.json"))
            if case .absent = mainLocal { sources.append(ownLocal) } else { sources.append(mainLocal) }
        } else {
            sources.append(ownLocal)
        }
        sources.append(Self.value(inFile: (root as NSString).appendingPathComponent(".claude/settings.json")))
        sources.append(Self.value(inFile: (configFolder as NSString).appendingPathComponent("settings.json")))
        return sources
    }

    /// The key in a settings file read as strict JSON: a missing or invalid file, or a value neither a string nor
    /// null, gives nothing.
    static func value(inFile path: String) -> SourceValue {
        guard var data = FileManager.default.contents(atPath: path) else { return .absent }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["autoMemoryDirectory"]
        else { return .absent }
        if let string = value as? String { return .string(string) }
        if value is NSNull { return .null }
        return .absent
    }

    /// The folder a value names, or nil when the CLI refuses it.
    func validated(_ value: String) -> String? {
        // A network or special path is refused as written, before `..` and repeated `/` are folded.
        guard !Self.isSpecial(value) else { return nil }
        var path = value
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            let rest = String(path.dropFirst(2))
            guard !rest.isEmpty else { return nil }
            path = Self.normalized((home as NSString).appendingPathComponent(rest))
            guard path == home || path.hasPrefix(home + "/") else { return nil }
        } else {
            path = Self.normalized(path)
        }
        while path.count > 1, path.hasSuffix("/") || path.hasSuffix("\\") { path.removeLast() }
        guard path.hasPrefix("/"), path.utf16.count >= 3, !path.contains("\0"), !Self.isSpecial(path) else { return nil }
        return path
    }

    /// Node's `path.normalize`: `.` and `..` resolved, repeated `/` merged.
    static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." { parts.removeLast(); continue }
            if part == "..", absolute { continue }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    /// Network and special paths, which the CLI refuses.
    static func isSpecial(_ path: String) -> Bool {
        if path.hasPrefix("//") || path.hasPrefix("\\\\") || path.hasPrefix("/??/") { return true }
        let lower = path.lowercased()
        if lower.hasPrefix("/net/") || lower == "/network" || lower.hasPrefix("/network/") { return true }
        return ["/.vol", "/.file", "/.nofollow", "/.resolve"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    private static func absolute(_ path: String, relativeTo folder: String) -> String {
        let joined = path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
        return normalized(joined)
    }
}

/// A memory folder a sub project inherits from an ancestor (docs/data.md › Memories): read-only for its chats.
public struct InheritedMemoryFolder: Sendable, Hashable {
    /// The nearest ancestor whose memory folder this is.
    public var projectID: String
    public var projectName: String
    public var folder: String

    public init(projectID: String, projectName: String, folder: String) {
        self.projectID = projectID
        self.projectName = projectName
        self.folder = folder
    }
}

extension MemoryLocations {
    /// The folders a project inherits: each ancestor's memory folder, nearest parent first, but the project's own and
    /// those already listed. `ancestors` are (id, name, root), nearest parent first.
    public func inherited(ownFolder: String, ancestors: [(id: String, name: String, root: String)]) -> [InheritedMemoryFolder] {
        var seen: Set<String> = [ownFolder]
        var result: [InheritedMemoryFolder] = []
        for ancestor in ancestors {
            let folder = projectFolder(root: ancestor.root)
            guard seen.insert(folder).inserted else { continue }
            result.append(InheritedMemoryFolder(projectID: ancestor.id, projectName: ancestor.name, folder: folder))
        }
        return result
    }
}
