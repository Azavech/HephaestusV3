import Foundation
import Testing
import ToolsFoundation
@testable import ContractsKit

// `Operation` alone would also name Foundation's.
private typealias ContractOperation = ContractsKit.Operation

/// Contracts kept in memory, by project; a send answers `answer`, or fails with `failure`.
final class MockContractStore: ContractStore {
    var contracts: [Project.ID: Contract]
    var answer = SampleResponse(status: 201, duration: .milliseconds(12), bytes: 2, body: "{}")
    var failure: String?
    /// How long a send takes, for Cancel.
    var delay: Duration?
    private(set) var environments: [String] = []

    init(contracts: [Project.ID: Contract] = [:]) {
        self.contracts = contracts
    }

    func contract(of project: Project) -> ContractLoad { contracts[project.id].map(ContractLoad.loaded) ?? .none }
    func refresh(_ project: Project) async {}
    func send(_ draft: RequestDraft, to environment: DeploymentEnvironment, of project: Project) async throws(ContractSendError) -> SampleResponse {
        if let delay { try? await Task.sleep(for: delay) }
        if let failure { throw ContractSendError(message: failure) }
        return answer
    }
    func lastResponse(of operation: ContractsKit.Operation, in project: Project) -> SampleResponse? { nil }
    func setEnvironment(_ name: String, of project: Project) { environments.append(name) }
    func access(of project: Project) -> ContractAccess? { nil }
    func setAccess(_ access: ContractAccess, of project: Project) {}
}

/// A small contract: two tags, the Items tag coming back after Billing, a failing operation, and a
/// summary with a diacritic.
private let billing = Contract(
    title: "Billing API",
    version: "1.0.0",
    operations: [
        ContractOperation(
            id: "listItems", method: .get, path: "/items", summary: "List items", tag: "Items",
            parameters: [
                Parameter(name: "cursor", location: .query, type: "string", isRequired: false, example: ""),
                Parameter(name: "limit", location: .query, type: "integer", isRequired: false, example: "20"),
            ],
            requestBody: nil,
            responses: [DocumentedResponse(status: 200, description: "A page of items")],
            lastResponse: SampleResponse(status: 200, duration: .milliseconds(84), bytes: 1_486, body: "{}")
        ),
        ContractOperation(
            id: "createItem", method: .post, path: "/items", summary: "Create an item", tag: "Items",
            parameters: [Parameter(name: "Idempotency-Key", location: .header, type: "string", isRequired: true, example: "7f1c")],
            requestBody: "{ \"name\": \"pen\" }",
            responses: [DocumentedResponse(status: 201, description: "The new item")],
            lastResponse: SampleResponse(status: 201, duration: .milliseconds(230), bytes: 312, body: "{}")
        ),
        ContractOperation(
            id: "payInvoice", method: .post, path: "/invoices/{id}/pay", summary: "Pay an invoice", tag: "Billing",
            parameters: [Parameter(name: "id", location: .path, type: "string", isRequired: true, example: "88")],
            requestBody: "{}",
            responses: [DocumentedResponse(status: 201, description: "Paid")],
            lastResponse: SampleResponse(status: 504, duration: .milliseconds(4_210), bytes: 96, body: "{}")
        ),
        ContractOperation(
            id: "findCafe", method: .get, path: "/cafes", summary: "Find a café", tag: "Items",
            parameters: [], requestBody: nil,
            responses: [DocumentedResponse(status: 200, description: "The cafés")],
            lastResponse: SampleResponse(status: 200, duration: .milliseconds(2), bytes: 15, body: "{}")
        ),
    ]
)

private func environment(_ name: String) -> DeploymentEnvironment {
    DeploymentEnvironment(
        name: name, cluster: "c", namespace: "n", url: "https://\(name.lowercased()).example.com", health: .healthy
    )
}

private func project(id: Project.ID = "BIL", environments: [String] = ["Local", "Staging", "Production"]) -> Project {
    Project(
        id: id, name: "Billing", kind: .service, tint: .accent, symbol: "creditcard", path: "~/billing",
        repository: "services/billing", environments: environments.map(environment),
        activity: ProjectActivity(
            openTickets: 0, ticketsInReview: 0, draftTickets: 0, lastBuild: .passed, lastBuildAt: .distantPast,
            contractVersion: "1.0.0", operationCount: 4
        )
    )
}

private let store = MockContractStore(contracts: ["BIL": billing])

