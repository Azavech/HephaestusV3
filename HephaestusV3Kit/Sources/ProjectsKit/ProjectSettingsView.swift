import AppKit
import AZDesign
import ExternalTools
import ProjectData
import SwiftUI
import ToolsFoundation
import UniformTypeIdentifiers

/// The Project Settings window of one project (⇧⌘,): its name, type, tint and icon, its folder and parent, and
/// the sections that apply to it, its GitHub page, graph and environments, the others added with `+`
/// (docs/ui/project-settings.md).
public struct ProjectSettingsWindow: View {
    @State private var model: ProjectSettingsModel

    public init(session: ProjectSession, projectID: Project.ID) {
        _model = State(initialValue: ProjectSettingsModel(projectID: projectID, backend: session))
    }

    init(model: ProjectSettingsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if let project = model.project {
                ProjectSettingsForm(model: model, project: project)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Project Not Found", bundle: #bundle), systemImage: "folder.badge.questionmark")
                } description: {
                    Text("The project is no longer in the list.", bundle: #bundle)
                }
                .accessibilityIdentifier("projectSettings.notFound")
            }
        }
        .frame(minWidth: 420, idealWidth: 600, minHeight: 420, idealHeight: 720)
        .navigationTitle(Text("Project Settings", bundle: #bundle))
        .navigationSubtitle(Text(verbatim: model.project?.file.name ?? ""))
    }
}

/// The form: one section per group of settings.
private struct ProjectSettingsForm: View {
    let model: ProjectSettingsModel
    let project: LoadedProject

    @FocusState private var focus: ProjectSettingsModel.Field?
    @State private var browsingKubeconfig = false

