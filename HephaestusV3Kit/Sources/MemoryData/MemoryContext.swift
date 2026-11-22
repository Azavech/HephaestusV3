import Foundation

/// What a chat's CLI gets of the memories at each launch (docs/data.md › Memories › In chats), as V2 gave it: the
/// global memories folder, made when missing, to read and write (`--add-dir`); the folders inherited from the parent
/// projects, to read only; and the internal skill `chat-memories` filled with them, appended to the CLI's system prompt.
public struct MemoryContext: Sendable, Hashable {
    public var globalFolder: String
    /// Whether the global folder exists or could be made; the CLI gets it with `--add-dir` only then.
    public var globalFolderReady: Bool
    /// Why the global folder couldn't be made.
    public var globalFolderFailure: String?
    public var globalIndex: String
    /// The inherited folders that exist, nearest parent first, with their `MEMORY.md` as the chats get it.
    public var inherited: [(folder: InheritedMemoryFolder, index: String)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.globalFolder == rhs.globalFolder && lhs.globalFolderReady == rhs.globalFolderReady && lhs.globalIndex == rhs.globalIndex
            && lhs.inherited.map(\.folder) == rhs.inherited.map(\.folder) && lhs.inherited.map(\.index) == rhs.inherited.map(\.index)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(globalFolder)
        hasher.combine(inherited.map(\.folder))
    }

    /// Reads what a chat of the project at `root`, whose ancestors are given nearest parent first, gets.
    public static func load(locations: MemoryLocations, root: String, ancestors: [(id: String, name: String, root: String)]) -> MemoryContext {
        let global = locations.globalFolder
        var failure: String?
        do {
            try FileManager.default.createDirectory(atPath: global, withIntermediateDirectories: true)
        } catch {
            failure = error.localizedDescription
        }
        let own = locations.projectFolder(root: root)
        let inherited = locations.inherited(ownFolder: own, ancestors: ancestors).compactMap { folder -> (InheritedMemoryFolder, String)? in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.folder, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return (folder, indexForPrompt((try? MemoryFolder(path: folder.folder).readIndex()) ?? nil))
        }
        return MemoryContext(globalFolder: global, globalFolderReady: failure == nil, globalFolderFailure: failure,
                             globalIndex: indexForPrompt((try? MemoryFolder(path: global).readIndex()) ?? nil),
                             inherited: inherited.map { (folder: $0.0, index: $0.1) })
    }

    /// `MEMORY.md` as a chat gets it, as the CLI limits its own: line breaks as LF, trimmed, its first 200 lines, then
    /// at most 25,000 UTF-16 units, cut at the last line break that fits.
    public static func indexForPrompt(_ text: String?) -> String {
        guard var text else { return "" }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 200 { text = lines.prefix(200).joined(separator: "\n") }
        let units = Array(text.utf16)
        guard units.count > 25_000 else { return text }
        let head = Array(units.prefix(25_000))
        if let lastBreak = head.lastIndex(of: 0x0A), lastBreak > 0 {
            return String(decoding: head[..<lastBreak], as: UTF16.self)
        }
        return String(decoding: head, as: UTF16.self)
    }

    /// The skill's content with its placeholders filled: `{{globalMemoriesFolder}}`, `{{globalMemories}}` (the global
    /// `MEMORY.md`) and `{{parentMemories}}` (each inherited folder: its project's name and identifier and its path,
    /// then its `MEMORY.md`; empty for a top-level project). Nil when the content is blank: nothing is appended.
    public func render(_ content: String) -> String? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parents = inherited.map { entry in
            let heading = "\(entry.folder.projectName) (\(entry.folder.projectID)), \(entry.folder.folder):"
            return entry.index.isEmpty ? heading : heading + "\n" + entry.index
        }.joined(separator: "\n\n")
        return content
            .replacing("{{globalMemoriesFolder}}", with: globalFolder)
            .replacing("{{globalMemories}}", with: globalIndex)
            .replacing("{{parentMemories}}", with: parents)
    }

    /// The CLI's `Read` rules for the inherited folders: `Read(//<folder>/**)`, and the same for the folder with its
    /// links resolved when it differs. A path the CLI would read as a pattern, or that ends with white space, gets none.
    public var readRules: [String] {
        var rules: [String] = []
        for entry in inherited {
            let written = entry.folder.folder
            for path in [written, MemoryLocations.startPath(written)] {
                guard !path.contains(where: { "*?[\\".contains($0) || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }),
                      path.last.map({ !$0.isWhitespace && $0 != "\u{FEFF}" }) ?? false else { continue }
                let rule = "Read(/\(path)/**)"
                if !rules.contains(rule) { rules.append(rule) }
            }
        }
        return rules
    }
}
