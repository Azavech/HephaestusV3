import Foundation
import ProjectData
import ToolsFoundation

/// How the projects of the app's data become the `Project` values every window shows
/// (docs/architecture.md › ProjectsKit).
extension Project.Kind {
    /// The types: `goService` is a Service, `swiftApplication` an App, `library` a Library, `none` Other.
    public init(_ kind: ProjectKind) {
        switch kind {
        case .goService: self = .service
        case .swiftApplication: self = .app
        case .library: self = .library
        case .none: self = .other
        }
    }

    /// The type stored in `project.yml`.
    public var stored: ProjectKind {
        switch self {
        case .service: .goService
        case .app: .swiftApplication
        case .library: .library
        case .other: .none
        }
    }
}

extension ProjectTint {
    /// The tint of a stored color: a tint's name gives that tint; a `#RRGGBB` gives the tint of the
    /// nearest hue (a gray gives Accent); no color gives Accent.
    public init(stored color: String?) {
        guard let color else {
            self = .accent
            return
        }
        if let tint = ProjectTint(rawValue: color) {
            self = tint
            return
        }
        self = Self.nearest(toHex: color) ?? .accent
    }

    /// The hue of each tint, in degrees, as AZDesign draws it in Dark Mode (Dracula).
    static let hues: [(ProjectTint, Double)] = [
        (.accent, 265), (.accentSecondary, 326), (.info, 191), (.success, 135), (.warning, 31),
    ]

    static func nearest(toHex hex: String) -> ProjectTint? {
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255, green = Double((value >> 8) & 0xFF) / 255, blue = Double(value & 0xFF) / 255
        let high = max(red, green, blue), low = min(red, green, blue), range = high - low
        guard range > 0.08 else { return .accent }
        var hue: Double
        switch high {
        case red: hue = 60 * ((green - blue) / range).truncatingRemainder(dividingBy: 6)
        case green: hue = 60 * ((blue - red) / range + 2)
        default: hue = 60 * ((red - green) / range + 4)
        }
        if hue < 0 { hue += 360 }
        func distance(_ other: Double) -> Double { min(abs(hue - other), 360 - abs(hue - other)) }
        return hues.min { distance($0.1) < distance($1.1) }?.0
    }
}

extension DeploymentEnvironment {
    /// An environment as it applies; `inheritedFrom` names the parent it comes from, if it does.
    public init(_ entry: EnvironmentEntry, inheritedFrom: Project.ID?) {
        self.init(name: entry.name, cluster: nil, namespace: entry.namespace, url: entry.baseURL, health: nil,
                  deployment: entry.deployment, jaeger: entry.jaeger, argoCDApplication: entry.argoCDApplication,
                  kubeconfig: entry.kubeconfig, allowsInvalidCertificates: entry.allowInvalidCertificates, inheritedFrom: inheritedFrom)
    }
}

extension Project {
    /// A loaded project as the windows show it. Its tools report no figures yet: `activity` is nil.
    public init(_ loaded: LoadedProject) {
        let file = loaded.file
        let kind = Project.Kind(file.type)
        let inheritedNames = Set(loaded.resolved.inheritedEnvironments.map(\.name))
        let repository = loaded.resolved.githubPage.flatMap(GitHubPage.ownerAndName).map { "\($0.owner)/\($0.name)" } ?? ""
        self.init(
            id: file.id, name: file.name, kind: kind, tint: ProjectTint(stored: file.color), symbol: file.icon ?? kind.symbol,
            path: loaded.root, repository: repository,
            environments: loaded.resolved.environments.map {
                DeploymentEnvironment($0, inheritedFrom: inheritedNames.contains($0.name) ? loaded.parentID : nil)
            },
            activity: nil, parentID: loaded.parentID, environmentsAreResolved: true,
            githubPage: loaded.resolved.githubPage, currentEnvironment: loaded.resolved.currentEnvironment, fileIssue: loaded.fileIssue,
            hasContract: FileManager.default.fileExists(atPath: loaded.root + "/openapi/contract.yaml"),
            graphEnabled: loaded.resolved.graphEnabled
        )
    }
}

extension ProjectDirectory {
    /// Brings the directory in step with the session: its projects, its state, and the entries that didn't
    /// load, each with its reason in the user's words.
    @MainActor
    public func update(from session: ProjectSession) {
        let snapshot = session.snapshot
        let names = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.file.name) })
        let unavailable = snapshot.issues.map { issue in
            var parentID: Project.ID?
            if case .subproject(let parent, _) = issue.source { parentID = parent }
            return Unavailable(path: issue.path, reason: ProjectMessages.reason(issue.reason, names: names), parentID: parentID)
        }
        let state: State = switch session.phase {
        case .starting: .loading
        case .ready: .ready
        case .failed(let error): .failed(ProjectMessages.message(error))
        }
        update(projects: snapshot.projects.map(Project.init), state: state, unavailable: unavailable)
    }
}

