import AZDesign
import ContractData
import SwiftUI
import ToolsFoundation

/// The Contracts window for one project: the operations of its OpenAPI contract, and a request
/// builder to call one on an environment.
/// What a tab keeps of Contracts while another tab is in front: its model, so that its selection, filters
/// and drafts are still there when the tab comes back. The app's window makes one per tab and project.
@MainActor
public final class ContractsTabState {
    let model: ContractsModel

    public init(project: Project, focus: String? = nil, store: LiveContractStore) {
        model = ContractsModel(project: project, focus: focus, store: store)
    }
}

public struct ContractsRootView: View {
    @State private var model: ContractsModel

    @Environment(\.reportChatSubject) private var reportChatSubject
    @Environment(\.windowLayout) private var layout

    /// The contract of `project`, with `focus` (an operation id) selected when it opens.
    public init(project: Project, focus: String? = nil, store: LiveContractStore) {
        self.init(model: ContractsModel(project: project, focus: focus, store: store))
    }

    init(model: ContractsModel) {
        _model = State(initialValue: model)
    }

    /// The contract a tab keeps.
    public init(state: ContractsTabState) {
        self.init(model: state.model)
    }

    /// The operations column: shown on a Mac, folded behind the sidebar button on an iPad.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The credentials and headers sheet, while it shows.
    @State private var access: ContractAccess?

    public var body: some View {
        Group {
            if let contract = model.contract {
                if layout == .phone {
                    phoneBody(contract)
                } else {
                    splitBody(contract)
                }
            } else {
                Group {
                    switch model.contractLoad {
                    case .loading:
                        ProgressView(String(localized: "Reading the contract…", bundle: #bundle))
                            .accessibilityIdentifier("contracts.loading")
                    case .failed(let message):
                        ContentUnavailableView {
                            Label(String(localized: "Can't Read the Contract", bundle: #bundle), systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(verbatim: message)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        .accessibilityIdentifier("contracts.unreadable")
                    default:
                        ContentUnavailableView {
                            Label(String(localized: "No Contract", bundle: #bundle), systemImage: ToolKind.contracts.symbol)
                        } description: {
                            Text("This project has no OpenAPI contract yet.", bundle: #bundle)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("contracts.noContract")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.canvas)
                .toolbar {
                    ChatPanelToolbarItem()
                }
            }
        }
        // The contract is read when the window shows, and again when its files change.
        .task {
            await model.refresh()
        }
        .sheet(item: $access) { access in
            ContractAccessSheet(access: access) { changed in
                model.store.setAccess(changed, of: model.project)
                self.access = nil
            } cancel: {
                self.access = nil
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
                OperationView(draft: draft(for: operation), environment: model.environment, response: model.response(for: operation),
                              failure: model.failures[operation.id])
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
                OperationView(draft: draft(for: operation), environment: model.environment, response: model.response(for: operation),
                              failure: model.failures[operation.id])
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
                    Picker(String(localized: "Environment", bundle: #bundle), selection: Binding(get: { model.environmentName },
                                                                                                    set: { model.pickEnvironment($0) })) {
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
        if let access = model.store.access(of: model.project) {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Credentials and Headers", bundle: #bundle), systemImage: "key") {
                    self.access = access
                }
                .help(String(localized: "Credentials and headers of the requests", bundle: #bundle))
                .accessibilityIdentifier("contracts.access")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(String(localized: "Send", bundle: #bundle, comment: "Button: sends the request to the environment."), systemImage: "paperplane.fill") {
                Task { await model.send() }
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


/// The credentials the contract asks for and the headers added to every request, kept on this Mac
/// (docs/ui/contracts.md › Credentials and headers).
private struct ContractAccessSheet: View {
    @State var access: ContractAccess
    let save: (ContractAccess) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach($access.schemes) { $scheme in
                    Section {
                        switch scheme.kind {
                        case .apiKey(let label):
                            TextField(label, text: binding($scheme, "value"))
                        case .basic:
                            TextField(String(localized: "Username", bundle: #bundle), text: binding($scheme, "username"))
                            SecureField(String(localized: "Password", bundle: #bundle), text: binding($scheme, "password"))
                        case .bearer:
                            SecureField(String(localized: "Token", bundle: #bundle), text: binding($scheme, "token"))
                        }
                    } header: {
                        Text(verbatim: scheme.name)
                    } footer: {
                        if !scheme.description.isEmpty {
                            Text(verbatim: scheme.description).font(.caption).foregroundStyle(.textSecondary)
                        }
                    }
                }
                Section {
                    ForEach(access.headers.indices, id: \.self) { index in
                        HStack {
                            TextField(String(localized: "Name", bundle: #bundle), text: $access.headers[index].name)
                            TextField(String(localized: "Value", bundle: #bundle), text: $access.headers[index].value)
                            Button(String(localized: "Remove Header", bundle: #bundle), systemImage: "minus.circle") {
                                access.headers.remove(at: index)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    Button(String(localized: "Add Header", bundle: #bundle)) {
                        access.headers.append(StoredHeader(name: "", value: ""))
                    }
                    .accessibilityIdentifier("contracts.access.addHeader")
                } header: {
                    Text("Headers", bundle: #bundle)
                } footer: {
                    Text("Added to every request of this contract. Kept on this Mac, with the credentials.", bundle: #bundle)
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: #bundle), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", bundle: #bundle)) { save(access) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("contracts.access.save")
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 360)
        .accessibilityIdentifier("contracts.access.sheet")
    }

    private func binding(_ scheme: Binding<ContractAccess.Scheme>, _ key: String) -> Binding<String> {
        Binding(get: { scheme.wrappedValue.values[key] ?? "" }, set: { scheme.wrappedValue.values[key] = $0 })
    }
}

extension ContractAccess: Identifiable {
    var id: String { schemes.map(\.name).joined(separator: ",") + "|\(headers.count)" }
}
