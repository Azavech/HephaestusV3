import Foundation

/// The rules of the project files' values (docs/data.md › Ids, › Paths, › Project environment). The
/// read rules make a file invalid; the write rules are checked on what the user or Claude changes, and
/// a value that breaks one is refused with a `ProjectRuleError`.
public enum ProjectRules {
    // MARK: Identifiers

    /// A project identifier: `^[A-Z]{2,8}$`, such as `HEPH`. It prefixes the project's tickets.
    public static func isIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (2...8).contains(bytes.count) && bytes.allSatisfy { (0x41...0x5A).contains($0) }
    }

    /// The identifier a name suggests, from its ASCII letters, accents removed: a name that starts with a capital
    /// and has two capitals or more gives its capitals, at most eight (`AntiBeeCycle` → `ABC`, `YeenCloud` → `YC`,
    /// `Orders API` → `OAPI`); any other name its first four letters, uppercased (`orders` → `ORDE`). Nothing when
    /// that gives fewer than two letters.
    public static func suggestedIdentifier(fromName name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        func isCapital(_ scalar: Unicode.Scalar) -> Bool { (0x41...0x5A).contains(scalar.value) }
        if let first = folded.unicodeScalars.first, isCapital(first) {
            let capitals = folded.unicodeScalars.filter(isCapital)
            if capitals.count >= 2 { return String(String.UnicodeScalarView(capitals.prefix(8))) }
        }
        let letters = folded.uppercased().unicodeScalars.filter(isCapital)
        let suggestion = String(String.UnicodeScalarView(letters.prefix(4)))
        return suggestion.count >= 2 ? suggestion : ""
    }

    // MARK: Text

    /// The value trimmed, nil when it is nil or empty once trimmed.
    public static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A project's or an environment's name: one line of 1 to 100 characters, trimmed.
    public static func name(_ value: String, field: String) throws(ProjectRuleError) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), (1...100).contains(trimmed.count) else { throw .nameLength(field: field) }
        return trimmed
    }

    // MARK: Paths

    /// A relative path of a project file: `/` separators, no leading or trailing `/`, no empty, `.` or
    /// `..` component.
    public static func isRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// An absolute path of the data folder's files: starts with `/`, no trailing `/`, no empty, `.` or
    /// `..` component.
    public static func isAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        if value == "/" { return true }
        guard !value.hasSuffix("/") else { return false }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// An absolute path, or one starting with `~/`.
    public static func isAbsoluteOrHomePath(_ value: String) -> Bool {
        value.hasPrefix("/") || (value.hasPrefix("~/") && value.count > 2)
    }

    // MARK: Environments

    /// An absolute `http` or `https` URL with a host.
    public static func isHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// An environment's `url`: trimmed, nil when empty, otherwise an absolute `http` or `https` URL.
    public static func environmentURL(_ value: String?, field: String) throws(ProjectRuleError) -> String? {
        guard let trimmed = trimmedOrNil(value) else { return nil }
        guard isHTTPURL(trimmed) else { throw .url(field: field) }
        return trimmed
    }

    /// An environment's `port`: 1–65535.
    public static func port(_ value: Int, field: String) throws(ProjectRuleError) -> Int {
        guard (1...65535).contains(value) else { throw .port(field: field) }
        return value
    }

    /// A namespace or a deployment: trimmed, nil when empty, otherwise one line.
    public static func line(_ value: String?, field: String) throws(ProjectRuleError) -> String? {
        guard let trimmed = trimmedOrNil(value) else { return nil }
        guard !trimmed.contains(where: \.isNewline) else { throw .singleLine(field: field) }
        return trimmed
    }

    /// The Kubernetes Service of a Jaeger, `<namespace>/<name>`: exactly one `/`, the parts not empty,
    /// no white space.
    public static func isJaegerService(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
    }

    public static func jaeger(_ value: String?, field: String) throws(ProjectRuleError) -> String? {
        guard let trimmed = trimmedOrNil(value) else { return nil }
        guard isJaegerService(trimmed) else { throw .jaeger(field: field) }
        return trimmed
    }

    /// An Argo CD Application, `<name>` (in the namespace `argocd`) or `<namespace>/<name>`: one `/` at
    /// most, the parts not empty, no white space.
    public static func isArgoCDApplication(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty }
    }

    public static func argoCDApplication(_ value: String?, field: String) throws(ProjectRuleError) -> String? {
        guard let trimmed = trimmedOrNil(value) else { return nil }
        guard isArgoCDApplication(trimmed) else { throw .argoCDApplication(field: field) }
        return trimmed
    }

    /// A kubeconfig file: trimmed, nil when empty, otherwise one line, an absolute path or one starting
    /// with `~/`.
    public static func kubeconfig(_ value: String?, field: String) throws(ProjectRuleError) -> String? {
        guard let trimmed = trimmedOrNil(value) else { return nil }
        guard !trimmed.contains(where: \.isNewline), isAbsoluteOrHomePath(trimmed) else { throw .kubeconfig(field: field) }
        return trimmed
    }
}

/// A value that breaks a write rule. The windows say it in their own words, by case; `description` is
/// the English message of the logs and of Claude's tools.
public enum ProjectRuleError: Error, Sendable, Hashable, CustomStringConvertible {
    case identifierFormat
    case identifierInUse(identifier: String, by: String)
    case nameLength(field: String)
    case relativePath(field: String)
    case url(field: String)
    case port(field: String)
    case singleLine(field: String)
    case jaeger(field: String)
    case argoCDApplication(field: String)
    case kubeconfig(field: String)
    case githubPage
    case color
    case duplicateEnvironment(String)
    case widget(field: String, message: String)
    case duplicateWidget(String)

    public var description: String {
        switch self {
        case .identifierFormat: "identifier: use 2 to 8 letters A–Z."
        case let .identifierInUse(identifier, name): "\(identifier) is already used by “\(name)”."
        case let .nameLength(field): "\(field): use 1 to 100 characters on one line."
        case let .relativePath(field): "\(field): use a relative path with / separators and no empty, . or .. component."
        case let .url(field): "\(field): use an absolute http or https URL."
        case let .port(field): "\(field): use a port from 1 to 65535."
        case let .singleLine(field): "\(field): use one line."
        case let .jaeger(field): "\(field): use a Jaeger as <namespace>/<name>."
        case let .argoCDApplication(field): "\(field): use an Argo CD application as <name> or <namespace>/<name>."
        case let .kubeconfig(field): "\(field): use a kubeconfig file as an absolute path or a path starting with ~/."
        case .githubPage: "githubPage: use a page of the form https://github.com/<owner>/<name>."
        case .color: "color: use a tint or a color of the form #RRGGBB."
        case let .duplicateEnvironment(name): "An environment named “\(name)” already exists."
        case let .widget(field, message): "\(field): \(message)."
        case let .duplicateWidget(id): "Widget \(id) is listed more than once."
        }
    }
}
