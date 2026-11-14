import FileStorage
import Foundation

/// `.hephaestus/project.yml`: a project's identity, type, color, icon, counters, documentation folder,
/// GitHub page, sub projects and environments (docs/data.md › Project file).
///
/// Read and written in a fixed key order. The keys the app doesn't use yet (`webTabs`, `skills`,
/// `chatDefaults`, `deletedChats`, `commentAnswers`) are kept exactly as read, at their place; the app never
/// adds them. Keys it doesn't know follow, in the order they were read.
public struct ProjectFile: Codable, Sendable, Hashable {
    public var schema: Int
    /// The identifier (`ProjectRules.isIdentifier`). Set at creation, never changed.
    public var id: String
    public var name: String
    public var created: Date
    public var type: ProjectKind
    /// `#RRGGBB` in uppercase, or the name of a tint (`ProjectColor.tintNames`); nil for no
    /// color.
    public var color: String?
    /// The name of an SF Symbol; nil for no icon.
    public var icon: String?
    public var nextTicketNumber: Int
    public var nextBundleNumber: Int
    /// The relative path of the documentation folder.
    public var docsPath: String
    /// The page typed in the GitHub page field, `https://github.com/<owner>/<name>`.
    public var githubPage: String?
    /// The relative paths of the direct sub projects, in the order they were added.
    public var subprojects: [String]
    /// Whether the graph is enabled; nil takes the parent's value, false for a top-level project.
    public var graphEnabled: Bool?
    /// The project's own environments, in the order they were added.
    public var environments: [EnvironmentEntry]
    /// The changes of a sub project to the environments it inherits, by environment name.
    public var environmentOverrides: [String: EnvironmentOverride]
    /// The widgets of the project's Dashboard, in their order; nil shows the default list, `[]` no widget.
    public var dashboardWidgets: [DashboardWidgetEntry]?
    /// The time window of the Dashboard's service widgets; nil is `hour`.
    public var dashboardGraphWindow: DashboardGraphWindow?
    /// The keys the app doesn't use yet, as read; absent keys stay absent.
    public var keptKeys: YAMLMapping
    /// The keys the app doesn't know, in the order they were read.
    public var unknownKeys: YAMLMapping

    public init(schema: Int = 1, id: String, name: String, created: Date, type: ProjectKind = .none, color: String? = nil,
                icon: String? = nil, nextTicketNumber: Int = 1, nextBundleNumber: Int = 1, docsPath: String = "docs",
                githubPage: String? = nil, subprojects: [String] = [],
                graphEnabled: Bool? = nil, environments: [EnvironmentEntry] = [],
                environmentOverrides: [String: EnvironmentOverride] = [:], dashboardWidgets: [DashboardWidgetEntry]? = nil,
                dashboardGraphWindow: DashboardGraphWindow? = nil, keptKeys: YAMLMapping = [:],
                unknownKeys: YAMLMapping = [:]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.created = created
        self.type = type
        self.color = color
        self.icon = icon
        self.nextTicketNumber = nextTicketNumber
        self.nextBundleNumber = nextBundleNumber
        self.docsPath = docsPath
        self.githubPage = githubPage
        self.subprojects = subprojects
        self.graphEnabled = graphEnabled
        self.environments = environments
        self.environmentOverrides = environmentOverrides
        self.dashboardWidgets = dashboardWidgets
        self.dashboardGraphWindow = dashboardGraphWindow
        self.keptKeys = keptKeys
        self.unknownKeys = unknownKeys
    }