private func makeModel(focus: String? = nil, environments: [String] = ["Local", "Staging", "Production"]) -> ContractsModel {
    ContractsModel(project: project(environments: environments), focus: focus, store: store)
}

private let english = Locale(identifier: "en_US")

@Suite("Opening")
struct OpeningTests {
    @Test("Without a focus, the first operation is selected and the list starts on the iPhone")
    func noFocus() {
        let model = makeModel()
        #expect(model.selection == "listItems")
        #expect(model.opensSelection == false)
    }

    @Test("A focus selects its operation and opens its page on the iPhone")
    func focus() {
        let model = makeModel(focus: "payInvoice")
        #expect(model.selection == "payInvoice")
        #expect(model.selectedOperation?.path == "/invoices/{id}/pay")
        #expect(model.opensSelection)
    }

    @Test("An operation the contract doesn't have opens on the first one, not on an empty page")
    func unknownFocus() {
        let model = makeModel(focus: "deleteEverything")
        #expect(model.selection == "listItems")
        #expect(model.opensSelection == false)
    }

    @Test("A project without a contract has nothing to select")
    func noContract() {
        let model = ContractsModel(project: project(id: "APP"), focus: "listItems", store: store)
        #expect(model.contract == nil)
        #expect(model.selection == nil)
        #expect(model.sections.isEmpty)
        #expect(model.hasNoMatches == false)
        #expect(model.chatSubject == nil)
        #expect(model.canSend == false)
    }

    @Test("The environment starts on Staging, else on the first one")
    func environment() {
        #expect(makeModel().environmentName == "Staging")
        #expect(makeModel(environments: ["Local", "Production"]).environmentName == "Local")
        #expect(makeModel(environments: []).environment == nil)
    }
}

@Suite("Route focus")
struct FocusTests {
    @Test("A second route to the same operation selects it again after the user picked another")
    func sameOperationAgain() {
        let model = makeModel(focus: "payInvoice")
        model.selection = "createItem"
        model.select(focus: "payInvoice")
        #expect(model.selection == "payInvoice")
    }

    @Test("A route selects its operation after Back cleared the selection")
    func afterBack() {
        let model = makeModel(focus: "payInvoice")
        model.selection = nil
        model.select(focus: "payInvoice")
        #expect(model.selection == "payInvoice")
    }

    @Test("An operation the contract doesn't have changes nothing")
    func unknownOperation() {
        let model = makeModel(focus: "createItem")
        model.select(focus: "nothing")
        #expect(model.selection == "createItem")
    }

    @Test("A filter that hides the operation is cleared; one that shows it stays")
    func filter() {
        let model = makeModel()
        model.query = "items"
        model.select(focus: "payInvoice")
        #expect(model.query.isEmpty)
        #expect(model.selection == "payInvoice")

        model.query = "item"
        model.select(focus: "createItem")
        #expect(model.query == "item")
        #expect(model.selection == "createItem")
    }

    @Test("A route to the operation already selected keeps what the user typed")
    func keepsDraft() throws {
        let model = makeModel(focus: "payInvoice")
        let operation = try #require(model.selectedOperation)
        var draft = model.draft(for: operation)
        draft.body = "{ \"amount\": 1 }"
        model.update(draft)
        model.select(focus: "payInvoice")
        #expect(model.draft(for: operation).body == "{ \"amount\": 1 }")
    }
}

@Suite("Filter")
struct FilterTests {
    @Test("Sections follow the order in which each tag first appears, with every operation of the tag")
    func sections() {
        let sections = makeModel().sections
        #expect(sections.map(\.tag) == ["Items", "Billing"])
        #expect(sections.first?.operations.map(\.id) == ["listItems", "createItem", "findCafe"])
        #expect(billing.tags == ["Items", "Billing"])
    }

    @Test("Matches the path, the summary or the operation id, ignoring case and diacritics", arguments: [
        ("/invoices", ["payInvoice"]),
        ("PAY AN", ["payInvoice"]),
        ("createitem", ["createItem"]),
        ("cafe", ["findCafe"]),
        ("  invoice  ", ["payInvoice"]),
    ])
    func matches(query: String, ids: [String]) {
        let model = makeModel()
        model.query = query
        #expect(model.sections.flatMap(\.operations).map(\.id) == ids)
    }

    @Test("A tag without a match loses its section")
    func dropsSection() {
        let model = makeModel()
        model.query = "invoice"
        #expect(model.sections.map(\.tag) == ["Billing"])
    }

