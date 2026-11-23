import AppKit
import ExternalTools
import FileStorage
import Foundation
import Observation
import ProjectData
import ToolsFoundation

/// What Project Settings needs from the project data; `ProjectSession` in the app, a fake in tests.
@MainActor
protocol ProjectSettingsBackend: AnyObject {
    var snapshot: ProjectSnapshot { get }
    /// kubectl with the tools found; nil without it.
    var kubectl: Kubectl? { get }
    /// Whether the tools were looked up: until then `kubectl` is nil, whether kubectl is installed or not.
    var hasLookedUpTools: Bool { get }
    /// Returns once the tools were looked up the first time.
    func waitForTools() async
    func update(_ id: String, _ change: ProjectChange) async throws(ProjectError)
    /// This Mac's Kafka password of an environment of a project, from `secrets.json`.
    func kafkaPassword(project: String, environment: String) -> String?
    func setKafkaPassword(_ password: String?, project: String, environment: String) throws(StorageError)
}

extension ProjectSettingsBackend {
    func kafkaPassword(project: String, environment: String) -> String? { nil }
    func setKafkaPassword(_ password: String?, project: String, environment: String) throws(StorageError) {}
}

extension ProjectSession: ProjectSettingsBackend {
    func kafkaPassword(project: String, environment: String) -> String? {
        dataFolder?.kafkaPassword(project: project, environment: environment)
    }

