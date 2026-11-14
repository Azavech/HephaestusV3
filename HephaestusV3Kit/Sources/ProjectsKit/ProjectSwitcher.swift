import AZDesign
import SwiftUI
import ToolsFoundation

/// The project of a tool window, in its toolbar. Clicking it lists the projects to switch to.
///
/// Switching changes this window only, so two windows of the same tool can show two projects.
public struct ProjectSwitcher: View {
    @Binding var selection: Project.ID
    /// Projects without this tool are listed but can't be picked.
    let tool: ToolKind

    @Environment(\.openRoute) private var openRoute
    @State private var model: ProjectPickerModel
    @State private var isPresented = false

    public init(projects: [Project], selection: Binding<Project.ID>, tool: ToolKind) {
        _selection = selection
        self.tool = tool
        _model = State(initialValue: ProjectPickerModel(
            store: SampleProjectStore(projects: projects), requiredTool: tool, highlighting: selection.wrappedValue
        ))
    }

    public var body: some View {
        Button {
            if !isPresented {
                // Each opening starts without a filter, on the window's project.
                model.reset(highlighting: selection)
            }
            isPresented.toggle()
        } label: {
            if let current {
                Label {
                    Text(verbatim: current.name)
                } icon: {
                    ProjectIcon(current)
                }
                .labelStyle(.titleAndIcon)
                .toolbarLabelPadding()
            }
        }
        .help(String(localized: "Switch Project", bundle: #bundle))
        .accessibilityIdentifier("toolbar.projectSwitcher")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectSwitcherList(model: model, current: selection) { project in
                isPresented = false
                // The project the window already shows changes nothing: it keeps its tool and selection.
                if project.id != selection {
                    selection = project.id
                }
            } onShowAll: {
                isPresented = false
                openRoute(.project(selection))
            }
        }
    }

    private var current: Project? {
        model.tree.project(selection)
    }
}

/// The popover's content: a filter field, the projects by kind, and a way to the Projects window.
///
/// The keyboard works as in the menu bar panel: typing filters and highlights the first match, ↑ ↓
/// move the highlight, Return picks the highlighted project.
struct ProjectSwitcherList: View {
    let model: ProjectPickerModel
    /// The window's project, which has a checkmark.
    let current: Project.ID?
    let onPick: (Project) -> Void
    let onShowAll: () -> Void

    @FocusState private var isFilterFocused: Bool
    /// The popover's size, which grows with the text size.
    @ScaledMetric(relativeTo: .body) private var width = 300.0
    @ScaledMetric(relativeTo: .body) private var height = 380.0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TextField(String(localized: "Filter Projects", bundle: #bundle), text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFilterFocused)
                .onSubmit {
                    if let project = model.highlightedProject {
                        onPick(project)
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
                .padding(10)
                .accessibilityIdentifier("projectSwitcher.filter")
            ScrollViewReader { proxy in
                List {
                    ForEach(model.sections) { section in
                        Section(section.kind.pluralTitle) {
                            ForEach(section.entries, id: \.project.id) { entry in
                                row(entry.project, depth: entry.depth)
                                    .id(entry.project.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if model.hasNoMatches {
                        NoMatchingProjects(query: model.query)
                            .accessibilityIdentifier("projectSwitcher.noMatches")
                    }
                }
                .onChange(of: model.highlighted) { _, id in
                    proxy.scrollTo(id)
                }
            }
            Divider()
            Button(String(localized: "Show All Projects", bundle: #bundle), systemImage: "square.grid.2x2", action: onShowAll)
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .accessibilityIdentifier("projectSwitcher.showAll")
        }
        .frame(width: width, height: height)
        .defaultFocus($isFilterFocused, true)
        .onAppear {
            isFilterFocused = true
        }
    }

    private func row(_ project: Project, depth: Int) -> some View {
        let available = model.isAvailable(project)
        let isHighlighted = project.id == model.highlighted
        return Button {
            onPick(project)
        } label: {
            HStack {
                ProjectRow(project: project)
                Spacer()
                if project.id == current {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.accent)
                        .accessibilityLabel(Text("Current", bundle: #bundle, comment: "The project the window shows, in the project switcher"))
                } else if !available, let tool = model.requiredTool {
                    Text("No \(tool.title)", bundle: #bundle, comment: "A project without the window's tool, such as No Contracts")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            isHighlighted ? Color.highlight : .clear,
            in: .rect(corners: .concentric(minimum: .fixed(6)), isUniform: true)
        )
        .onHover { isInside in
            if isInside {
                model.highlight(project.id)
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("projectSwitcher.row.\(project.id)")
    }
}

// MARK: - Previews

private func previewModel(_ current: Project.ID, tool: ToolKind, query: String = "") -> ProjectPickerModel {
    let model = ProjectPickerModel(store: SampleProjectStore(), requiredTool: tool, highlighting: current)
    model.query = query
    return model
}

#Preview("Switcher List", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectSwitcherList(model: previewModel("ORD", tool: .contracts), current: "ORD", onPick: { _ in }, onShowAll: {})
}

#Preview("Switcher List, Dark", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectSwitcherList(model: previewModel("PAY", tool: .tickets), current: "PAY", onPick: { _ in }, onShowAll: {})
        .preferredColorScheme(.dark)
}

#Preview("Switcher Filtered", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectSwitcherList(model: previewModel("ORD", tool: .serviceMap, query: "s"), current: "ORD", onPick: { _ in }, onShowAll: {})
}

#Preview("Switcher No Matches", traits: .appChrome, .sizeThatFitsLayout) {
    ProjectSwitcherList(model: previewModel("ORD", tool: .tickets, query: "xyz"), current: "ORD", onPick: { _ in }, onShowAll: {})
}

#Preview("Switcher List, Largest Text", traits: .largestText, .sizeThatFitsLayout) {
    ProjectSwitcherList(model: previewModel("ORD", tool: .contracts), current: "ORD", onPick: { _ in }, onShowAll: {})
}
