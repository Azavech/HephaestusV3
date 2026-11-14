import ExternalTools
import FileStorage
import Foundation

/// The projects of this Mac: it loads them from the registry and their folders, applies V2's rules to every
/// change, and gives a new `ProjectSnapshot` after each one (docs/data.md › Loading, › Changes).
///
/// An actor: every read and write of the files goes through it, one at a time. The windows never call it
/// directly; they talk to `ProjectSession`.
public actor ProjectLibrary {
    public nonisolated let dataFolder: DataFolder
    public nonisolated let ownWrites: OwnWrites
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date

    private var registry = RegistryFile()
    private var choices = CurrentEnvironmentsFile()
    private var loaded: [String: Node] = [:]
    private var order: [String] = []
    private var issues: [ProjectIssue] = []
    private var fileIssues: [String: String] = [:]
    private var revision = 0
    private var last = ProjectSnapshot.empty
    private var tools = Tools.notLookedUp
    /// The `origin` remote of each loaded folder that has one, by folder.
    private var origins: [String: String] = [:]
    /// What `ssh -G` gave for each SSH host alias of an origin.
    private var hostNames: [String: String] = [:]

    private struct Node: Sendable {
        var root: String
        var file: ProjectFile
        var parentID: String?
        var depth: Int
        var childIDs: [String]
    }

    public init(dataFolder: DataFolder, runner: any ProcessRunning, ownWrites: OwnWrites = OwnWrites(),
                now: @escaping @Sendable () -> Date = { ISODate.now() }) {
        self.dataFolder = dataFolder
        self.runner = runner
        self.ownWrites = ownWrites
        self.now = now
    }

    // MARK: Loading

    /// Reads `registry.yml` and `current-environments.yml`, then loads every project (docs/data.md ›
    /// Loading). A missing registry is created empty; an invalid data folder file is set aside as
    /// `<file>.invalid` and the app starts from its default.
    public func load() -> ProjectSnapshot {
        registry = readDataFile(RegistryFile.self, at: dataFolder.registryFile, default: RegistryFile(), createsMissing: true)
        choices = readDataFile(CurrentEnvironmentsFile.self, at: dataFolder.currentEnvironmentsFile,
                               default: CurrentEnvironmentsFile(), createsMissing: false)
        rebuild()
        return publish(force: true)
    }

    /// The folders to watch: the data folder and the folder of each top-level project.
    public var watchedFolders: Set<String> {
        var folders: Set<String> = [dataFolder.url.path]
        for id in order where loaded[id]?.parentID == nil {
            if let root = loaded[id]?.root { folders.insert(root) }
        }
        for issue in issues where issue.source == .registry {
            folders.insert(issue.path)
        }
        return folders
    }

    /// Applies a batch of file events: reloads what they may have changed and returns the new snapshot,
    /// or nil when nothing changed (docs/data.md › Outside changes).
    public func handle(_ events: [FileEvent]) async -> ProjectSnapshot? {
        let roots = knownRoots()
        let relevant = events.filter { Self.isRelevant($0, roots: roots) }
        guard !relevant.isEmpty else { return nil }
        if relevant.contains(where: { $0.path.hasSuffix("/registry.yml") || $0.kind.contains(.mustRescan) }),
           let read = try? YAMLFile.read(RegistryFile.self, at: dataFolder.registryFile) {
            registry = read
        }
        if relevant.contains(where: { $0.path.hasSuffix("/current-environments.yml") || $0.kind.contains(.mustRescan) }),
           let read = try? YAMLFile.read(CurrentEnvironmentsFile.self, at: dataFolder.currentEnvironmentsFile) {
            choices = read
        }
        rebuild()
        if relevant.contains(where: { $0.path.hasSuffix("/.git/config") || $0.path.hasSuffix("/.git") }) {
            await readOrigins()
        }
        return publishIfChanged()
    }

    /// Whether an event may change what the library loaded: a project file, a `.hephaestus` folder, a data
    /// folder file, a git configuration, a project's folder (or one holding it) created, moved or removed,
    /// or anything when events were dropped. `roots` are the folders of the loaded projects and of the
    /// entries that didn't load, as written and with symbolic links resolved.
    static func isRelevant(_ event: FileEvent, roots: Set<String>) -> Bool {
        if event.kind.contains(.mustRescan) || event.kind.contains(.rootChanged) { return true }
        guard event.changesMoreThanMetadata else { return false }
        let path = event.path
        if path.hasSuffix("/.hephaestus/project.yml") || path.hasSuffix("/.hephaestus")
            || path.hasSuffix("/registry.yml") || path.hasSuffix("/current-environments.yml")
            || path.hasSuffix("/.git/config") || path.hasSuffix("/.git") {
            return true
        }
        return roots.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    private func knownRoots() -> Set<String> {
        let paths = loaded.values.map(\.root) + issues.map(\.path)
        return Set(paths.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] })
    }

    // MARK: Tools and origins

    /// The tools found, for the origins and the host aliases.
    public func setTools(_ tools: Tools) {
        self.tools = tools
    }

    /// Reads the `origin` of every loaded folder, then the host name of each SSH alias they use, and returns
    /// the new snapshot when a GitHub page changed (docs/data.md › GitHub page).
    public func refreshOrigins() async -> ProjectSnapshot? {
        await readOrigins()
        return publishIfChanged()
    }

    private func readOrigins() async {
        guard let git = Git(tools, runner: runner) else { return }
        var read: [String: String] = [:]
        for root in Set(loaded.values.map(\.root)) {
            if let url = await git.originURL(in: root) {
                read[root] = url
            }
        }
        origins = read
        guard let ssh = SSH(tools, runner: runner) else { return }
        for (root, url) in read {
            guard let remote = GitRemote(remoteURL: url), remote.isSSH, !remote.isGitHubHost, hostNames[remote.host] == nil else { continue }
            hostNames[remote.host] = await ssh.hostName(alias: remote.host, in: root) ?? ""
        }
    }

    // MARK: Changes

    /// Creates a project in a folder and adds it: to its parent's `subprojects` (the given parent, else the
    /// innermost loaded project whose folder holds it), or to the registry (docs/data.md › Changes).
    public func create(_ request: NewProject) throws(ProjectError) -> (id: String, snapshot: ProjectSnapshot) {
        let name = try rule { () throws(ProjectRuleError) in try ProjectRules.name(request.name, field: "name") }
        let identifier = request.identifier.trimmingCharacters(in: .whitespaces).uppercased()
        guard ProjectRules.isIdentifier(identifier) else { throw .rule(.identifierFormat) }
        if let other = loaded[identifier] { throw .rule(.identifierInUse(identifier: identifier, by: other.file.name)) }
        let root = Self.standardized(request.folder)
        let parent: Node?
        if let parentID = request.parentID {
            guard let node = loaded[parentID] else { throw .projectNotLoaded(parentID) }
            guard Self.isStrictlyInside(root, node.root) else { throw .notInsideParent(parentName: node.file.name) }
            parent = node
        } else {
            parent = innermostProject(containing: root)
        }
        var isFolder: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root, isDirectory: &isFolder) {
            guard request.createsFolder else { throw .folderMissing(path: root) }
            do {
                try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            } catch {
                throw .storage(.writeFailed(path: root, reason: (error as NSError).localizedDescription))
            }
        } else if !isFolder.boolValue {
            throw .folderMissing(path: root)
        }
        let folder = ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true))
        guard !folder.isProject else { throw .alreadyContainsProject(path: root) }
        let file = ProjectFile(id: identifier, name: name, created: now(), type: request.kind)
        try storage { () throws(StorageError) in
            try YAMLFile.write(file, to: folder.projectFile, ownWrites: ownWrites)
            try ensureGitignore(folder)
        }
        try register(root: root, under: parent)
        rebuild()
        return (identifier, publish())
    }

    /// Adds an existing project's folder: to the innermost loaded project whose folder holds it, else to the
    /// registry; its sub projects load with it. A folder that is already loaded gives its project.
    public func open(folder path: String) throws(ProjectError) -> (id: String, snapshot: ProjectSnapshot) {
        let root = Self.standardized(path)
        if let node = loaded.values.first(where: { $0.root == root }) {
            return (node.file.id, publish())
        }
        let folder = ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true))
        guard folder.isProject else { throw .noProject(path: root) }
        let file = try storage { () throws(StorageError) in try YAMLFile.read(ProjectFile.self, at: folder.projectFile) }
        if let other = loaded[file.id] { throw .rule(.identifierInUse(identifier: file.id, by: other.file.name)) }
        try storage { () throws(StorageError) in try ensureGitignore(folder) }
        let parent = innermostProject(containing: root)
        // Registry entries that the opened project lists as its descendants load under it from now on.
        let descendants = Self.descendantRoots(of: root)
        if parent == nil, registry.projects.contains(where: { descendants.contains(Self.standardized($0)) }) {
            registry.projects.removeAll { descendants.contains(Self.standardized($0)) }
        }
        try register(root: root, under: parent)
        rebuild()
        return (file.id, publish())
    }

    /// Changes the project's file; only the values `change` sets, each checked with its write rules.
    public func update(_ id: String, _ change: ProjectChange) throws(ProjectError) -> ProjectSnapshot {
        guard let node = loaded[id] else { throw .projectNotLoaded(id) }
        var file = node.file
        do throws(ProjectRuleError) {
            if let name = change.name { file.name = try ProjectRules.name(name, field: "name") }
            if let kind = change.kind { file.type = kind }
            if let color = change.color {
                file.color = try color.map { text throws(ProjectRuleError) in
                    guard let color = ProjectColor.normalized(text.trimmingCharacters(in: .whitespaces)) else { throw .color }
                    return color
                }
            }
            if let icon = change.icon { file.icon = ProjectRules.trimmedOrNil(icon) }
            if let docsPath = change.docsPath {
                let trimmed = docsPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard ProjectRules.isRelativePath(trimmed), trimmed != ".hephaestus", !trimmed.hasPrefix(".hephaestus/") else {
                    throw .relativePath(field: "docsPath")
                }
                file.docsPath = trimmed
            }
            if let page = change.githubPage {
                file.githubPage = try ProjectRules.trimmedOrNil(page).map { text throws(ProjectRuleError) in try GitHubPage.validated(text) }
            }
            if let useParentSettings = change.useParentSettings { file.useParentSettings = useParentSettings }
            if let graphEnabled = change.graphEnabled { file.graphEnabled = graphEnabled }
            if let environments = change.environments {
                let inheritedNames = Set(resolved(id, file: file).inheritedEnvironments.map(\.name))
                file.environments = try Self.checked(environments, keeping: node.file.environments, inheritedNames: inheritedNames)
            }
            if let overrides = change.environmentOverrides {
                file.environmentOverrides = try Self.checked(overrides, keeping: node.file.environmentOverrides)
            }
        } catch {
            throw .rule(error)
        }
        guard file != node.file else { return publish() }
        let before = allResolved()
        try storage { () throws(StorageError) in try YAMLFile.write(file, to: Self.projectFile(node.root), ownWrites: ownWrites) }
        loaded[id]?.file = file
        let renamed = change.environments.map { Self.renamedEnvironments(from: node.file.environments, to: $0) } ?? [:]
        try keepCurrentEnvironments(since: before, renamed: renamed)
        return publish()
    }

    /// Removes a project and its sub projects from the app: their entry leaves the registry or the parent's
    /// `subprojects`, and their chosen environments are forgotten. No file of theirs changes.
    public func remove(_ id: String) throws(ProjectError) -> ProjectSnapshot {
        guard let node = loaded[id] else { throw .projectNotLoaded(id) }
        let family = Set(familyIDs(of: id))
        if let parentID = node.parentID, var parent = loaded[parentID]?.file, let parentRoot = loaded[parentID]?.root {
            parent.subprojects.removeAll { Self.standardized(parentRoot + "/" + $0) == node.root }
            try storage { () throws(StorageError) in try YAMLFile.write(parent, to: Self.projectFile(parentRoot), ownWrites: ownWrites) }
        } else {
            registry.projects.removeAll { Self.standardized($0) == node.root }
            try storage { () throws(StorageError) in try YAMLFile.write(registry, to: dataFolder.registryFile, ownWrites: ownWrites) }
        }
        var kept = choices
        for projectID in family { kept.projects[projectID] = nil }
        try storeChoices(kept)
        rebuild()
        return publish()
    }

    /// Chooses the environment the user works in for a service.
    public func setCurrentEnvironment(_ id: String, to name: String) throws(ProjectError) -> ProjectSnapshot {
        guard loaded[id] != nil else { throw .projectNotLoaded(id) }
        guard resolved(id).environments.contains(where: { $0.name == name }) else { throw .unknownEnvironment(name) }
        var kept = choices
        kept.projects[id] = name
        try storeChoices(kept)
        return publish()
    }

    // MARK: Building the tree

    /// Loads the registry's projects, each followed by its sub projects, depth first; keeps the version
    /// loaded before of a project whose file became invalid.
    private func rebuild() {
        let previous = loaded
        loaded = [:]
        order = []
        issues = []
        fileIssues = [:]
        var visited: Set<String> = []

        func issue(_ path: String, _ source: ProjectIssue.Source, _ reason: ProjectIssue.Reason) {
            issues.append(ProjectIssue(path: path, source: source, reason: reason))
        }

        func loadTree(root: String, source: ProjectIssue.Source, parentID: String?, depth: Int) -> String? {
            guard visited.insert(root).inserted else { return nil }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder), isFolder.boolValue else {
                issue(root, source, .folderMissing)
                return nil
            }
            let folder = ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true))
            AtomicFile.removeLeftoverTemporaryFiles(in: folder.dataFolder)
            let earlier = previous.values.first { $0.root == root }
            var file: ProjectFile
            do {
                file = try YAMLFile.read(ProjectFile.self, at: folder.projectFile)
                if let earlier, earlier.file.id != file.id {
                    file = earlier.file
                    fileIssues[file.id] = "id: the identifier can't change"
                }
            } catch {
                if case .invalidFile(_, let reason) = error, let earlier {
                    file = earlier.file
                    fileIssues[file.id] = reason
                } else if case .invalidFile(_, let reason) = error {
                    issue(root, source, .invalidFile(reason: reason))
                    return nil
                } else {
                    issue(root, source, .fileMissing)
                    return nil
                }
            }
            if let other = loaded[file.id] {
                issue(root, source, .identifierInUse(identifier: file.id, by: other.file.name))
                return nil
            }
            loaded[file.id] = Node(root: root, file: file, parentID: parentID, depth: depth, childIDs: [])
            order.append(file.id)
            var children: [String] = []
            for entry in file.subprojects {
                guard ProjectRules.isRelativePath(entry) else {
                    issue(root + "/" + entry, .subproject(parentID: file.id, entry: entry), .invalidEntry)
                    continue
                }
                let childRoot = Self.standardized(root + "/" + entry)
                if let child = loadTree(root: childRoot, source: .subproject(parentID: file.id, entry: entry), parentID: file.id,
                                        depth: depth + 1) {
                    children.append(child)
                }
            }
            loaded[file.id]?.childIDs = children
            return file.id
        }

        for entry in registry.projects {
            guard ProjectRules.isAbsolutePath(entry) else {
                issue(entry, .registry, .invalidEntry)
                continue
            }
            _ = loadTree(root: Self.standardized(entry), source: .registry, parentID: nil, depth: 0)
        }
    }

    /// A new snapshot when something changed since the last one; nil otherwise.
    private func publishIfChanged() -> ProjectSnapshot? {
        let before = last.revision
        let snapshot = publish()
        return snapshot.revision == before ? nil : snapshot
    }

    /// The current snapshot; a new revision when it differs from the last one (or when `force`).
    private func publish(force: Bool = false) -> ProjectSnapshot {
        let projects = order.compactMap { id -> LoadedProject? in
            guard let node = loaded[id] else { return nil }
            return LoadedProject(root: node.root, file: node.file, parentID: node.parentID, depth: node.depth,
                                 childIDs: node.childIDs, resolved: resolved(id), fileIssue: fileIssues[id])
        }
        var snapshot = ProjectSnapshot(revision: last.revision, projects: projects, issues: issues)
        if force || snapshot != last {
            revision += 1
            snapshot.revision = revision
            last = snapshot
        }
        return last
    }

    // MARK: Resolution

    private func resolved(_ id: String, file override: ProjectFile? = nil) -> ResolvedSettings {
        var settings = ResolvedSettings()
        guard let node = loaded[id] else { return settings }
        let (environments, inherited) = environments(of: id, file: override)
        settings.environments = environments
        settings.inheritedEnvironments = inherited
        if let chosen = choices.projects[id], environments.contains(where: { $0.name == chosen }) {
            settings.currentEnvironment = chosen
        } else {
            settings.currentEnvironment = environments.first?.name
        }
        settings.originGithubPage = originPage(of: node.root)
        settings.githubPage = githubPage(of: id)
        settings.graphEnabled = graphEnabled(of: id)
        return settings
    }

    private func allResolved() -> [String: ResolvedSettings] {
        Dictionary(uniqueKeysWithValues: order.map { ($0, resolved($0)) })
    }

    /// The environments as they apply, and those inherited: none for a project that isn't a service; for a
    /// sub project that uses its parent's settings, the parent's (as the parent resolves them) with its
    /// changes, then its own whose names they don't have.
    private func environments(of id: String, file override: ProjectFile? = nil,
                              visited: Set<String> = []) -> (environments: [EnvironmentEntry], inherited: [EnvironmentEntry]) {
        guard let node = loaded[id], !visited.contains(id) else { return ([], []) }
        let file = override ?? node.file
        guard file.type == .goService else { return ([], []) }
        var inherited: [EnvironmentEntry] = []
        if file.useParentSettings, let parentID = node.parentID, loaded[parentID] != nil {
            inherited = environments(of: parentID, visited: visited.union([id])).environments
        }
        let names = Set(inherited.map(\.name))
        let environments = inherited.map { file.environmentOverrides[$0.name]?.applied(to: $0) ?? $0 }
            + file.environments.filter { !names.contains($0.name) }
        return (environments, inherited)
    }

    /// The parent's page while the project uses its parent's settings, else its typed page, else its
    /// origin's.
    private func githubPage(of id: String) -> String? {
        var current = id
        var visited: Set<String> = []
        while let node = loaded[current], visited.insert(current).inserted {
            guard node.file.useParentSettings, let parentID = node.parentID, loaded[parentID] != nil else {
                return node.file.githubPage ?? originPage(of: node.root)
            }
            current = parentID
        }
        return nil
    }

    private func originPage(of root: String) -> String? {
        guard let url = origins[root], let remote = GitRemote(remoteURL: url) else { return nil }
        let hostName = hostNames[remote.host].flatMap { $0.isEmpty ? nil : $0 }
        return remote.gitHubPage(resolvedHostName: hostName)
    }

    /// Never for a project that isn't a service; the parent's while the project uses its parent's settings.
    private func graphEnabled(of id: String) -> Bool {
        var current = id
        var visited: Set<String> = []
        while let node = loaded[current], visited.insert(current).inserted {
            guard node.file.type == .goService else { return false }
            guard node.file.useParentSettings, let parentID = node.parentID, loaded[parentID] != nil else {
                return node.file.graphEnabled
            }
            current = parentID
        }
        return false
    }

    // MARK: Current environments

    /// After a change: a chosen environment that the change renamed stays chosen under its new name; one a
    /// project no longer has is forgotten, so that its first environment is current.
    private func keepCurrentEnvironments(since before: [String: ResolvedSettings], renamed: [String: String]) throws(ProjectError) {
        var kept = choices
        for (id, name) in choices.projects {
            guard let old = before[id], loaded[id] != nil else { continue }
            let now = resolved(id)
            guard now.environments != old.environments else { continue }
            let names = Set(now.environments.map(\.name))
            if let newName = renamed[name], names.contains(newName) {
                kept.projects[id] = newName
            } else if !names.contains(name) {
                kept.projects[id] = nil
            }
        }
        try storeChoices(kept)
    }

    private func storeChoices(_ kept: CurrentEnvironmentsFile) throws(ProjectError) {
        guard kept != choices else { return }
        try storage { () throws(StorageError) in
            try YAMLFile.write(kept, to: dataFolder.currentEnvironmentsFile, ownWrites: ownWrites)
        }
        choices = kept
    }

    /// The environments a change of a list renames, old name to new: those whose name changed at the same
    /// position, the list keeping its length.
    static func renamedEnvironments(from old: [EnvironmentEntry], to new: [EnvironmentEntry]) -> [String: String] {
        guard old.count == new.count else { return [:] }
        var renamed: [String: String] = [:]
        for (before, after) in zip(old, new) where before.name != after.name {
            renamed[before.name] = after.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return renamed
    }

    // MARK: Write rules of environments

    /// Each environment the list adds or changes keeps the write rules, in order, then has a name no other
    /// has, inherited ones included. An environment equal to a stored one is written back as it is.
    static func checked(_ environments: [EnvironmentEntry], keeping stored: [EnvironmentEntry],
                        inheritedNames: Set<String>) throws(ProjectRuleError) -> [EnvironmentEntry] {
        var list: [EnvironmentEntry] = []
        var kept: [Bool] = []
        for (index, environment) in environments.enumerated() {
            if stored.contains(environment) {
                list.append(environment)
                kept.append(true)
                continue
            }
            let field = "environments[\(index)]"
            var copy = environment
            copy.name = try ProjectRules.name(environment.name, field: field + ".name")
            copy.url = try ProjectRules.environmentURL(environment.url, field: field + ".url")
            if let port = environment.port { copy.port = try ProjectRules.port(port, field: field + ".port") }
            copy.namespace = try ProjectRules.line(environment.namespace, field: field + ".namespace")
            copy.deployment = try ProjectRules.line(environment.deployment, field: field + ".deployment")
            copy.jaeger = try ProjectRules.jaeger(environment.jaeger, field: field + ".jaeger")
            copy.argoCDApplication = try ProjectRules.argoCDApplication(environment.argoCDApplication, field: field + ".argoCDApplication")
            copy.kubeconfig = try ProjectRules.kubeconfig(environment.kubeconfig, field: field + ".kubeconfig")
            list.append(copy)
            kept.append(false)
        }
        for (index, environment) in list.enumerated() where !kept[index] {
            let clash = inheritedNames.contains(environment.name)
                || list.indices.contains { $0 != index && list[$0].name == environment.name }
            if clash { throw .duplicateEnvironment(environment.name) }
        }
        return list
    }

    /// Each change the map adds or changes keeps the write rules; one equal to the stored change of its name
    /// is written back as it is. A change that sets no value is dropped.
    static func checked(_ overrides: [String: EnvironmentOverride],
                        keeping stored: [String: EnvironmentOverride]) throws(ProjectRuleError) -> [String: EnvironmentOverride] {
        var result: [String: EnvironmentOverride] = [:]
        for name in overrides.keys.sorted() {
            let change = overrides[name]!
            if stored[name] == change {
                result[name] = change
                continue
            }
            let field = "environmentOverrides[\(name)]"
            var copy = change
            copy.url = try ProjectRules.environmentURL(change.url, field: field + ".url")
            if let port = change.port { copy.port = try ProjectRules.port(port, field: field + ".port") }
            copy.deployment = try ProjectRules.line(change.deployment, field: field + ".deployment")
            copy.jaeger = try ProjectRules.jaeger(change.jaeger, field: field + ".jaeger")
            copy.argoCDApplication = try ProjectRules.argoCDApplication(change.argoCDApplication, field: field + ".argoCDApplication")
            if !copy.isEmpty || !copy.unknownKeys.isEmpty {
                result[name] = copy
            }
        }
        return result
    }

    // MARK: Helpers

    private func register(root: String, under parent: Node?) throws(ProjectError) {
        if let parent, var file = loaded[parent.file.id]?.file {
            let entry = String(root.dropFirst(parent.root.count + 1))
            if !file.subprojects.contains(where: { Self.standardized(parent.root + "/" + $0) == root }) {
                file.subprojects.append(entry)
            }
            try storage { () throws(StorageError) in try YAMLFile.write(file, to: Self.projectFile(parent.root), ownWrites: ownWrites) }
            loaded[parent.file.id]?.file = file
        } else {
            if !registry.projects.contains(where: { Self.standardized($0) == root }) {
                registry.projects.append(root)
            }
            try storage { () throws(StorageError) in try YAMLFile.write(registry, to: dataFolder.registryFile, ownWrites: ownWrites) }
        }
    }

    private func ensureGitignore(_ folder: ProjectFolder) throws(StorageError) {
        do {
            try folder.ensureGitignore(ownWrites: ownWrites)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: folder.gitignoreFile.path, reason: String(describing: error))
        }
    }

    /// The innermost loaded project whose folder strictly holds `root`.
    private func innermostProject(containing root: String) -> Node? {
        loaded.values.filter { Self.isStrictlyInside(root, $0.root) }.max { $0.root.count < $1.root.count }
    }

    private func familyIDs(of id: String) -> [String] {
        [id] + (loaded[id]?.childIDs ?? []).flatMap { familyIDs(of: $0) }
    }

    /// A data folder file: an invalid one is set aside as `<file>.invalid`, replacing an older copy; a
    /// missing or invalid one is recreated with its default when `createsMissing`; an unreadable one stays.
    private func readDataFile<T: Codable>(_ type: T.Type, at url: URL, default value: T, createsMissing: Bool) -> T {
        do {
            return try YAMLFile.read(type, at: url)
        } catch {
            switch error {
            case .invalidFile:
                let aside = dataFolder.invalidCopy(of: url)
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                if createsMissing { _ = try? YAMLFile.write(value, to: url, ownWrites: ownWrites) }
            case .readFailed where YAMLFile.isMissing(url):
                if createsMissing { _ = try? YAMLFile.write(value, to: url, ownWrites: ownWrites) }
            default:
                break
            }
            return value
        }
    }

    @discardableResult
    private func rule<T>(_ body: () throws(ProjectRuleError) -> T) throws(ProjectError) -> T {
        do { return try body() } catch { throw .rule(error) }
    }

    @discardableResult
    private func storage<T>(_ body: () throws(StorageError) -> T) throws(ProjectError) -> T {
        do { return try body() } catch { throw .storage(error) }
    }

    static func projectFile(_ root: String) -> URL {
        ProjectFolder(root: URL(fileURLWithPath: root, isDirectory: true)).projectFile
    }

    /// An absolute path without `.` and `..` components or a trailing `/`; symbolic links are kept.
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func isStrictlyInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder == "/" ? "/" : folder + "/") && path != folder
    }

    /// The folders a project's file lists as its descendants, read from disk; unreadable files are skipped.
    static func descendantRoots(of root: String) -> Set<String> {
        var result: Set<String> = []
        var pending = [root]
        while let current = pending.popLast() {
            guard let file = try? YAMLFile.read(ProjectFile.self, at: projectFile(current)) else { continue }
            for entry in file.subprojects where ProjectRules.isRelativePath(entry) {
                let child = standardized(current + "/" + entry)
                if result.insert(child).inserted { pending.append(child) }
            }
        }
        return result
    }
}

