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
    let store: any ContractStore
    /// A focus waiting for the contract to be read.
    private var pendingFocus: String?
    /// A request on its way.
    private(set) var isSending = false
    /// Why an operation's last call got no answer, by operation.
    private(set) var failures: [Operation.ID: String] = [:]
    /// The answers of this window's calls, by operation.
    private(set) var responses: [Operation.ID: SampleResponse] = [:]
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
        self.store = store
        let contract = store.contract(of: project).value
        let focused = focus.flatMap { contract?.operation($0) }
        opensSelection = focused != nil || (contract == nil && focus != nil)
        pendingFocus = contract == nil ? focus : nil
        // The project's current environment; for a sample, Staging when it has one, the first place a change can
        // be tried on.
        let preferred = project.deploymentEnvironments.first { $0.name == project.currentEnvironment }
            ?? project.deploymentEnvironments.first { $0.name == "Staging" } ?? project.deploymentEnvironments.first
        environmentName = preferred?.name ?? ""
        selection = (focused ?? contract?.operations.first)?.id
    }

    /// The project's contract: on its way, read, unreadable, or none.
    var contractLoad: ContractLoad { store.contract(of: project) }
    var contract: Contract? { contractLoad.value }

    /// Reads the contract again, then selects a focus that waited for it, or the first operation.
    func refresh() async {
        await store.refresh(project)
        if let pendingFocus, contract?.operation(pendingFocus) != nil {
            self.pendingFocus = nil
            select(focus: pendingFocus)
        } else if selection == nil || selectedOperation == nil {
            selection = contract?.operations.first?.id
        }
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

    /// The request for `operation`: what the user typed while it stays selected, on the operation as the
    /// contract reads now, otherwise the contract's examples.
    func draft(for operation: Operation) -> RequestDraft {
        if let draft, draft.operation.id == operation.id {
            return draft.operation == operation ? draft : draft.rebased(on: operation)
        }
        return RequestDraft(operation: operation)
    }

    /// Keeps what the user typed in the selected operation's request.
    func update(_ draft: RequestDraft) {
        guard draft.operation.id == selectedID else { return }
        self.draft = draft
    }

    /// An operation is selected, there is an environment to send it to, and no request is on its way.
    var canSend: Bool {
        selectedOperation != nil && environment != nil && !isSending
    }

    /// Picks the environment requests go to; in the app it becomes the project's current one.
    func pickEnvironment(_ name: String) {
        environmentName = name
        store.setEnvironment(name, of: project)
    }

    /// Sends the selected operation's request; its answer, or why none came, shows in **Last Response**.
    func send() async {
        guard let operation = selectedOperation, let environment, !isSending else { return }
        isSending = true
        // A cancelled request's end leaves isSending to Cancel, which cleared it: a new Send may be out already.
        defer { if !Task.isCancelled { isSending = false } }
        do throws(ContractSendError) {
            let response = try await store.send(draft(for: operation), to: environment, of: project)
            // Cancel: Last Response keeps what it showed.
            guard !Task.isCancelled else { return }
            responses[operation.id] = response
            failures[operation.id] = nil
        } catch {
            guard !Task.isCancelled else { return }
            failures[operation.id] = error.message
        }
    }

    /// The request being sent, which Cancel stops, as V2's did.
    @ObservationIgnored private var sending: Task<Void, Never>?

    /// Send, from the toolbar: kept, so that Cancel can stop it.
    func startSend() {
        sending = Task { [weak self] in await self?.send() }
    }

    /// Cancel: stops the request being sent; the operation's Last Response stays as it was.
    func cancelSend() {
        sending?.cancel()
        sending = nil
        isSending = false
    }

    /// The answer shown for an operation: this window's last, else the store's, else a sample's.
    func response(for operation: Operation) -> SampleResponse? {
        responses[operation.id] ?? store.lastResponse(of: operation, in: project) ?? operation.lastResponse
    }

    // MARK: Chat

    /// The selected operation, which the chat panel beside the window asks about.
    var chatSubject: ChatReference? {
        selectedOperation.map { ContractsReader.reference($0, in: project) }
    }
}