    func setKafkaPassword(_ password: String?, project: String, environment: String) throws(StorageError) {
        guard let dataFolder else {
            throw .writeFailed(path: "secrets.json", reason: String(localized: "The app has no data folder.", bundle: #bundle))
        }
        try dataFolder.setKafkaPassword(password, project: project, environment: environment)
    }
}

/// A project's settings: each field applies on its own, as soon as it changes (a text field on Return or
/// when it loses the focus), with the rules of docs/ui/project-settings.md. A sub project takes each field it
/// leaves empty from its parent.
@Observable
final class ProjectSettingsModel {
    /// A field, for its message.
    enum Field: Hashable {
        case name, kind, tint, icon, docsPath, githubPage, graph
        case environments
        case environmentName, kubeconfig, namespace, deployment, jaeger, url, port, certificates
        case kafkaBrokers, kafkaUsername, kafkaPassword, kafkaTLS
    }

    /// Whether kubectl reaches the cluster of the selected environment's kubeconfig file.
    enum Connection: Equatable {
        case none
        case checking
        case connected
        case failed(String)
    }

    /// A section the form shows only when it applies, which `+` adds otherwise.
    enum OptionalSection: String, CaseIterable, Identifiable {
        case github, service, environments

        var id: String { rawValue }

        var title: String {
            switch self {
            case .github: String(localized: "GitHub", bundle: #bundle)
            case .service: String(localized: "Service", bundle: #bundle)
            case .environments: String(localized: "Environments", bundle: #bundle)
            }
        }

        var symbol: String {
            switch self {
            case .github: "link"
            case .service: "point.3.connected.trianglepath.dotted"
            case .environments: "server.rack"
            }
        }
    }

    let projectID: Project.ID
    @ObservationIgnored private let backend: any ProjectSettingsBackend
    /// The sections added with `+` while the window is open.
    private(set) var addedSections: Set<OptionalSection> = []

    // Text fields, as typed.
    var name = ""
    var icon = ""
    var docsPath = ""
    var githubPage = ""
    /// The messages under the fields, in red: a broken rule or a failed change.
    private(set) var messages: [Field: String] = [:]
    /// Whether the text fields hold the stored values: false until the project is loaded. Until then a text
    /// field applies nothing, so that an empty field never replaces a stored value.
    private(set) var hasValues = false

    // Environments.
    private(set) var selectedEnvironment: String?
    var environmentName = ""
    var kubeconfig = ""
    var namespace = ""
    var deployment = ""
    var jaeger = ""
    var url = ""
    var port = ""
    var kafkaBrokers = ""
    var kafkaUsername = ""
    /// This Mac's password, kept in `secrets.json`, never in the project's files.
    var kafkaPassword = ""
    private(set) var connection = Connection.none
    private(set) var namespaces: [String] = []
    private(set) var deployments: [String] = []

    init(projectID: Project.ID, backend: any ProjectSettingsBackend) {
        self.projectID = projectID
        self.backend = backend
        reload()
    }

    var project: LoadedProject? { backend.snapshot.project(projectID) }

    var parent: LoadedProject? { project?.parentID.flatMap { backend.snapshot.project($0) } }

    /// Whether the form shows the section: when the project's type uses it, when the project sets a value of
    /// its own in it, or once it is added with `+`. A value that only comes from the parent or the origin remote
    /// doesn't show it; once shown, the section shows that value greyed.
    func shows(_ section: OptionalSection) -> Bool {
        project != nil && (addedSections.contains(section) || typeUses(section) || hasOwnValues(section))
    }

    /// Whether the project's type uses the section, which then always shows: a service's Service and Environments.
    func typeUses(_ section: OptionalSection) -> Bool {
        project?.file.type == .goService && section != .github
    }

    /// Whether the project sets a value of its own in the section: a typed GitHub page; a graph setting; an
    /// environment or a change to an inherited one.
    func hasOwnValues(_ section: OptionalSection) -> Bool {
        guard let file = project?.file else { return false }
        switch section {
        case .github: return file.githubPage != nil
        case .service: return file.graphEnabled != nil
        case .environments: return !file.environments.isEmpty || !file.environmentOverrides.isEmpty
        }
    }

    /// The sections `+` offers: those the form doesn't show.
    var addableSections: [OptionalSection] { OptionalSection.allCases.filter { !shows($0) } }

    /// Whether the section has Remove: it shows, and the project's type doesn't use it.
    func canRemove(_ section: OptionalSection) -> Bool {
        shows(section) && !typeUses(section)
    }

    /// Shows the section until the window closes; it stays afterwards once one of its values is set.
    func add(_ section: OptionalSection) {
        addedSections.insert(section)
    }

    /// Removes the section: the project's own values in it are deleted from its file in one change, and the
    /// form stops showing it. A value from the parent or the origin remote still applies. Nothing happens for
    /// a section the type uses; when the change fails, the section stays with its message.
    func remove(_ section: OptionalSection) async {
        guard canRemove(section) else { return }
        if hasOwnValues(section) {
            let applied = switch section {
            case .github: await apply(.githubPage, ProjectChange(githubPage: .some(nil)))
            case .service: await apply(.graph, ProjectChange(graphEnabled: .some(nil)))
            case .environments: await apply(.environments, ProjectChange(environments: [], environmentOverrides: [:]))
            }
            guard applied else { return }
        }
        addedSections.remove(section)
    }

    /// Copies the stored values into the text fields, except `editing`, the field being edited.
    func reload(except editing: Field? = nil) {
        guard let file = project?.file else { return }
        hasValues = true
        if editing != .name { name = file.name }
        if editing != .icon { icon = file.icon ?? "" }
        if editing != .docsPath { docsPath = file.docsPath }
        if editing != .githubPage { githubPage = file.githubPage ?? "" }
        let names = environments.map(\.name)
        if selectedEnvironment == nil || !names.contains(selectedEnvironment!) {
            selectedEnvironment = project?.resolved.currentEnvironment ?? names.first
        }
        loadEnvironment(except: editing)
    }

    func message(_ field: Field) -> String? { messages[field] }

    // MARK: General

    func applyName() async {
        guard hasValues else { return reload() }
        guard name != project?.file.name else { return clear(.name) }
        await apply(.name, ProjectChange(name: name))
    }

    func applyKind(_ kind: Project.Kind) async {
        await apply(.kind, ProjectChange(kind: kind.stored))
    }

    func applyTint(_ tint: ProjectTint) async {
        await apply(.tint, ProjectChange(color: .some(tint.rawValue)))
    }

    /// An SF Symbol of this Mac, or none when the field is empty.
    func applyIcon() async {
        guard hasValues else { return reload() }
        let trimmed = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (project?.file.icon ?? "") else { return clear(.icon) }
        if !trimmed.isEmpty, NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) == nil {
            messages[.icon] = String(localized: "\(trimmed) is not an SF Symbol of this Mac.", bundle: #bundle)
            return
        }
        await apply(.icon, ProjectChange(icon: .some(trimmed.isEmpty ? nil : trimmed)))
    }

    /// A symbol chosen in the picker: it fills the field and applies at once.
    func pickIcon(_ name: String) async {
        icon = name
        await applyIcon()
    }

    func applyDocsPath() async {
        guard hasValues else { return reload() }
        guard docsPath != project?.file.docsPath else { return clear(.docsPath) }
        await apply(.docsPath, ProjectChange(docsPath: docsPath))
    }

    func applyGitHubPage() async {
        guard hasValues else { return reload() }
        let trimmed = githubPage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (project?.file.githubPage ?? "") else { return clear(.githubPage) }
        await apply(.githubPage, ProjectChange(githubPage: .some(trimmed.isEmpty ? nil : trimmed)))
    }

    /// On, off, or nil to take the parent's value.
    func applyGraph(_ value: Bool?) async {
        guard value != project?.file.graphEnabled else { return clear(.graph) }
        await apply(.graph, ProjectChange(graphEnabled: .some(value)))
    }

    /// The graph as it applies: the project's value, else its parent's.
    var graphEnabled: Bool { project?.resolved.graphEnabled ?? false }

    /// The project's own value: nil takes the parent's.
    var graphSetting: Bool? { project?.file.graphEnabled }

    /// The parent's graph as it applies.
    var inheritedGraphEnabled: Bool { project?.resolved.inheritedGraphEnabled ?? false }

    // MARK: Environments

    /// The environments as they apply: the inherited ones first, then the project's own.
    var environments: [EnvironmentEntry] { project?.resolved.environments ?? [] }

    var inheritedNames: Set<String> { Set(project?.resolved.inheritedEnvironments.map(\.name) ?? []) }

    var isInherited: Bool { selectedEnvironment.map(inheritedNames.contains) ?? false }

    /// The selected environment as it applies.
    var selected: EnvironmentEntry? { environments.first { $0.name == selectedEnvironment } }

    /// The parent's version of the selected inherited environment, without the project's change.
    var parentEnvironment: EnvironmentEntry? {
        project?.resolved.inheritedEnvironments.first { $0.name == selectedEnvironment }
    }

    func select(_ name: String?) async {
        await applyPendingEnvironmentFields()
        selectedEnvironment = name
        loadEnvironment()
    }

    /// `+`: an environment of its own named "New Environment", or the first free "New Environment <n>".
    func addEnvironment() async {
        guard let file = project?.file else { return }
        let taken = Set(environments.map(\.name))
        let base = String(localized: "New Environment", bundle: #bundle)
        var name = base
        var number = 2
        while taken.contains(name) {
            name = "\(base) \(number)"
            number += 1
        }
        await applyEnvironments(file.environments + [EnvironmentEntry(name: name)], field: .environments, selecting: name)
    }

    /// `−`: removes the selected environment of the project's own; the first environment is selected after.
    func removeEnvironment() async {
        guard let file = project?.file, let name = selectedEnvironment, !isInherited else { return }
        await applyEnvironments(file.environments.filter { $0.name != name }, field: .environments, selecting: nil)
    }

    /// The environment fields a text field edits.
    static let environmentFields: [Field] = [.environmentName, .kubeconfig, .namespace, .deployment, .jaeger, .url, .port,
                                             .kafkaBrokers, .kafkaUsername]

    /// Applies every environment field that differs from the stored value, in one change.
    func applyPendingEnvironmentFields() async {
        await applyEnvironmentFields(Self.environmentFields)
    }

    /// Applies one environment field when it differs from the stored value.
    func applyEnvironmentField(_ field: Field) async {
        await applyEnvironmentFields([field])
    }

    /// Applies environment fields from their text: an own environment changes in `environments`; an
    /// inherited one in `environmentOverrides`, where an empty field gives the parent's value.
    private func applyEnvironmentFields(_ fields: [Field]) async {
        guard hasValues else { return reload() }
        guard let file = project?.file, let name = selectedEnvironment, selected != nil else { return }
        var port: Int??
        if fields.contains(.port) {
            guard let parsed = parsedPort(.port) else { return }
            port = parsed
        }
        let field = fields.count == 1 ? fields[0] : .environments
        if isInherited {
            var change = file.environmentOverrides[name] ?? EnvironmentOverride()
            for field in fields {
                switch field {
                case .kubeconfig: change.kubeconfig = ProjectRules.trimmedOrNil(kubeconfig)
                case .namespace: change.namespace = ProjectRules.trimmedOrNil(namespace)
                case .deployment: change.deployment = ProjectRules.trimmedOrNil(deployment)
                case .jaeger: change.jaeger = ProjectRules.trimmedOrNil(jaeger)
                case .url: change.url = ProjectRules.trimmedOrNil(url)
                case .port: change.port = port ?? nil
                case .kafkaBrokers: change.kafkaBrokers = ProjectRules.trimmedOrNil(kafkaBrokers)
                case .kafkaUsername: change.kafkaUsername = ProjectRules.trimmedOrNil(kafkaUsername)
                default: break
                }
            }
            guard change != (file.environmentOverrides[name] ?? EnvironmentOverride()) else { return fields.forEach(clear) }
            var overrides = file.environmentOverrides
            overrides[name] = change.isEmpty && change.unknownKeys.isEmpty ? nil : change
            await apply(field, ProjectChange(environmentOverrides: overrides))
        } else {
            guard let index = file.environments.firstIndex(where: { $0.name == name }) else { return }
            var entry = file.environments[index]
            for field in fields {
                switch field {
                case .environmentName: entry.name = environmentName
                case .kubeconfig: entry.kubeconfig = ProjectRules.trimmedOrNil(kubeconfig)
                case .namespace: entry.namespace = ProjectRules.trimmedOrNil(namespace)
                case .deployment: entry.deployment = ProjectRules.trimmedOrNil(deployment)
                case .jaeger: entry.jaeger = ProjectRules.trimmedOrNil(jaeger)
                case .url: entry.url = ProjectRules.trimmedOrNil(url)
                case .port: entry.port = port ?? nil
                case .kafkaBrokers: entry.kafkaBrokers = ProjectRules.trimmedOrNil(kafkaBrokers)
                case .kafkaUsername: entry.kafkaUsername = ProjectRules.trimmedOrNil(kafkaUsername)
                default: break
                }
            }
            guard entry != file.environments[index] else { return fields.forEach(clear) }
            var list = file.environments
            list[index] = entry
            let newName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            await applyEnvironments(list, field: field, selecting: newName)
        }
    }

    /// Allow invalid certificates: for an inherited environment, stored only while it differs from the parent's.
    func applyCertificates(_ on: Bool) async {
        guard let file = project?.file, let name = selectedEnvironment else { return }
        if isInherited {
            var change = file.environmentOverrides[name] ?? EnvironmentOverride()
            change.allowInvalidCertificates = on == parentEnvironment?.allowInvalidCertificates ? nil : on
            var overrides = file.environmentOverrides
            overrides[name] = change.isEmpty && change.unknownKeys.isEmpty ? nil : change
            await apply(.certificates, ProjectChange(environmentOverrides: overrides))
        } else if let index = file.environments.firstIndex(where: { $0.name == name }) {
            var list = file.environments
            list[index].allowInvalidCertificates = on
            await applyEnvironments(list, field: .certificates, selecting: name)
        }
    }

    /// Kafka over TLS: for an inherited environment, stored only while it differs from the parent's.
    func applyKafkaTLS(_ on: Bool) async {
        guard let file = project?.file, let name = selectedEnvironment else { return }
        if isInherited {
            var change = file.environmentOverrides[name] ?? EnvironmentOverride()
            change.kafkaTLS = on == parentEnvironment?.kafkaTLS ? nil : on
            var overrides = file.environmentOverrides
            overrides[name] = change.isEmpty && change.unknownKeys.isEmpty ? nil : change
            await apply(.kafkaTLS, ProjectChange(environmentOverrides: overrides))
        } else if let index = file.environments.firstIndex(where: { $0.name == name }) {
            var list = file.environments
            list[index].kafkaTLS = on
            await applyEnvironments(list, field: .kafkaTLS, selecting: name)
        }
    }

    /// The Kafka password: this Mac's, in `secrets.json`, under the project and the environment; empty removes it.
    func applyKafkaPassword() {
        guard let name = selectedEnvironment else { return }
        let stored = backend.kafkaPassword(project: projectID, environment: name) ?? ""
        guard kafkaPassword != stored else { return clear(.kafkaPassword) }
        do throws(StorageError) {
            try backend.setKafkaPassword(kafkaPassword, project: projectID, environment: name)
            clear(.kafkaPassword)
        } catch {
            messages[.kafkaPassword] = error.description
        }
    }

    /// Whether kubectl was found, for the connection dot and the suggestions. The form checks the cluster again
    /// when it changes, as when the first lookup ends or Look Again finds kubectl.
    var hasKubectl: Bool { backend.kubectl != nil }

    /// Reaches the cluster of the selected environment's kubeconfig file, then reads its namespaces and the
    /// deployments of the environment's namespace, as suggestions.
    func checkCluster() async {
        namespaces = []
        deployments = []
        guard let environment = selected, let file = environment.kubeconfig else {
            connection = .none
            return
        }
        // A window that opens with the app waits for the first lookup of the tools rather than finding kubectl missing.
        if !backend.hasLookedUpTools {
            connection = .checking
            await backend.waitForTools()
            guard !Task.isCancelled, selected?.kubeconfig == file else { return }
        }
        guard let kubectl = backend.kubectl else {
            connection = .failed(String(localized: "kubectl wasn’t found in your login shell’s PATH.", bundle: #bundle))
            return
        }
        connection = .checking
        do throws(KubectlError) {
            let found = try await kubectl.namespaces(kubeconfig: file)
            guard selected?.kubeconfig == file else { return }
            namespaces = found
            connection = .connected
            deployments = (try? await kubectl.deployments(namespace: environment.namespace, kubeconfig: file)) ?? []
        } catch {
            guard selected?.kubeconfig == file else { return }
            connection = .failed(error.description)
        }
    }

    // MARK: Private

    private func loadEnvironment(except editing: Field? = nil) {
        let entry = selected
        let inherited = isInherited
        let change = selectedEnvironment.flatMap { project?.file.environmentOverrides[$0] }
        if editing != .environmentName { environmentName = entry?.name ?? "" }
        // An inherited environment shows the project's change, its parent's values as placeholders.
        if editing != .kubeconfig { kubeconfig = (inherited ? change?.kubeconfig : entry?.kubeconfig) ?? "" }
        if editing != .namespace { namespace = (inherited ? change?.namespace : entry?.namespace) ?? "" }
        if editing != .deployment { deployment = (inherited ? change?.deployment : entry?.deployment) ?? "" }
        if editing != .jaeger { jaeger = (inherited ? change?.jaeger : entry?.jaeger) ?? "" }
        if editing != .url { url = (inherited ? change?.url : entry?.url) ?? "" }
        if editing != .port { port = ((inherited ? change?.port : entry?.port).map(String.init)) ?? "" }
        if editing != .kafkaBrokers { kafkaBrokers = (inherited ? change?.kafkaBrokers : entry?.kafkaBrokers) ?? "" }
        if editing != .kafkaUsername { kafkaUsername = (inherited ? change?.kafkaUsername : entry?.kafkaUsername) ?? "" }
        if editing != .kafkaPassword {
            kafkaPassword = selectedEnvironment.flatMap { backend.kafkaPassword(project: projectID, environment: $0) } ?? ""
        }
    }

    /// The port field as a number: empty is none; anything else must be 1–65535.
    private func parsedPort(_ field: Field) -> Int?? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Int(trimmed), (1...65535).contains(value) else {
            messages[field] = ProjectMessages.ruleMessage(.port(field: "port"))
            return nil
        }
        return .some(value)
    }

    private func applyEnvironments(_ list: [EnvironmentEntry], field: Field, selecting name: String?) async {
        if await apply(field, ProjectChange(environments: list)) {
            selectedEnvironment = name ?? environments.first?.name
            loadEnvironment()
        }
    }

    private func clear(_ field: Field) {
        messages[field] = nil
    }

    /// Applies a change; true when it applied, false when its message shows under `field`.
    @discardableResult
    private func apply(_ field: Field, _ change: ProjectChange) async -> Bool {
        do throws(ProjectError) {
            try await backend.update(projectID, change)
            messages[field] = nil
            reload()
            return true
        } catch {
            messages[field] = ProjectMessages.message(error)
            return false
        }
    }
}