    @Test("No match shows the No Matching Operations state; spaces alone filter nothing")
    func noMatches() {
        let model = makeModel()
        model.query = "zzz"
        #expect(model.hasNoMatches)
        #expect(model.filterText == "zzz")
        model.query = "   "
        #expect(model.hasNoMatches == false)
        #expect(model.sections.flatMap(\.operations).count == 4)
    }

    @Test("The filter keeps the selection, even of an operation it hides")
    func keepsSelection() {
        let model = makeModel(focus: "payInvoice")
        model.query = "items"
        #expect(model.selection == "payInvoice")
        #expect(model.selectedOperation?.id == "payInvoice")
    }
}

@Suite("Request")
struct RequestTests {
    @Test("A request starts from the contract's examples")
    func examples() throws {
        let model = makeModel(focus: "createItem")
        let operation = try #require(model.selectedOperation)
        let draft = model.draft(for: operation)
        #expect(draft.body == "{ \"name\": \"pen\" }")
        #expect(draft[operation.parameters[0]] == "7f1c")
    }

    @Test("The URL fills the path, adds the query parameters that have a value, and leaves headers out")
    func url() throws {
        let list = try #require(billing.operation("listItems"))
        var draft = RequestDraft(operation: list)
        let staging = environment("Staging")
        #expect(draft.url(on: staging) == "https://staging.example.com/items?limit=20")
        draft[list.parameters[0]] = "abc"
        #expect(draft.url(on: staging) == "https://staging.example.com/items?cursor=abc&limit=20")

        let pay = try #require(billing.operation("payInvoice"))
        var payment = RequestDraft(operation: pay)
        payment[pay.parameters[0]] = "91"
        #expect(payment.url(on: environment("Local")) == "https://local.example.com/invoices/91/pay")

        let create = try #require(billing.operation("createItem"))
        #expect(RequestDraft(operation: create).url(on: staging) == "https://staging.example.com/items")
    }

    @Test("The environment changes the URL; the values stay")
    func environmentChange() throws {
        let model = makeModel(focus: "payInvoice")
        let operation = try #require(model.selectedOperation)
        var draft = model.draft(for: operation)
        draft[operation.parameters[0]] = "91"
        model.update(draft)
        model.environmentName = "Production"
        let production = try #require(model.environment)
        #expect(model.draft(for: operation).url(on: production) == "https://production.example.com/invoices/91/pay")
    }

    @Test("Picking another operation and coming back restores the examples")
    func valuesAreNotKept() throws {
        let model = makeModel(focus: "payInvoice")
        let operation = try #require(model.selectedOperation)
        var draft = model.draft(for: operation)
        draft.body = "edited"
        model.update(draft)
        #expect(model.draft(for: operation).body == "edited")
        model.selection = "listItems"
        model.selection = "payInvoice"
        #expect(model.draft(for: operation).body == "{}")
    }

    @Test("After Back, the page that goes away keeps its request; opening it again restores the examples")
    func back() throws {
        let model = makeModel(focus: "payInvoice")
        let operation = try #require(model.selectedOperation)
        var draft = model.draft(for: operation)
        draft.body = "edited"
        model.update(draft)
        model.selection = nil
        #expect(model.draft(for: operation).body == "edited")
        model.selection = "payInvoice"
        #expect(model.draft(for: operation).body == "{}")
    }

