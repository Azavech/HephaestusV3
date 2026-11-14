import Foundation
import Observation
import ToolsFoundation

/// The operations of one tag, as the list shows them.
nonisolated struct OperationSection: Identifiable, Hashable, Sendable {
    let tag: String
    let operations: [Operation]

    var id: String { tag }
}

/// The Contracts window: its filter, its selection, what a route's focus selects, the environment
/// the request goes to, and the request being written.
@Observable
final class ContractsModel {
    let project: Project
    /// Nil for a project without a contract.
    let contract: Contract?
    /// Whether the window opened on an operation a route asked for: an iPhone's layout then starts on
    /// its page.
    let opensSelection: Bool

    /// What the Filter Operations field holds.
    var query = ""
    /// The name of the environment the request goes to.
    var environmentName: String

    private var selectedID: Operation.ID? = nil
    /// The request for the selected operation, or for the last one while nothing is selected.
    private var draft: RequestDraft? = nil

    /// `focus`, an `operationId`, is selected when the window opens. Without one, or with an id the
    /// contract doesn't have, the first operation is.
    init(project: Project, focus: String?, store: any ContractStore) {
        self.project = project
        let contract = store.contract(of: project.id)
        self.contract = contract
        let focused = focus.flatMap { contract?.operation($0) }
        opensSelection = focused != nil
        // Staging when the project has one: the first place a change can be tried on.
        let preferred = project.deploymentEnvironments.first { $0.name == "Staging" } ?? project.deploymentEnvironments.first
        environmentName = preferred?.name ?? ""
        selection = (focused ?? contract?.operations.first)?.id
    }

    /// The selected operation's id. Selecting another operation starts its request from the
    /// contract's examples; nothing selected keeps the last request for the page that is going away.
    var selection: Operation.ID? {
        get { selectedID }
        set {
            guard newValue != selectedID else { return }
            selectedID = newValue
            if let operation = newValue.flatMap({ contract?.operation($0) }) {
                draft = RequestDraft(operation: operation)
            }
        }
    }

    var selectedOperation: Operation? {
        selectedID.flatMap { contract?.operation($0) }
    }

    func operation(_ id: Operation.ID) -> Operation? {
        contract?.operation(id)
    }

    /// Selects the operation a route asks for, even if it was selected before and the user picked
    /// another since. A filter that hides it is cleared, so that its row shows. An id the contract
    /// doesn't have changes nothing.
    func select(focus: String) {
        guard let operation = contract?.operation(focus) else { return }
        if !matches(operation) {
            query = ""
        }
        selection = operation.id
    }

    // MARK: Filter

    /// The filter's text, without surrounding spaces.
    var filterText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The operations the filter keeps, by tag, in the order each tag first appears in the contract.
    /// A tag without a match has no section.
    var sections: [OperationSection] {
        guard let contract else { return [] }
        let kept = contract.operations.filter(matches)
        return contract.tags.compactMap { tag in
            let operations = kept.filter { $0.tag == tag }
            return operations.isEmpty ? nil : OperationSection(tag: tag, operations: operations)
        }
    }

    /// The filter matches no operation.
    var hasNoMatches: Bool {
        contract != nil && !filterText.isEmpty && sections.isEmpty
    }

    /// Whether the filter keeps `operation`: its path, summary or `operationId` contains the text,
    /// ignoring case and diacritics.
    func matches(_ operation: Operation) -> Bool {
        let text = filterText
        guard !text.isEmpty else { return true }
        return operation.path.localizedStandardContains(text)
            || operation.summary.localizedStandardContains(text)
            || operation.id.localizedStandardContains(text)
    }

    // MARK: Request

    var environments: [DeploymentEnvironment] {
        project.deploymentEnvironments
    }

    /// The environment the request goes to; nil for a project without environments.
    var environment: DeploymentEnvironment? {
        project.deploymentEnvironments.first { $0.name == environmentName }
    }

    /// The request for `operation`: what the user typed while it stays selected, otherwise the
    /// contract's examples.
    func draft(for operation: Operation) -> RequestDraft {
        if let draft, draft.operation.id == operation.id {
            return draft
        }
        return RequestDraft(operation: operation)
    }

    /// Keeps what the user typed in the selected operation's request.
    func update(_ draft: RequestDraft) {
        guard draft.operation.id == selectedID else { return }
        self.draft = draft
    }

    /// An operation is selected and there is an environment to send it to.
    var canSend: Bool {
        selectedOperation != nil && environment != nil
    }

    /// Sends the request. Not wired yet: the sample data has no service to call.
    func send() {}

    // MARK: Chat

    /// The selected operation, which the chat panel beside the window asks about.
    var chatSubject: ChatReference? {
        selectedOperation.map { ContractsReader.reference($0, in: project) }
    }
}