    /// Every key of the table, in its order.
    static let keyOrder = [
        "schema", "id", "name", "created", "type", "color", "icon", "nextTicketNumber", "nextBundleNumber", "docsPath",
        "githubPage", "useParentSettings", "subprojects", "webTabs", "skills", "chatDefaults", "graphEnabled",
        "environments", "environmentOverrides", "dashboardWidgets", "dashboardGraphWindow", "deletedChats", "commentAnswers",
    ]
    /// The keys kept as read. `useParentSettings`, V2's switch, no longer has an effect: every field of a sub
    /// project that is empty takes the parent's value.
    static let keptKeys: Set<String> = ["useParentSettings", "webTabs", "skills", "chatDefaults", "deletedChats", "commentAnswers"]
    static let knownKeys = Set(keyOrder)

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, ProjectRules.isIdentifier, "project identifier")
        name = try c.required("name")
        created = try c.requiredDate("created")
        type = try c.value("type", default: ProjectKind.none)
        color = try c.optional("color", String.self).map { text in
            guard let color = ProjectColor.normalized(text) else {
                throw c.invalid("color", "\"\(text)\" is not a color of the form #RRGGBB, nor a tint")
            }
            return color
        }
        icon = ProjectRules.trimmedOrNil(try c.optional("icon", String.self))
        nextTicketNumber = try c.value("nextTicketNumber", default: 1)
        nextBundleNumber = try c.value("nextBundleNumber", default: 1)
        docsPath = try c.value("docsPath", default: "docs")
        githubPage = try c.optional("githubPage", String.self).map { text in
            guard let page = GitHubPage.normalized(text) else {
                throw c.invalid("githubPage", "\"\(text)\" is not a page of the form https://github.com/<owner>/<name>")
            }
            return page
        }
        subprojects = try c.value("subprojects", default: [])
        graphEnabled = try c.optional("graphEnabled")
        environments = try c.value("environments", default: [])
        environmentOverrides = try c.value("environmentOverrides", default: [:])
        dashboardWidgets = try c.optional("dashboardWidgets")
        dashboardGraphWindow = try c.optional("dashboardGraphWindow")
        var kept = YAMLMapping()
        for key in Self.keyOrder where Self.keptKeys.contains(key) {
            kept[key] = try c.raw(key)
        }
        keptKeys = kept
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(name, "name")
        try c.encodeDate(created, "created")
        try c.encode(type, "type")
        try c.encodeIfPresent(color, "color")
        try c.encodeIfPresent(icon, "icon")
        try c.encode(nextTicketNumber, "nextTicketNumber")
        try c.encode(nextBundleNumber, "nextBundleNumber")
        try c.encode(docsPath, "docsPath")
        try c.encodeIfPresent(githubPage, "githubPage")
        try c.encodeIfPresent(keptKeys["useParentSettings"], "useParentSettings")
        try c.encode(subprojects, "subprojects")
        for key in ["webTabs", "skills", "chatDefaults"] {
            try c.encodeIfPresent(keptKeys[key], key)
        }
        try c.encodeIfPresent(graphEnabled, "graphEnabled")
        try c.encode(environments, "environments")
        try c.encode(EnvironmentOverride.SortedMap(environmentOverrides), "environmentOverrides")
        try c.encodeIfPresent(dashboardWidgets, "dashboardWidgets")
        try c.encodeIfPresent(dashboardGraphWindow, "dashboardGraphWindow")
        for key in ["deletedChats", "commentAnswers"] {
            try c.encodeIfPresent(keptKeys[key], key)
        }
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }
}

/// The key `type`: what the project is (docs/data.md › Project kind).
public enum ProjectKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Neither of the others: `none`, shown as Other.
    case none
    /// A Go service: V3's Service.
    case goService
    /// A Swift application: V3's App.
    case swiftApplication
    /// A library. V3's addition to the format.
    case library
}

/// The key `color`: `#RRGGBB`, or the name of one of the app's tints, the semantic colors of
/// AZDesign (docs/data.md › Project file).
public enum ProjectColor {
    /// The tints V3 writes, the names of ToolsFoundation's `ProjectTint`.
    public static let tintNames: Set<String> = ["accent", "accentSecondary", "info", "success", "warning"]

