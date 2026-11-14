import Foundation

/// A project's GitHub page, `https://github.com/<owner>/<name>` (docs/data.md › Project file,
/// `githubPage`).
public enum GitHubPage {
    static let prefix = "https://github.com/"

    /// The page of an owner and a repository name; nil when it isn't a valid page.
    public static func page(owner: String, name: String) -> String? {
        normalized(prefix + owner + "/" + name)
    }

    /// A typed page trimmed and without one trailing `/`; nil when the result isn't
    /// `https://github.com/<owner>/<name>`, `<owner>` of ASCII letters, digits, `-` and `_`, `<name>` of
    /// ASCII letters, digits, `.`, `-` and `_`, neither `.` nor `..`.
    public static func normalized(_ text: String) -> String? {
        var page = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.hasSuffix("/") {
            page.removeLast()
        }
        guard page.hasPrefix(prefix) else { return nil }
        let parts = page.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isOwner(parts[0]), isName(parts[1]) else { return nil }
        return page
    }

    /// The owner and the repository name of a page; nil when the text isn't a page.
    public static func ownerAndName(of text: String) -> (owner: String, name: String)? {
        guard let page = normalized(text) else { return nil }
        let parts = page.dropFirst(prefix.count).split(separator: "/")
        return (String(parts[0]), String(parts[1]))
    }

    /// The page as stored. Throws `ProjectRuleError.githubPage` for anything else.
    public static func validated(_ text: String) throws(ProjectRuleError) -> String {
        guard let page = normalized(text) else { throw .githubPage }
        return page
    }

    private static func isOwner(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "-" || $0 == "_" }
    }

    private static func isName(_ text: Substring) -> Bool {
        !text.isEmpty && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// The host, owner and name of a git remote, in one of the forms git writes:
/// `[<user>@]<host>:<owner>/<name>`, `ssh://[<user>@]<host>[:<port>]/<owner>/<name>` and
/// `https://[<user>@]<host>[:<port>]/<owner>/<name>`, each with or without a final `.git`.
public struct GitRemote: Sendable, Hashable {
    /// GitHub's host.
    public static let gitHubHost = "github.com"

    /// The host as written in the remote, an SSH host alias included.
    public var host: String
    public var owner: String
    public var name: String
    /// True for the two SSH forms, whose host may be an alias of `~/.ssh/config`.
    public var isSSH: Bool

    public init(host: String, owner: String, name: String, isSSH: Bool) {
        self.host = host
        self.owner = owner
        self.name = name
        self.isSSH = isSSH
    }

    /// The parts of a remote URL; nil for any other form.
    public init?(remoteURL: String) {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "ssh" || scheme == "https", let components = URLComponents(string: text),
                  let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
                  components.path.hasPrefix("/") else { return nil }
            self.host = host
            path = String(components.path.dropFirst())
            isSSH = scheme == "ssh"
        } else {
            // The scp-like form: the part before the first `:` is `[<user>@]<host>` and holds no `/`
            // (git reads a `/` before the colon as a local path).
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let userAndHost = text[..<colon]
            guard !userAndHost.contains("/"),
                  let host = userAndHost.split(separator: "@", omittingEmptySubsequences: false).last, !host.isEmpty
            else { return nil }
            self.host = String(host)
            path = String(text[text.index(after: colon)...])
            isSSH = true
        }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// True when the host is `github.com`, in any letter case.
    public var isGitHubHost: Bool {
        host.lowercased() == Self.gitHubHost
    }

    /// The GitHub page of the remote, when its host is GitHub's, or when it is an SSH alias whose real
    /// host name (`ssh -G`) is; nil otherwise.
    public func gitHubPage(resolvedHostName: String? = nil) -> String? {
        let isGitHub = isGitHubHost || (isSSH && resolvedHostName?.lowercased() == Self.gitHubHost)
        return isGitHub ? GitHubPage.page(owner: owner, name: name) : nil
    }
}
