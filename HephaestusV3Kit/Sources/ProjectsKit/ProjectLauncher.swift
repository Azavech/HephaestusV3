import AZDesign
import SwiftUI
import ToolsFoundation

/// The menu bar's panel: type a few letters of a project, then Return to bring its window forward, or
/// ⌘1–⌘6 to open one of its tools. The pointer works too: a click on a project, or on one of the
/// tool buttons of the row under it.
///
/// It opens routes only; ToolsScenes decides whether a window already shows the project.
public struct ProjectLauncher: View {
    /// Every project, as the app holds them now: the panel follows their changes, also while the menu bar extra
    /// keeps it between openings.
    let projects: [Project]
    @State private var model = ProjectPickerModel(projects: [])
    @FocusState private var isFilterFocused: Bool
    /// Whether the panel is open: its window is key while it shows.
    @Environment(\.appearsActive) private var appearsActive

    public init(projects: [Project]) {
        self.projects = projects
    }

    public var body: some View {
        ProjectLauncherPanel(model: model, isFilterFocused: $isFilterFocused)
            // The menu bar extra may keep this view between openings, so the panel starts afresh each
            // time its window becomes key or stops being key (and after each action), not only at the
            // first appearance: no filter, the first row highlighted, and the keyboard in the field.
            .onAppear {
                startAfresh()
            }
            .onChange(of: appearsActive) { _, isActive in
                startAfresh(focusing: isActive)
            }
            .onChange(of: projects, initial: true) {
                model.update(projects: projects)
            }
    }

    private func startAfresh(focusing: Bool = true) {
        model.reset()
        if focusing {
            isFilterFocused = true
        }
    }
}

/// The panel's content: the filter field, the projects, the footer.
struct ProjectLauncherPanel: View {
    let model: ProjectPickerModel
    var isFilterFocused: FocusState<Bool>.Binding

    @Environment(\.openRoute) private var openRoute
    @Environment(\.dismiss) private var dismiss
    /// Only the available tools show.
    @Environment(\.availableTools) private var availableTools
    /// The row the VoiceOver cursor is on, which the highlight follows.
    @AccessibilityFocusState private var voiceOverRow: Project.ID?