    /// A color as stored: `#RRGGBB` in uppercase, or a tint name as is; nil for anything else.
    public static func normalized(_ text: String) -> String? {
        if tintNames.contains(text) { return text }
        let bytes = Array(text.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#"),
              bytes.dropFirst().allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        return text.uppercased()
    }
}

/// One element of the key `environments`: a place where a service runs, with the Kubernetes resources
/// it runs on (docs/data.md › Project environment).
public struct EnvironmentEntry: Codable, Sendable, Hashable {
    public var name: String
    /// The address of the environment's API, an absolute `http` or `https` URL; nil for none.
    public var url: String?
    /// Replaces the URL's port in the base URL; nil keeps the URL's own.
    public var port: Int?
    /// Whether requests to the environment accept an invalid server certificate.
    public var allowInvalidCertificates: Bool
    /// The Kubernetes namespace of the deployment; nil uses the current context's.
    public var namespace: String?
    /// The Kubernetes Deployment that runs the service.
    public var deployment: String?
    /// The Kubernetes Service of the environment's Jaeger, `<namespace>/<name>`.
    public var jaeger: String?
    /// The Argo CD Application that deploys the service, `<name>` or `<namespace>/<name>`.
    public var argoCDApplication: String?
    /// The kubeconfig file, an absolute path or one starting with `~/`; nil uses kubectl's default.
    public var kubeconfig: String?
    /// The keys the app doesn't know, such as an old `context`, in their order.
    public var unknownKeys: YAMLMapping