/// The user's words for what the project data reports.
public enum ProjectMessages {
    /// Why an entry of the list didn't load.
    public static func reason(_ reason: ProjectIssue.Reason, names: [String: String] = [:]) -> String {
        switch reason {
        case .folderMissing:
            String(localized: "The folder is missing.", bundle: #bundle, comment: "Why a project of the list didn't load")
        case .fileMissing:
            String(localized: "The folder has no .hephaestus/project.yml.", bundle: #bundle, comment: "Why a project of the list didn't load")
        case .invalidFile(let detail):
            String(localized: "Its project.yml can't be read: \(detail)", bundle: #bundle,
                   comment: "Why a project of the list didn't load; the detail is technical, in English")
        case .identifierInUse(let identifier, let name):
            String(localized: "Its identifier \(identifier) is already used by “\(name)”.", bundle: #bundle,
                   comment: "Why a project of the list didn't load")
        case .invalidEntry:
            String(localized: "The list names it with a path that can't be used.", bundle: #bundle,
                   comment: "Why a project of the list didn't load")
        }
    }

    /// What a failed change or start says.
    public static func message(_ error: ProjectError) -> String {
        switch error {
        case .noDataFolder:
            String(localized: "This copy of Hephaestus V3 has no data folder: it can't find the Application Support folder.", bundle: #bundle)
        case .storage(.folderInUse):
            String(localized: "Another copy of Hephaestus V3 is using its data. Quit it, then open this one again.", bundle: #bundle)
        case .storage(let error):
            String(localized: "A file can't be used: \(error.description)", bundle: #bundle,
                   comment: "A storage error; the detail is technical, in English")
        case .rule(let rule):
            ruleMessage(rule)
        case .noProject:
            String(localized: "The folder has no .hephaestus/project.yml.", bundle: #bundle)
        case .alreadyContainsProject:
            String(localized: "The folder already holds a project. Add it with Add Existing Folder instead.", bundle: #bundle)
        case .folderMissing:
            String(localized: "The folder doesn’t exist.", bundle: #bundle)
        case .notInsideParent(let parentName):
            String(localized: "Choose a folder inside “\(parentName)”.", bundle: #bundle)
        case .projectNotLoaded:
            String(localized: "The project is no longer in the list.", bundle: #bundle)
        case .unknownEnvironment(let name):
            String(localized: "The project has no environment named “\(name)”.", bundle: #bundle)
        }
    }

    /// What a value that breaks a write rule says.
    public static func ruleMessage(_ rule: ProjectRuleError) -> String {
        switch rule {
        case .identifierFormat:
            String(localized: "Use 2 to 8 letters (A–Z).", bundle: #bundle)
        case .identifierInUse(let identifier, let name):
            String(localized: "\(identifier) is already used by “\(name)”.", bundle: #bundle)
        case .nameLength:
            String(localized: "Enter a name of 1 to 100 characters.", bundle: #bundle)
        case .relativePath:
            String(localized: "Enter a folder path inside the project, for example docs.", bundle: #bundle)
        case .url:
            String(localized: "Enter an http or https URL.", bundle: #bundle)
        case .port:
            String(localized: "Enter a port from 1 to 65535.", bundle: #bundle)
        case .singleLine:
            String(localized: "Use one line.", bundle: #bundle)
        case .jaeger:
            String(localized: "Enter a Service as <namespace>/<name>, for example jaeger/jaeger.", bundle: #bundle)
        case .argoCDApplication:
            String(localized: "Enter an application as <name> or <namespace>/<name>.", bundle: #bundle)
        case .kubeconfig:
            String(localized: "Enter an absolute path or a path starting with ~/.", bundle: #bundle)
        case .githubPage:
            String(localized: "Enter a GitHub page, for example https://github.com/owner/name.", bundle: #bundle)
        case .color:
            String(localized: "Choose a tint.", bundle: #bundle)
        case .duplicateEnvironment(let name):
            String(localized: "An environment named “\(name)” already exists.", bundle: #bundle)
        case .widget, .duplicateWidget:
            // Only the Dashboard changes widgets; its windows show the data's own message.
            rule.description
        }
    }
}