    @Test("A request typed for the selected operation follows the contract when it changes, what was typed kept")
    func draftFollowsContract() throws {
        let store = MockContractStore(contracts: ["BIL": billing])
        let model = ContractsModel(project: project(environments: ["Local"]), focus: "payInvoice", store: store)
        var draft = model.draft(for: try #require(model.operation("payInvoice")))
        draft.body = "{\"amount\": 3}"
        model.update(draft)
        let pay = try #require(billing.operations.first { $0.id == "payInvoice" })
        let changed = ContractOperation(
            id: "payInvoice", method: .post, path: pay.path, summary: "Pay an invoice now", tag: pay.tag,
            parameters: pay.parameters + [Parameter(name: "expand", location: .query, type: "string", isRequired: true, example: "items")],
            requestBody: pay.requestBody, responses: pay.responses, lastResponse: pay.lastResponse
        )
        store.contracts["BIL"] = Contract(title: billing.title, version: billing.version,
                                          operations: billing.operations.map { $0.id == "payInvoice" ? changed : $0 })
        let rebased = model.draft(for: try #require(model.operation("payInvoice")))
        #expect(rebased.operation.summary == "Pay an invoice now")
        #expect(rebased.body == "{\"amount\": 3}")
        #expect(rebased.url(on: environment("Local")) == "https://local.example.com/invoices/88/pay?expand=items")
    }

    @Test("A request for an operation that isn't selected is not kept")
    func updateOfAnother() throws {
        let model = makeModel(focus: "payInvoice")
        let other = try #require(model.operation("createItem"))
        var draft = model.draft(for: other)
        draft.body = "edited"
        model.update(draft)
        #expect(model.draft(for: other).body == "{ \"name\": \"pen\" }")
    }

    @Test("Send needs an operation and an environment with a URL; what the settings lack says so, as V2's did")
    func canSend() {
        #expect(makeModel().canSend)
        #expect(makeModel().missingSetting == nil)
        let none = makeModel(environments: [])
        #expect(none.canSend == false)
        #expect(none.missingSetting == "Add an environment in Project Settings.")
        let model = makeModel()
        model.selection = nil
        #expect(model.canSend == false)
        var withoutURL = project(environments: [])
        withoutURL = Project(id: withoutURL.id, name: withoutURL.name, kind: withoutURL.kind, tint: withoutURL.tint, symbol: withoutURL.symbol,
                             path: withoutURL.path, repository: withoutURL.repository,
                             environments: [DeploymentEnvironment(name: "Staging", cluster: "c", namespace: "n", url: " ", health: .healthy)],
                             activity: withoutURL.activity)
        let noURL = ContractsModel(project: withoutURL, focus: nil, store: store)
        #expect(noURL.canSend == false)
        #expect(noURL.missingSetting == "Set the URL of Staging in Project Settings.")
    }
}

@Suite("Responses")
struct ResponseTests {
    @Test("Last Response lays out at most the first 100 KB of a body, cut at a line's end")
    func shownBody() {
        let small = SampleResponse(status: 200, duration: .zero, bytes: 2, body: "{}")
        #expect(small.shownBody == ("{}", false))
        let line = String(repeating: "x", count: 99) + "\n"
        let large = SampleResponse(status: 200, duration: .zero, bytes: 0, body: String(repeating: line, count: 5_000))
        let shown = large.shownBody
        #expect(shown.isCut && shown.text.utf8.count <= SampleResponse.shownLimit && shown.text.utf8.count > SampleResponse.shownLimit - 2_000)
        #expect(!shown.text.hasSuffix("\n") && shown.text.hasSuffix("x"), "Cut at a line's end")
    }

    @Test("Durations read in milliseconds below a second, in seconds with one decimal from a second", arguments: [
        (2, "2 ms"), (84, "84 ms"), (999, "999 ms"), (1_000, "1.0 sec"), (4_210, "4.2 sec"),
    ])
    func duration(milliseconds: Int, text: String) {
        let response = SampleResponse(status: 200, duration: .milliseconds(milliseconds), bytes: 0, body: "")
        #expect(response.duration.formatted(response.durationStyle.locale(english)) == text)
    }

    @Test("A status from 400 is an error")
    func errors() {
        #expect(SampleResponse(status: 399, duration: .zero, bytes: 0, body: "").isError == false)
        #expect(SampleResponse(status: 400, duration: .zero, bytes: 0, body: "").isError)
        #expect(SampleResponse(status: 504, duration: .zero, bytes: 0, body: "").isError)
    }
}

@Suite("Reader and chat")
struct ReaderTests {
    @Test("Reads an operation as whole sentences")
    func read() throws {
        let reading = try #require(ContractsReader.read("payInvoice", project: project(), store: store, locale: english))
        #expect(reading.action == "Read operation payInvoice")
        #expect(reading.detail == "Pay an invoice: POST /invoices/{id}/pay, in Billing API 1.0.0. Its last call answered 504 after 4.2 sec.")
    }

    @Test("Suggests asking why a failed call failed, first")
    func failedSuggestions() throws {
        let reading = try #require(ContractsReader.read("payInvoice", project: project(), store: store, locale: english))
        #expect(reading.suggestions == ["Why did payInvoice answer 504?", "Show an example request for payInvoice"])
    }

    @Test("Suggests an example request and what an operation returns when its last call succeeded")
    func suggestions() throws {
        let reading = try #require(ContractsReader.read("createItem", project: project(), store: store, locale: english))
        #expect(reading.suggestions == ["Show an example request for createItem", "What does createItem return?"])
    }

    @Test("Reads nothing for an unknown operation or a project without a contract")
    func readsNothing() {
        #expect(ContractsReader.read("nothing", project: project(), store: store) == nil)
        #expect(ContractsReader.read("payInvoice", project: project(id: "APP"), store: store) == nil)
    }

    @Test("Reads the sample contracts by default")
    func sample() throws {
        let orders = try #require(Project.sample("ORD"))
        let reading = try #require(ContractsReader.read("checkoutOrder", project: orders, store: nil))
        #expect(reading.action.contains("checkoutOrder"))
        #expect(reading.detail.contains("POST /orders/{id}/checkout"))
        #expect(reading.suggestions.count == 2)
    }

    @Test("The chat panel asks about the selected operation, by its operation id")
    func chatSubject() {
        let model = makeModel(focus: "payInvoice")
        #expect(model.chatSubject == ChatReference(tool: .contracts, projectID: "BIL", focus: "payInvoice", title: "payInvoice"))
        model.selection = nil
        #expect(model.chatSubject == nil)
    }
}

@Suite("Sample contracts")
struct SampleTests {
    @Test("Orders, Payments and Edge Gateway have a contract; other projects don't")
    func contracts() {
        let store = SampleContractStore()
        #expect(store.contract(of: "ORD")?.operations.count == 6)
        #expect(store.contract(of: "PAY")?.operations.count == 4)
        #expect(store.contract(of: "GW")?.operations.count == 3)
        #expect(store.contract(of: "SHOP") == nil)
        #expect(store.contract(of: "TLS") == nil)
    }

    @Test("Payments lists listCharges under Charges, above Refunds")
    func paymentsSections() throws {
        let payments = try #require(Project.sample("PAY"))
        let model = ContractsModel(project: payments, focus: nil, store: SampleContractStore())
        #expect(model.sections.map(\.tag) == ["Charges", "Refunds"])
        #expect(model.sections.first?.operations.map(\.id) == ["createCharge", "getCharge", "listCharges"])
    }
}


@Suite("Sending")
@MainActor
struct ContractSendTests {
    @Test("Send shows the answer, or why none came; the environment picked becomes the project's")
    func send() async throws {
        let store = MockContractStore(contracts: ["ORD": try #require(SampleContractStore().contract(of: "ORD"))])
        let orders = try #require(Project.sample("ORD"))
        let model = ContractsModel(project: orders, focus: "listOrders", store: store)
        let operation = try #require(model.selectedOperation)
        await model.send()
        #expect(model.response(for: operation)?.status == 201)
        store.failure = "Could not connect to the server."
        await model.send()
        #expect(model.failures[operation.id] == "Could not connect to the server.")
        model.pickEnvironment("Production")
        #expect(store.environments == ["Production"] && model.environmentName == "Production")
    }

    @Test("A tab's model takes the project as loaded now: a new environment applies, the picked one stays while it exists")
    func projectUpdate() {
        let store = MockContractStore(contracts: ["BIL": billing])
        let model = ContractsModel(project: project(environments: ["Local"]), focus: nil, store: store)
        #expect(model.environments.map(\.name) == ["Local"])
        model.update(project: project(environments: ["Local", "Staging"]))
        #expect(model.environments.map(\.name) == ["Local", "Staging"] && model.environmentName == "Local")
        model.update(project: project(environments: ["Staging"]))
        #expect(model.environmentName == "Staging" && model.environment?.url == "https://staging.example.com")
    }

    @Test("Cancel stops a request being sent: Send comes back and Last Response keeps what it showed")
    func cancel() async throws {
        let store = MockContractStore(contracts: ["ORD": try #require(SampleContractStore().contract(of: "ORD"))])
        store.delay = .milliseconds(300)
        store.answer = SampleResponse(status: 500, duration: .milliseconds(1), bytes: 2, body: "{}")
        let model = ContractsModel(project: try #require(Project.sample("ORD")), focus: "listOrders", store: store)
        let operation = try #require(model.selectedOperation)
        let before = model.response(for: operation)
        model.startSend()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isSending)
        model.cancelSend()
        #expect(!model.isSending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.response(for: operation) == before && model.failures[operation.id] == nil)
    }
}