    public init(name: String, url: String? = nil, port: Int? = nil, allowInvalidCertificates: Bool = false,
                namespace: String? = nil, deployment: String? = nil, jaeger: String? = nil, argoCDApplication: String? = nil,
                kubeconfig: String? = nil, unknownKeys: YAMLMapping = [:]) {
        self.name = name
        self.url = url
        self.port = port
        self.allowInvalidCertificates = allowInvalidCertificates
        self.namespace = namespace
        self.deployment = deployment
        self.jaeger = jaeger
        self.argoCDApplication = argoCDApplication
        self.kubeconfig = kubeconfig
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["name", "url", "port", "allowInvalidCertificates", "namespace", "deployment", "jaeger",
                                         "argoCDApplication", "kubeconfig"]

    /// The URL and the Kubernetes keys are read trimmed, an empty value being null.
    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        name = try c.required("name")
        url = ProjectRules.trimmedOrNil(try c.optional("url", String.self))
        port = try c.optional("port")
        allowInvalidCertificates = try c.value("allowInvalidCertificates", default: false)
        namespace = ProjectRules.trimmedOrNil(try c.optional("namespace", String.self))
        deployment = ProjectRules.trimmedOrNil(try c.optional("deployment", String.self))
        jaeger = ProjectRules.trimmedOrNil(try c.optional("jaeger", String.self))
        argoCDApplication = ProjectRules.trimmedOrNil(try c.optional("argoCDApplication", String.self))
        kubeconfig = ProjectRules.trimmedOrNil(try c.optional("kubeconfig", String.self))
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(name, "name")
        try c.encodeOptional(url, "url")
        try c.encodeOptional(port, "port")
        try c.encode(allowInvalidCertificates, "allowInvalidCertificates")
        try c.encodeOptional(namespace, "namespace")
        try c.encodeOptional(deployment, "deployment")
        try c.encodeOptional(jaeger, "jaeger")
        try c.encodeOptional(argoCDApplication, "argoCDApplication")
        try c.encodeOptional(kubeconfig, "kubeconfig")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The URL with its port replaced by `port` when set, without a trailing `/`; nil without a URL.
    public var baseURL: String? {
        guard let url else { return nil }
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // A negative port, possible only in a file edited by hand, would make Foundation raise.
        if let port, port >= 0, var components = URLComponents(string: text), components.host != nil {
            components.port = port
            text = components.string ?? text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}

/// One value of the key `environmentOverrides`, under the name of the environment it changes: what a
/// sub project changes in an environment it inherits. A value replaces the parent's; nil keeps it
/// (docs/data.md › Environment override). `namespace` and `kubeconfig` are V3's additions.
public struct EnvironmentOverride: Codable, Sendable, Hashable {
    public var url: String?
    public var port: Int?
    public var allowInvalidCertificates: Bool?
    public var namespace: String?
    public var deployment: String?
    public var jaeger: String?
    public var argoCDApplication: String?
    public var kubeconfig: String?
    public var unknownKeys: YAMLMapping

    public init(url: String? = nil, port: Int? = nil, allowInvalidCertificates: Bool? = nil, namespace: String? = nil,
                deployment: String? = nil, jaeger: String? = nil, argoCDApplication: String? = nil, kubeconfig: String? = nil,
                unknownKeys: YAMLMapping = [:]) {
        self.url = url
        self.port = port
        self.allowInvalidCertificates = allowInvalidCertificates
        self.namespace = namespace
        self.deployment = deployment
        self.jaeger = jaeger
        self.argoCDApplication = argoCDApplication
        self.kubeconfig = kubeconfig
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["url", "port", "allowInvalidCertificates", "namespace", "deployment", "jaeger",
                                         "argoCDApplication", "kubeconfig"]

    /// The string keys are read trimmed, an empty value being null.
    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        url = ProjectRules.trimmedOrNil(try c.optional("url", String.self))
        port = try c.optional("port")
        allowInvalidCertificates = try c.optional("allowInvalidCertificates")
        namespace = ProjectRules.trimmedOrNil(try c.optional("namespace", String.self))
        deployment = ProjectRules.trimmedOrNil(try c.optional("deployment", String.self))
        jaeger = ProjectRules.trimmedOrNil(try c.optional("jaeger", String.self))
        argoCDApplication = ProjectRules.trimmedOrNil(try c.optional("argoCDApplication", String.self))
        kubeconfig = ProjectRules.trimmedOrNil(try c.optional("kubeconfig", String.self))
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    /// V2's six keys are written as V2 writes them, null included; V3's two only when set.
    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encodeOptional(url, "url")
        try c.encodeOptional(port, "port")
        try c.encodeOptional(allowInvalidCertificates, "allowInvalidCertificates")
        try c.encodeIfPresent(namespace, "namespace")
        try c.encodeOptional(deployment, "deployment")
        try c.encodeOptional(jaeger, "jaeger")
        try c.encodeOptional(argoCDApplication, "argoCDApplication")
        try c.encodeIfPresent(kubeconfig, "kubeconfig")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// True when the change replaces none of the parent's values.
    public var isEmpty: Bool {
        url == nil && port == nil && allowInvalidCertificates == nil && namespace == nil && deployment == nil && jaeger == nil
            && argoCDApplication == nil && kubeconfig == nil
    }

    /// The parent's environment with the values this change sets; its name and other fields stay.
    public func applied(to environment: EnvironmentEntry) -> EnvironmentEntry {
        var result = environment
        if let url { result.url = url }
        if let port { result.port = port }
        if let allowInvalidCertificates { result.allowInvalidCertificates = allowInvalidCertificates }
        if let namespace { result.namespace = namespace }
        if let deployment { result.deployment = deployment }
        if let jaeger { result.jaeger = jaeger }
        if let argoCDApplication { result.argoCDApplication = argoCDApplication }
        if let kubeconfig { result.kubeconfig = kubeconfig }
        return result
    }

    /// Writes a map of changes with its names in Unicode code point order, so that a file written
    /// twice is the same.
    struct SortedMap: Encodable {
        let overrides: [String: EnvironmentOverride]

        init(_ overrides: [String: EnvironmentOverride]) {
            self.overrides = overrides
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            for name in overrides.keys.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
                try container.encode(overrides[name]!, forKey: AnyKey(name))
            }
        }
    }
}