/// What New Project asks for (docs/data.md › Changes).
public struct NewProject: Sendable, Hashable {
    public var name: String
    /// As typed; it is uppercased.
    public var identifier: String
    public var kind: ProjectKind
    /// The project's folder, absolute.
    public var folder: String
    /// Whether the folder is created when it doesn't exist; otherwise it must.
    public var createsFolder: Bool
    /// The parent; nil adds the project to the innermost loaded project whose folder holds it, else to the
    /// registry.
    public var parentID: String?

    public init(name: String, identifier: String, kind: ProjectKind = .none, folder: String, createsFolder: Bool,
                parentID: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.kind = kind
        self.folder = folder
        self.createsFolder = createsFolder
        self.parentID = parentID
    }
}

/// A change to a project's file: each value that is set replaces the stored one; `.some(nil)` removes an
/// optional value.
public struct ProjectChange: Sendable, Hashable {
    public var name: String?
    public var kind: ProjectKind?
    public var color: String??
    public var icon: String??
    public var docsPath: String?
    public var githubPage: String??
    public var useParentSettings: Bool?
    public var graphEnabled: Bool?
    /// The whole list of the project's own environments, with the change applied.
    public var environments: [EnvironmentEntry]?
    /// All the changes to inherited environments, with the change applied.
    public var environmentOverrides: [String: EnvironmentOverride]?

    public init(name: String? = nil, kind: ProjectKind? = nil, color: String?? = nil, icon: String?? = nil,
                docsPath: String? = nil, githubPage: String?? = nil, useParentSettings: Bool? = nil, graphEnabled: Bool? = nil,
                environments: [EnvironmentEntry]? = nil, environmentOverrides: [String: EnvironmentOverride]? = nil) {
        self.name = name
        self.kind = kind
        self.color = color
        self.icon = icon
        self.docsPath = docsPath
        self.githubPage = githubPage
        self.useParentSettings = useParentSettings
        self.graphEnabled = graphEnabled
        self.environments = environments
        self.environmentOverrides = environmentOverrides
    }
}
