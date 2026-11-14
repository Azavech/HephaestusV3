import AZDesign
import SwiftUI
import ToolsFoundation

/// The Contracts window for one project: the operations of its OpenAPI contract, and a request
/// builder to call one on an environment.
public struct ContractsRootView: View {
    @State private var model: ContractsModel

    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.toolLayout) private var layout

    /// The contract of `project`, with `focus` (an operation id) selected when it opens.
    public init(project: Project, focus: String? = nil) {
        self.init(model: ContractsModel(project: project, focus: focus, store: SampleContractStore()))
    }

    init(model: ContractsModel) {
        _model = State(initialValue: model)
    }

    /// The operations column: shown on a Mac, folded behind the sidebar button on an iPad.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public var body: some View {
        Group {
            if let contract = model.contract {
                if layout == .phone {
                    phoneBody(contract)
                } else {
                    splitBody(contract)
                }
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Contract", bundle: #bundle), systemImage: ToolKind.contracts.symbol)
                } description: {
                    Text("This project has no OpenAPI contract yet.", bundle: #bundle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("contracts.noContract")
                .toolbar {
                    ChatPanelToolbarItem()
                }
            }
        }
        // A later route to this window selects its operation, without starting afresh.
        .onFocusRequest { focus in
            model.select(focus: focus)
        }
        // The chat panel beside the window asks about the selected operation.
        .onChange(of: model.selection, initial: true) {
            reportChatSubject(model.chatSubject)
        }
    }

    /// The Mac's: the operations beside the one picked. An iPad's folds the operations behind the
    /// sidebar button, as an iPad's split view does when it lacks the room, so the operation keeps it.
    private func splitBody(_ contract: Contract) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            operationList(contract)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let operation = model.selectedOperation {
                OperationView(draft: draft(for: operation), environment: model.environment)
                    .id(operation.id)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Operation Selected", bundle: #bundle), systemImage: ToolKind.contracts.symbol)
                } description: {
                    Text("Pick an operation to read it and call it.", bundle: #bundle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("contracts.noSelection")
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: Text("Filter Operations", bundle: #bundle))
        .toolbar {
            operationToolbar
        }
        .onChange(of: layout, initial: true) {
            columnVisibility = layout == .mac ? .all : .detailOnly
        }
    }

    /// An iPhone's: the operations, then the one picked as a page with Back.
    private func phoneBody(_ contract: Contract) -> some View {
        PhoneStack(selection: $model.selection, opensSelection: model.opensSelection) {
            operationList(contract)
                // In the toolbar's middle, so the chat panel's button stays last.
                .searchable(text: $model.query, placement: .toolbarPrincipal, prompt: Text("Filter Operations", bundle: #bundle))
                .toolbar {
                    ChatPanelToolbarItem()
                }
        } page: { id in
            if let operation = model.operation(id) {
                OperationView(draft: draft(for: operation), environment: model.environment)
                    .toolbar {
                        operationToolbar
                    }
            }
        }
    }

    private func operationList(_ contract: Contract) -> some View {
        OperationList(
            contract: contract,
            sections: model.sections,
            noMatchesText: model.hasNoMatches ? model.filterText : nil,
            selection: $model.selection
        )
    }

    /// The environment the request goes to, Send, and the chat panel's button.
    @ToolbarContentBuilder private var operationToolbar: some ToolbarContent {
        if !model.environments.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(String(localized: "Environment", bundle: #bundle), selection: $model.environmentName) {
                        ForEach(model.environments) { environment in
                            Text(verbatim: environment.name).tag(environment.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(verbatim: model.environmentName)
                        .toolbarLabelPadding()
                }
                .help(String(localized: "Environment the requests go to", bundle: #bundle))
                .accessibilityLabel(Text("Environment", bundle: #bundle))
                .accessibilityValue(Text(verbatim: model.environmentName))
                .accessibilityIdentifier("contracts.environment")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(String(localized: "Send", bundle: #bundle, comment: "Button: sends the request to the environment."), systemImage: "paperplane.fill") {
                model.send()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canSend)
            .help(String(localized: "Send the request", bundle: #bundle))
            .accessibilityIdentifier("contracts.send")
        }
        ChatPanelToolbarItem()
    }

    /// The request of `operation`, kept in the model while the operation stays selected.
    private func draft(for operation: Operation) -> Binding<RequestDraft> {
        Binding {
            model.draft(for: operation)
        } set: { draft in
            model.update(draft)
        }
    }
}

/// The operations, grouped by tag, under the contract's title and version.
private struct OperationList: View {
    let contract: Contract
    let sections: [OperationSection]
    /// The filter's text when it matches no operation.
    let noMatchesText: String?
    @Binding var selection: Operation.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.operations) { operation in
                        OperationRow(operation: operation)
                            .tag(operation.id)
                            .accessibilityIdentifier("contracts.row.\(operation.id)")
                    }
                } header: {
                    Text(verbatim: section.tag)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("contracts.section.\(section.tag)")
                }
            }
        }
        .overlay {
            if let noMatchesText {
                ContentUnavailableView {
                    Label(String(localized: "No Matching Operations", bundle: #bundle), systemImage: "magnifyingglass")
                } description: {
                    Text("No path, summary or operation id contains “\(noMatchesText)”.", bundle: #bundle)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("contracts.noResults")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: contract.title)
                    .font(.headline)
                Text(verbatim: contract.version)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("contracts.title")
        }
    }
}

/// An operation in the list: its method, its path and what it does.
private struct OperationRow: View {
    let operation: Operation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MethodBadge(method: operation.method)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: operation.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: operation.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

/// A model on the sample contracts, set up for a preview.
private func previewModel(
    _ project: Project = Project.samples[0], focus: String? = nil, query: String = "", selectsNothing: Bool = false
) -> ContractsModel {
    let model = ContractsModel(project: project, focus: focus, store: SampleContractStore())
    model.query = query
    if selectsNothing {
        model.selection = nil
    }
    return model
}

/// Orders, without its environments.
private var ordersWithoutEnvironments: Project {
    let orders = Project.samples[0]
    return Project(
        id: orders.id, name: orders.name, kind: orders.kind, tint: orders.tint, symbol: orders.symbol, path: orders.path,
        repository: orders.repository, environments: [], activity: orders.activity, parentID: orders.parentID
    )
}

#Preview("Loaded", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel())
}

#Preview("Loaded, Dark", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(focus: "createOrder"))
        .preferredColorScheme(.dark)
}

#Preview("Error Response", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(focus: "checkoutOrder"))
}

#Preview("Empty Response", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(focus: "cancelOrder"))
}

#Preview("No Operation Selected", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(selectsNothing: true))
}

#Preview("No Results", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(focus: "checkoutOrder", query: "invoice"))
}

#Preview("No Environments", traits: .appChrome, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(ordersWithoutEnvironments, focus: "getOrder"))
}

#Preview("No Contract", traits: .appChrome, .fixedLayout(width: 900, height: 600)) {
    ContractsRootView(model: previewModel(Project.samples[3]))
}

#Preview("Largest Text", traits: .largestText, .fixedLayout(width: 1100, height: 720)) {
    ContractsRootView(model: previewModel(focus: "createOrder"))
}

#Preview("iPad", traits: .padLayout, .fixedLayout(width: 760, height: 900)) {
    ContractsRootView(model: previewModel(focus: "checkoutOrder"))
}

#Preview("iPhone, Operations", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ContractsRootView(model: previewModel())
}

#Preview("iPhone, Operation", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ContractsRootView(model: previewModel(focus: "checkoutOrder"))
}

#Preview("iPhone, Dark", traits: .phoneLayout, .fixedLayout(width: 420, height: 800)) {
    ContractsRootView(model: previewModel(focus: "createOrder"))
        .preferredColorScheme(.dark)
}

#Preview("iPhone, Largest Text", traits: .phoneLayout, .largestText, .fixedLayout(width: 420, height: 800)) {
    ContractsRootView(model: previewModel(focus: "createOrder"))
}
