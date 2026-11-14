import FileStorage
import Foundation

/// A project's `.hephaestus/` folder and the paths of its files (docs/data.md › Project folder).
public struct ProjectFolder: Sendable, Hashable {
    /// The project's folder.
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `.hephaestus/`
    public var dataFolder: URL { root.appendingPathComponent(".hephaestus", isDirectory: true) }
    /// `.hephaestus/project.yml`
    public var projectFile: URL { dataFolder.appendingPathComponent("project.yml") }
    /// `.hephaestus/.gitignore`
    public var gitignoreFile: URL { dataFolder.appendingPathComponent(".gitignore") }
    /// `.hephaestus/ticket/`
    public var ticketFolder: URL { dataFolder.appendingPathComponent("ticket", isDirectory: true) }
    /// `.hephaestus/bundle/`
    public var bundleFolder: URL { dataFolder.appendingPathComponent("bundle", isDirectory: true) }
    /// `.hephaestus/chats/`, which git ignores.
    public var chatsFolder: URL { dataFolder.appendingPathComponent("chats", isDirectory: true) }
    /// `.hephaestus/attachments/`
    public var attachmentsFolder: URL { dataFolder.appendingPathComponent("attachments", isDirectory: true) }

    /// True when the folder is a project: it holds `.hephaestus/project.yml`.
    public var isProject: Bool { FileManager.default.fileExists(atPath: projectFile.path) }

    /// The line of `.hephaestus/.gitignore`: chats stay out of git.
    public static let gitignoreLine = "chats/"

    /// Writes `.hephaestus/.gitignore` with the line `chats/`, or adds the line to a file that lacks it,
    /// after a line break when the file doesn't end with one.
    /// - Returns: the SHA-256 of the written bytes, or nil when the file already had the line.
    @discardableResult
    public func ensureGitignore(ownWrites: OwnWrites? = nil) throws -> String? {
        let url = gitignoreFile
        var data: Data
        if let existing = try? Data(contentsOf: url) {
            let lines = String(decoding: existing, as: UTF8.self).components(separatedBy: "\n")
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            guard !lines.contains(Self.gitignoreLine) else { return nil }
            data = existing
            if let last = existing.last, last != 0x0A {
                data.append(0x0A)
            }
        } else {
            data = Data()
        }
        data.append(Data((Self.gitignoreLine + "\n").utf8))
        let digest = try AtomicFile.write(data, to: url)
        ownWrites?.recordWrite(path: AtomicFile.resolvedDestination(url).path, sha256: digest)
        return digest
    }
}