    @ScaledMetric(relativeTo: .body) private var panelWidth = 360.0
    @ScaledMetric(relativeTo: .body) private var panelHeight = 460.0
    /// The icon's column and each tool button's square.
    @ScaledMetric(relativeTo: .title3) private var iconSize = 24.0

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(.canvas)
        .background { shortcuts }
        .defaultFocus(isFilterFocused, true)
        .onChange(of: voiceOverRow) { _, id in
            if let id {
                model.highlight(id)
            }
        }
    }

    // MARK: Parts

    private var filterField: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.textSecondary)
                .accessibilityHidden(true)
            TextField(String(localized: "Open Project", bundle: #bundle), text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(isFilterFocused)
                .onSubmit {
                    if let project = model.highlightedProject {
                        open(project)
                    }
                }
                .onKeyPress(.downArrow) {
                    model.move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.move(by: -1)
                    return .handled
                }
                .accessibilityIdentifier("launcher.filter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.hasNoMatches {
                        Text("No Matching Projects", bundle: #bundle)
                            .foregroundStyle(.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .accessibilityIdentifier("launcher.noMatches")
                    }
                    ForEach(model.sections) { section in
                        if !model.isFiltering {
                            Text(verbatim: section.kind.pluralTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("launcher.section.\(section.kind.rawValue)")
                        }
                        ForEach(section.entries, id: \.project.id) { entry in
                            row(entry.project, depth: entry.depth)
                                .id(entry.project.id)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.highlighted) { _, id in
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ project: Project, depth: Int) -> some View {
        let isHighlighted = project.id == model.highlighted
        return HStack(spacing: 4) {
            Button {
                open(project)
            } label: {
                HStack(spacing: 10) {
                    ProjectIcon(project)
                        .font(.title3)
                        .frame(width: iconSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: project.name)
                            .foregroundStyle(.textPrimary)
                        Text(verbatim: project.id)
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Bring its window forward", bundle: #bundle))
            // VoiceOver says which row Return and ⌘1–⌘6 act on, and offers every row's tools, not
            // only the highlighted row's buttons.
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
            .accessibilityActions {
                ForEach(project.tools.filter(availableTools.contains)) { tool in
                    Button(String(localized: "Open \(tool.title)", bundle: #bundle, comment: "Opens a tool's window, such as Open Tickets")) {
                        open(tool, of: project)
                    }
                }
            }
            .accessibilityFocused($voiceOverRow, equals: project.id)
            .accessibilityIdentifier("launcher.row.\(project.id)")
            // The tools of the row under the pointer or the arrow keys, as ⌘1–⌘6 open them.
            if isHighlighted {
                ForEach(project.tools.filter(availableTools.contains)) { tool in
                    Button {
                        open(tool, of: project)
                    } label: {
                        Label(tool.title, systemImage: tool.symbol)
                            .labelStyle(.iconOnly)
                            .frame(width: iconSize, height: iconSize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.textPrimary)
                    .help(Text("\(tool.title) (⌘\(String(tool.shortcut.character)))", bundle: #bundle, comment: "A tool button's help: the tool and its shortcut"))
                    .accessibilityIdentifier("launcher.row.\(project.id).\(tool.rawValue)")
                }
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * 18)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            isHighlighted ? Color.highlight : .clear,
            in: .rect(corners: .concentric(minimum: .fixed(6)), isUniform: true)
        )
        .onHover { isInside in
            if isInside {
                model.highlight(project.id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(String(localized: "Show All Projects", bundle: #bundle), systemImage: "square.grid.2x2") {
                follow(.project(model.highlighted ?? model.tree.projects.first?.id ?? ""))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("launcher.showAll")
            Spacer(minLength: 8)
            Text("↩ Open  ⌘1–⌘6 Tools", bundle: #bundle, comment: "The menu bar panel's reminder of its keys")
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// ⌘1–⌘6 open a tool of the highlighted project, as the Window menu does for the key window's.
    private var shortcuts: some View {
        ZStack {
            ForEach(ToolKind.allCases.filter(availableTools.contains)) { tool in
                Button(tool.title) {
                    if let project = model.highlightedProject {
                        open(tool, of: project)
                    }
                }
                .keyboardShortcut(tool.shortcut)
                .disabled(!(model.highlightedProject?.tools.contains(tool) ?? false))
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func open(_ project: Project) {
        follow(.projectWindow(project.id))
    }

    private func open(_ tool: ToolKind, of project: Project) {
        follow(.tool(tool, project: project.id))
    }

    /// Every action asks for a route and closes the panel, which starts afresh at its next opening.
    private func follow(_ route: Route) {
        openRoute(route)
        dismiss()
        model.reset()
    }
}

// MARK: - Previews

/// The panel as it opens, or with `query` typed in its field.
private struct LauncherPreview: View {
    @State private var model = ProjectPickerModel(store: SampleProjectStore())
    @FocusState private var isFilterFocused: Bool
    let query: String

    init(query: String = "") {
        self.query = query
    }

    var body: some View {
        ProjectLauncherPanel(model: model, isFilterFocused: $isFilterFocused)
            .onAppear {
                model.query = query
            }
    }
}

#Preview("Launcher", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectLauncher(projects: Project.samples)
}

#Preview("Launcher, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectLauncher(projects: Project.samples)
        .preferredColorScheme(.dark)
}

#Preview("Filtering", traits: .appChrome, .sizeThatFitsLayout) {
    LauncherPreview(query: "pa")
}

#Preview("No Matches", traits: .appChrome, .sizeThatFitsLayout) {
    LauncherPreview(query: "xyz")
}

#Preview("Largest Text", traits: .largestText, .sizeThatFitsLayout) {
    LauncherPreview()
}
