import Foundation

/// Options of the Markdown renderers (docs/documentation-viewer.md › Renderer).
public struct MarkdownRenderOptions: Sendable {
    /// Project path of the folder the text belongs to; "" for the project root.
    public var baseDirectory: String
    /// Absolute path of the project root on the main device; recognizes absolute paths and file URLs.
    public var projectRootPath: String?
    /// Removes a leading YAML front matter block before parsing.
    public var stripFrontMatter: Bool
    /// Identifiers of the projects loaded in the app; their ticket and bundle ids become links
    /// (docs/documentation-viewer.md › Ticket and bundle ids).
    public var projectIdentifiers: Set<String>
    /// Writes each soft line break as a hard line break (docs/documentation-viewer.md › Renderer).
    public var softBreaksAsLineBreaks: Bool

    public init(baseDirectory: String = "", projectRootPath: String? = nil, stripFrontMatter: Bool = false,
                projectIdentifiers: Set<String> = [], softBreaksAsLineBreaks: Bool = false) {
        self.baseDirectory = baseDirectory
        self.projectRootPath = projectRootPath
        self.stripFrontMatter = stripFrontMatter
        self.projectIdentifiers = projectIdentifiers
        self.softBreaksAsLineBreaks = softBreaksAsLineBreaks
    }
}

enum FrontMatter {
    /// When the first line is exactly `---` and a later line is exactly `---` or `...`, every
    /// line up to and including that closing line is removed (docs/documentation-viewer.md ›
    /// Front matter). Without a closing line nothing is removed.
    static func strip(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first == "---" || first == "---\r" else { return markdown }
        for index in lines.indices.dropFirst() {
            let line = lines[index].hasSuffix("\r") ? lines[index].dropLast() : lines[index]
            if line == "---" || line == "..." {
                return lines[(index + 1)...].joined(separator: "\n")
            }
        }
        return markdown
    }
}