    var body: some View {
        @Bindable var model = model
        Form {
            general
            location
            if model.shows(.github) {
                Section(String(localized: "GitHub", bundle: #bundle)) {
                    field(String(localized: "GitHub Page", bundle: #bundle), text: $model.githubPage, field: .githubPage,
                          prompt: project.resolved.defaultGithubPage ?? "https://github.com/owner/name", monospaced: true) {
                        await model.applyGitHubPage()
                    }
                }
            }
            if model.shows(.service) {
                service
            }
            if model.shows(.environments) {
                environments
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(model.addableSections) { section in
                        Button {
                            model.add(section)
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                        }
                        .accessibilityIdentifier("projectSettings.addSection.\(section.rawValue)")
                    }
                } label: {
                    Label(String(localized: "Add Settings", bundle: #bundle), systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .disabled(model.addableSections.isEmpty)
                .help(String(localized: "Add settings this project doesn’t show yet", bundle: #bundle))
                .accessibilityIdentifier("projectSettings.addSection")
            }
        }
        // Changes made elsewhere show, except in the field being edited.
        .onChange(of: project) {
            model.reload(except: focus)
        }
        .onChange(of: focus) { old, _ in
            guard let old else { return }
            Task { await apply(old) }
        }
        .task(id: [model.selectedEnvironment ?? "", model.selected?.kubeconfig ?? "", model.selected?.namespace ?? ""]) {
            await model.checkCluster()
        }
        .fileImporter(isPresented: $browsingKubeconfig, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            model.kubeconfig = url.path
            Task { await model.applyEnvironmentField(.kubeconfig) }
        }
        .fileDialogDefaultDirectory(kubeDirectory)
        .fileDialogBrowserOptions(.includeHiddenFiles)
        .accessibilityIdentifier("projectSettings")
    }

    // MARK: Sections

    private var general: some View {
        @Bindable var model = model
        return Section(String(localized: "General", bundle: #bundle)) {
            field(String(localized: "Name", bundle: #bundle), text: $model.name, field: .name) { await model.applyName() }
            LabeledContent(String(localized: "Identifier", bundle: #bundle)) {
                Text(verbatim: project.id)
                    .monospaced()
                    .textSelection(.enabled)
            }
            .help(String(localized: "The identifier is set at creation and cannot be changed.", bundle: #bundle))
            .accessibilityIdentifier("projectSettings.identifier")
            Picker(String(localized: "Type", bundle: #bundle),
                   selection: Binding { Project.Kind(project.file.type) } set: { kind in Task { await model.applyKind(kind) } }) {
                ForEach(Project.Kind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .accessibilityIdentifier("projectSettings.type")
            message(.kind)
            Picker(String(localized: "Tint", bundle: #bundle),
                   selection: Binding { ProjectTint(stored: project.file.color) } set: { tint in Task { await model.applyTint(tint) } }) {
                ForEach(ProjectTint.allCases, id: \.self) { tint in
                    Label {
                        Text(verbatim: tint.title)
                    } icon: {
                        TintSwatch.image(tint.color)
                    }
                    .tag(tint)
                }
            }
            .accessibilityIdentifier("projectSettings.tint")
            message(.tint)
            field(String(localized: "Icon", bundle: #bundle), text: $model.icon, field: .icon, prompt: Project.Kind(project.file.type).symbol,
                  monospaced: true, symbol: model.icon.isEmpty ? Project.Kind(project.file.type).symbol : model.icon) {
                await model.applyIcon()
            }
        }
    }

    private var location: some View {
        @Bindable var model = model
        return Section(String(localized: "Location", bundle: #bundle)) {
            LabeledContent(String(localized: "Folder", bundle: #bundle)) {
                HStack(spacing: 8) {
                    Text(verbatim: project.root)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(String(localized: "Show in Finder", bundle: #bundle)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.root)])
                    }
                    .accessibilityIdentifier("projectSettings.showInFinder")
                }
            }
            .accessibilityIdentifier("projectSettings.folder")
            if let parent = model.parent {
                LabeledContent(String(localized: "Parent", bundle: #bundle)) {
                    Text(verbatim: "\(parent.file.name) (\(parent.id))")
                }
                .accessibilityIdentifier("projectSettings.parent")
                Text("Settings left empty take the values of “\(parent.file.name)”, shown in grey.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("projectSettings.parent.note")
            }
            field(String(localized: "Docs Folder", bundle: #bundle), text: $model.docsPath, field: .docsPath, prompt: "docs", monospaced: true) {
                await model.applyDocsPath()
            }
        }
    }

    /// The graph: a toggle for a top-level project; for a sub project, also the parent's value.
    private var service: some View {
        Section(String(localized: "Service", bundle: #bundle)) {
            if let parent = model.parent {
                Picker(String(localized: "Graph", bundle: #bundle),
                       selection: Binding { model.graphSetting } set: { value in Task { await model.applyGraph(value) } }) {
                    Text(model.inheritedGraphEnabled
                         ? String(localized: "Same as “\(parent.file.name)”: On", bundle: #bundle)
                         : String(localized: "Same as “\(parent.file.name)”: Off", bundle: #bundle))
                        .tag(Bool?.none)
                    Divider()
                    Text("On", bundle: #bundle).tag(Bool?.some(true))
                    Text("Off", bundle: #bundle).tag(Bool?.some(false))
                }
                .accessibilityIdentifier("projectSettings.graph")
            } else {
                Toggle(String(localized: "Enable graph", bundle: #bundle),
                       isOn: Binding { model.graphEnabled } set: { on in Task { await model.applyGraph(on ? true : nil) } })
                    .accessibilityIdentifier("projectSettings.graph")
            }
            message(.graph)
        }
    }

    private var environments: some View {
        @Bindable var model = model
        let selected = model.selected
        let parent = model.parentEnvironment
        let inherited = model.isInherited
        return Section {
            HStack(spacing: 8) {
                Picker(String(localized: "Environment", bundle: #bundle),
                       selection: Binding { model.selectedEnvironment } set: { name in Task { await model.select(name) } }) {
                    ForEach(model.environments, id: \.name) { environment in
                        Text(verbatim: environment.name).tag(String?.some(environment.name))
                    }
                }
                .disabled(model.environments.isEmpty)
                .accessibilityIdentifier("projectSettings.environment")
                Button {
                    Task { await model.addEnvironment() }
                } label: {
                    Label(String(localized: "Add Environment", bundle: #bundle), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Add Environment", bundle: #bundle))
                .accessibilityIdentifier("projectSettings.environment.add")
                Button {
                    Task { await model.removeEnvironment() }
                } label: {
                    Label(String(localized: "Remove Environment", bundle: #bundle), systemImage: "minus")
                        .labelStyle(.iconOnly)
                }
                .disabled(selected == nil || inherited)
                .help(String(localized: "Remove Environment", bundle: #bundle))
                .accessibilityIdentifier("projectSettings.environment.remove")
            }
            if inherited, let parentName = model.parent?.file.name {
                Text("Inherited from “\(parentName)”: fields left empty keep its values, shown in grey.", bundle: #bundle)
                    .font(.callout)
                    .foregroundStyle(.textSecondary)
                    .accessibilityIdentifier("projectSettings.environment.inherited")
            }
            message(.environments)
            if selected != nil {
                field(String(localized: "Name", bundle: #bundle), text: $model.environmentName, field: .environmentName, disabled: inherited) {
                    await model.applyEnvironmentField(.environmentName)
                }
                LabeledContent(String(localized: "Kubeconfig File", bundle: #bundle)) {
                    HStack(spacing: 8) {
                        TextField(String(localized: "Kubeconfig File", bundle: #bundle), text: $model.kubeconfig,
                                  prompt: Text(verbatim: inherited ? (parent?.kubeconfig ?? "") : "~/.kube/config"))
                            .labelsHidden()
                            .monospaced()
                            .focused($focus, equals: .kubeconfig)
                            .onSubmit { Task { await model.applyEnvironmentField(.kubeconfig) } }
                            .accessibilityIdentifier("projectSettings.kubeconfig")
                        Button(String(localized: "Browse…", bundle: #bundle)) {
                            browsingKubeconfig = true
                        }
                        connectionDot
                    }
                }
                message(.kubeconfig)
                connectionMessage
                suggestionField(String(localized: "Namespace", bundle: #bundle), text: $model.namespace, field: .namespace,
                                suggestions: model.namespaces, prompt: inherited ? parent?.namespace : nil)
                suggestionField(String(localized: "Deployment", bundle: #bundle), text: $model.deployment, field: .deployment,
                                suggestions: model.deployments, prompt: inherited ? parent?.deployment : nil)
                field(String(localized: "Jaeger", bundle: #bundle), text: $model.jaeger, field: .jaeger,
                      prompt: inherited ? (parent?.jaeger ?? "") : "jaeger/jaeger", monospaced: true) {
                    await model.applyEnvironmentField(.jaeger)
                }
                LabeledContent(String(localized: "API Access", bundle: #bundle)) {
                    HStack(spacing: 6) {
                        TextField(String(localized: "URL", bundle: #bundle), text: $model.url,
                                  prompt: Text(verbatim: inherited ? (parent?.url ?? "") : "https://api.example.com"))
                            .labelsHidden()
                            .monospaced()
                            .focused($focus, equals: .url)
                            .onSubmit { Task { await model.applyEnvironmentField(.url) } }
                            .accessibilityIdentifier("projectSettings.url")
                        Text(verbatim: ":")
                        TextField(String(localized: "Port", bundle: #bundle), text: $model.port,
                                  prompt: inherited ? Text(verbatim: parent?.port.map(String.init) ?? "") : Text("Port", bundle: #bundle))
                            .labelsHidden()
                            .monospaced()
                            .frame(width: 64)
                            .focused($focus, equals: .port)
                            .onSubmit { Task { await model.applyEnvironmentField(.port) } }
                            .accessibilityIdentifier("projectSettings.port")
                    }
                }
                message(.url)
                message(.port)
                Toggle(String(localized: "Allow invalid certificates", bundle: #bundle),
                       isOn: Binding { selected?.allowInvalidCertificates ?? false } set: { on in Task { await model.applyCertificates(on) } })
                    .accessibilityIdentifier("projectSettings.certificates")
                message(.certificates)
            }
        } header: {
            Text("Environments", bundle: #bundle)
        } footer: {
            if model.environments.isEmpty {
                Text("No environment yet. Add one with +.", bundle: #bundle)
                    .foregroundStyle(.textSecondary)
            }
        }
    }

    // MARK: Parts

    @ViewBuilder private var connectionDot: some View {
        switch model.connection {
        case .none:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Checking the cluster", bundle: #bundle))
        case .connected:
            StatusDot(.success)
                .accessibilityHidden(false)
                .accessibilityLabel(Text("kubectl reaches the cluster", bundle: #bundle))
                .help(String(localized: "kubectl reaches the cluster", bundle: #bundle))
        case .failed:
            StatusDot(.danger)
                .accessibilityHidden(false)
                .accessibilityLabel(Text("kubectl can’t reach the cluster", bundle: #bundle))
        }
    }

    @ViewBuilder private var connectionMessage: some View {
        if case .failed(let reason) = model.connection {
            Text(verbatim: reason)
                .font(.callout)
                .foregroundStyle(.danger)
                .lineLimit(3)
                .accessibilityIdentifier("projectSettings.connection.message")
        }
    }

    /// A text field applying on Return or when it loses the focus, with its message under it.
    private func field(_ title: String, text: Binding<String>, field: ProjectSettingsModel.Field, prompt: String? = nil,
                       monospaced: Bool = false, disabled: Bool = false, symbol: String? = nil,
                       apply: @escaping () async -> Void) -> some View {
        Group {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField(title, text: text, prompt: prompt.map { Text(verbatim: $0) })
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(monospaced ? .body.monospaced() : .body)
                        .focused($focus, equals: field)
                        .onSubmit { Task { await apply() } }
                        .disabled(disabled)
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(.textSecondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityIdentifier("projectSettings.\(identifier(field))")
            message(field)
        }
    }

    /// A text field with a menu of suggestions from the cluster; any name can be typed.
    private func suggestionField(_ title: String, text: Binding<String>, field: ProjectSettingsModel.Field, suggestions: [String],
                                 prompt: String? = nil) -> some View {
        Group {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    TextField(title, text: text, prompt: prompt.map { Text(verbatim: $0) })
                        .labelsHidden()
                        .monospaced()
                        .focused($focus, equals: field)
                        .onSubmit { Task { await model.applyEnvironmentField(field) } }
                    Menu {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) {
                                text.wrappedValue = name
                                Task { await model.applyEnvironmentField(field) }
                            }
                        }
                    } label: {
                        Label(String(localized: "Suggestions", bundle: #bundle), systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(suggestions.isEmpty)
                }
            }
            .accessibilityIdentifier("projectSettings.\(identifier(field))")
            message(field)
        }
    }

    @ViewBuilder private func message(_ field: ProjectSettingsModel.Field) -> some View {
        if let text = model.message(field) {
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.danger)
                .accessibilityIdentifier("projectSettings.\(identifier(field)).message")
        }
    }

    private func apply(_ field: ProjectSettingsModel.Field) async {
        switch field {
        case .name: await model.applyName()
        case .icon: await model.applyIcon()
        case .docsPath: await model.applyDocsPath()
        case .githubPage: await model.applyGitHubPage()
        case .environmentName, .kubeconfig, .namespace, .deployment, .jaeger, .url, .port: await model.applyEnvironmentField(field)
        default: break
        }
    }

    private func identifier(_ field: ProjectSettingsModel.Field) -> String {
        switch field {
        case .name: "name"
        case .kind: "type"
        case .tint: "tint"
        case .icon: "icon"
        case .docsPath: "docsPath"
        case .githubPage: "githubPage"
        case .graph: "graph"
        case .environments: "environments"
        case .environmentName: "environmentName"
        case .kubeconfig: "kubeconfig"
        case .namespace: "namespace"
        case .deployment: "deployment"
        case .jaeger: "jaeger"
        case .url: "url"
        case .port: "port"
        case .certificates: "certificates"
        }
    }

    /// `~/.kube` when it exists, else the home folder.
    private var kubeDirectory: URL {
        let kube = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube", isDirectory: true)
        return FileManager.default.fileExists(atPath: kube.path) ? kube : URL(fileURLWithPath: NSHomeDirectory())
    }
}

// MARK: - Previews

/// A fixed snapshot for the previews: Orders, a service with two environments; Worker, its sub project that
/// inherits them; Notes, an app; and Scripts, a project of type Other with nothing set. Changes do nothing.
@MainActor
final class PreviewSettingsBackend: ProjectSettingsBackend {
    let snapshot: ProjectSnapshot
    /// A kubectl that answers from fixed lists, without starting a process.
    var kubectl: Kubectl? {
        Kubectl(executable: "/opt/homebrew/bin/kubectl", environment: [:], runner: PreviewKubectlRunner())
    }

    init() {
        let created = Date(timeIntervalSince1970: 1_793_440_000)
        let local = EnvironmentEntry(name: "local", url: "http://127.0.0.1", port: 8080)
        let staging = EnvironmentEntry(name: "staging", url: "https://staging.example.com", allowInvalidCertificates: true,
                                       namespace: "orders", deployment: "orders-api", jaeger: "tracing/jaeger",
                                       kubeconfig: "~/.kube/staging.yaml")
        var orders = ResolvedSettings()
        orders.environments = [local, staging]
        orders.currentEnvironment = "staging"
        orders.githubPage = "https://github.com/example/orders"
        orders.defaultGithubPage = orders.githubPage
        orders.graphEnabled = true
        var worker = ResolvedSettings()
        var workerStaging = staging
        workerStaging.deployment = "orders-worker"
        worker.environments = [local, workerStaging]
        worker.inheritedEnvironments = [local, staging]
        worker.currentEnvironment = "staging"
        worker.githubPage = orders.githubPage
        worker.defaultGithubPage = orders.githubPage
        worker.graphEnabled = true
        worker.inheritedGraphEnabled = true
        var app = ResolvedSettings()
        app.defaultGithubPage = "https://github.com/example/notes"
        app.githubPage = app.defaultGithubPage
        snapshot = ProjectSnapshot(revision: 1, projects: [
            LoadedProject(root: "/Users/example/Developer/orders",
                          file: ProjectFile(id: "ORD", name: "Orders", created: created, type: .goService, color: "accent",
                                            icon: "cart", subprojects: ["worker"], graphEnabled: true, environments: [local, staging]),
                          parentID: nil, depth: 0, childIDs: ["WRK"], resolved: orders, fileIssue: nil),
            LoadedProject(root: "/Users/example/Developer/orders/worker",
                          file: ProjectFile(id: "WRK", name: "Worker", created: created, type: .goService,
                                            environmentOverrides: ["staging": EnvironmentOverride(deployment: "orders-worker")]),
                          parentID: "ORD", depth: 1, childIDs: [], resolved: worker, fileIssue: nil),
            LoadedProject(root: "/Users/example/Developer/notes",
                          file: ProjectFile(id: "NOTE", name: "Notes", created: created, type: .swiftApplication, color: "success"),
                          parentID: nil, depth: 0, childIDs: [], resolved: app, fileIssue: nil),
            LoadedProject(root: "/Users/example/Developer/scripts",
                          file: ProjectFile(id: "SCR", name: "Scripts", created: created, color: "warning"),
                          parentID: nil, depth: 0, childIDs: [], resolved: ResolvedSettings(), fileIssue: nil),
        ])
    }

    func update(_ id: String, _ change: ProjectChange) async throws(ProjectError) {}
}

/// Answers `get namespaces` and `get deployments` with fixed names.
private struct PreviewKubectlRunner: ProcessRunning {
    func run(_ request: ProcessRequest, input: Data?, timeout: Duration?) async throws -> ProcessResult {
        let names = request.arguments.contains("namespaces") ? ["default", "orders", "tracing"] : ["orders-api", "orders-worker"]
        let items = names.map { #"{"metadata":{"name":"\#($0)"}}"# }.joined(separator: ",")
        return ProcessResult(termination: .exited(0), standardOutput: Data(#"{"items":[\#(items)]}"#.utf8))
    }
}

@MainActor
func previewSettings(_ id: Project.ID) -> ProjectSettingsWindow {
    let model = ProjectSettingsModel(projectID: id, backend: PreviewSettingsBackend())
    return ProjectSettingsWindow(model: model)
}

#Preview("Service", traits: .appChrome, .fixedLayout(width: 600, height: 900)) {
    previewSettings("ORD")
}

#Preview("Service, Dark", traits: .appChrome, .fixedLayout(width: 600, height: 900)) {
    previewSettings("ORD")
        .preferredColorScheme(.dark)
}

#Preview("Sub Project, Inherited", traits: .appChrome, .fixedLayout(width: 600, height: 960)) {
    previewSettings("WRK")
}

#Preview("App", traits: .appChrome, .fixedLayout(width: 600, height: 560)) {
    previewSettings("NOTE")
}

#Preview("Other, Nothing Set", traits: .appChrome, .fixedLayout(width: 600, height: 480)) {
    previewSettings("SCR")
}

#Preview("Not Found", traits: .appChrome, .fixedLayout(width: 600, height: 420)) {
    previewSettings("GONE")
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 600, height: 900)) {
    previewSettings("ORD")
}

/// A tint's swatch in a menu. A menu draws a symbol as a template, in its own single color, so a symbol styled with
/// the tint shows in the menu's accent: the swatch is drawn into an image that isn't a template. Its color is the
/// tint's dynamic color, resolved each time the menu draws, so it follows Light and Dark Mode.
enum TintSwatch {
    static func image(_ color: Color, diameter: CGFloat = 12) -> Image {
        Image(nsImage: nsImage(color, diameter: diameter))
    }

    static func nsImage(_ color: Color, diameter: CGFloat = 12) -> NSImage {
        let fill = NSColor(color)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
