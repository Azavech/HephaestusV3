import ExternalTools
import Foundation
import MCPKit

/// The boxes and arrows of a namespace, from its Deployments and their sources on GitHub (docs/data.md ›
/// Clusters › Service graph), V2's rules.
public struct ServiceGraph: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case service, database, bucket
    }

    public struct Box: Sendable, Hashable {
        public let id: String
        public let kind: Kind
        /// For a service: its Deployment's replicas and ready replicas.
        public var replicas = 0
        public var ready = 0
        /// For a service: `github.com/<owner>/<repository>` and the deployed commit.
        public var repository: String?
        public var commit: String?
    }

    public struct Arrow: Sendable, Hashable {
        public let from: String
        public let to: String
    }

    public var boxes: [Box]
    public var arrows: [Arrow]
    /// Why a service's sources couldn't be read: `The sources of <deployment> cannot be read: <reason>.`
    public var problems: [String]

    /// `ghcr.io/<owner>/<repository>:sha-<commit>`, the first container image of that form; nil otherwise.
    public static func image(_ image: String) -> (owner: String, repository: String, commit: String)? {
        guard let match = image.wholeMatch(of: /ghcr\.io\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+):sha-([0-9a-fA-F]{7,40})/) else { return nil }
        return (String(match.output.1), String(match.output.2), String(match.output.3))
    }

    /// The module paths a `go.mod` requires, in its `require` lines and blocks.
    public static func requiredModules(_ goMod: String) -> [String] {
        var modules: [String] = []
        var inBlock = false
        for raw in goMod.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "//", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if inBlock {
                if line == ")" { inBlock = false; continue }
                if let module = line.split(separator: " ").first, !module.isEmpty { modules.append(String(module)) }
            } else if line == "require (" || line.hasPrefix("require (") {
                inBlock = true
            } else if line.hasPrefix("require ") {
                if let module = line.dropFirst("require ".count).split(separator: " ").first { modules.append(String(module)) }
            }
        }
        return modules
    }

    /// The scalars of a YAML file by dotted path, comments dropped, quotes removed (V2's values file reading).
    public static func values(_ yaml: String) -> [String: String] {
        var values: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = line.prefix { $0 == " " }.count
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            var value = String(trimmed[trimmed.index(after: colon)...])
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty { stack.append((indent, key)) } else { values[path] = value }
        }
        return values
    }

    static func isTrue(_ value: String?) -> Bool {
        ["true", "yes", "on"].contains(value?.lowercased() ?? "")
    }

    /// True when a module path ends with `/yc-shared/<name>` or a major version of it.
    static func requires(_ modules: [String], _ name: String) -> Bool {
        modules.contains { $0.range(of: #"/yc-shared/\#(name)(/v[0-9]+)?$"#, options: .regularExpression) != nil }
    }

    /// Builds the graph: a box per Deployment with a ghcr image (not `yc-shared`), its Cluster and bucket from its
    /// sources, its arrows to the services whose repository's module it requires.
    public static func build(deployments: [JSONValue], sources: (_ owner: String, _ repository: String, _ commit: String) async -> (goMod: String, values: String, problem: String?)) async -> ServiceGraph {
        struct Service { var box: Box; var modules: [String]; var values: [String: String] }
        var services: [Service] = []
        var problems: [String] = []
        for deployment in deployments {
            guard let name = deployment["metadata"]?["name"]?.stringValue else { continue }
            let images = (deployment["spec"]?["template"]?["spec"]?["containers"]?.arrayValue ?? []).compactMap { $0["image"]?.stringValue }
            guard let image = images.lazy.compactMap(Self.image).first, image.repository != "yc-shared" else { continue }
            let read = await sources(image.owner, image.repository, image.commit)
            if let problem = read.problem { problems.append("The sources of \(name) cannot be read: \(problem).") }
            var box = Box(id: name, kind: .service)
            box.replicas = deployment["spec"]?["replicas"]?.intValue ?? 0
            box.ready = deployment["status"]?["readyReplicas"]?.intValue ?? 0
            box.repository = "github.com/\(image.owner)/\(image.repository)"
            box.commit = image.commit
            services.append(Service(box: box, modules: requiredModules(read.goMod), values: values(read.values)))
        }
        services.sort { $0.box.id < $1.box.id }
        var boxes = services.map(\.box)
        var arrows: [Arrow] = []
        for service in services {
            for other in services where other.box.id != service.box.id {
                guard let repository = other.box.repository else { continue }
                if service.modules.contains(where: { $0 == repository || $0.hasPrefix(repository + "/") }) {
                    arrows.append(Arrow(from: service.box.id, to: other.box.id))
                }
            }
            if isTrue(service.values["postgres.enabled"]) || requires(service.modules, "gormpg") {
                boxes.append(Box(id: "\(service.box.id)-postgres", kind: .database))
                arrows.append(Arrow(from: service.box.id, to: "\(service.box.id)-postgres"))
            }
            if isTrue(service.values["s3.enabled"]) || requires(service.modules, "s3store") {
                boxes.append(Box(id: "\(service.box.id)-bucket", kind: .bucket))
                arrows.append(Arrow(from: service.box.id, to: "\(service.box.id)-bucket"))
            }
        }
        let order = Dictionary(boxes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        boxes = boxes.filter { $0.kind == .service } + boxes.filter { $0.kind != .service }.sorted { order[$0.id]! < order[$1.id]! }
        return ServiceGraph(boxes: boxes, arrows: arrows, problems: problems)
    }
}
