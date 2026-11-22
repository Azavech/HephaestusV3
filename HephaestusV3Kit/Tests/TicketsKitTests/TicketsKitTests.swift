import AppKit
import Foundation
import SwiftUI
import Testing
import ToolsFoundation
@testable import TicketsKit

/// Tickets and bundles given by each test, in the order given.
struct MockTicketStore: TicketStore {
    var allTickets: [Ticket]
    var allBundles: [TicketBundle] = []

    func tickets(of projects: Set<Project.ID>) -> [Ticket] {
        allTickets.filter { projects.contains($0.projectID) }
    }

    func bundles(of projects: Set<Project.ID>) -> [TicketBundle] {
        allBundles.filter { projects.contains($0.projectID) }
    }

    func ticket(_ id: Ticket.ID) -> Ticket? {
        allTickets.first { $0.id == id }
    }
}

/// A ticket with only what a test looks at.
func ticket(
    _ id: String, in projectID: Project.ID, _ status: TicketStatus = .created, priority: TicketPriority = .medium,
    title: String = "A ticket"
) -> Ticket {
    Ticket(
        id: id, projectID: projectID, title: title, details: "", status: status, priority: priority, labels: [],
        reporter: "You", createdAt: SampleClock.date(), updatedAt: SampleClock.date(), links: [], events: []
    )
}

/// Shop's family as the sample tree has it: Shop, then Orders, Payments and Edge Gateway. The store
/// lists the sub projects' tickets before the parent's, as the sample data does.
let familyStore = MockTicketStore(
    allTickets: [
        ticket("ORD-2", in: "ORD", .inProgress),
        ticket("ORD-1", in: "ORD", .done),
        ticket("PAY-1", in: "PAY", .draft),
        ticket("SHOP-1", in: "SHOP", .inProgress),
        ticket("SHOP-2", in: "SHOP", .draft),
        ticket("TLS-1", in: "TLS", .inReview),
    ],
    allBundles: [
        TicketBundle(id: "ORD-B1", projectID: "ORD", title: "Checkout", ticketIDs: ["ORD-2", "ORD-1"]),
        TicketBundle(id: "SHOP-B1", projectID: "SHOP", title: "Cluster move", ticketIDs: ["SHOP-1"]),
    ]
)

func model(_ projectID: Project.ID, focus: String? = nil, filter: TicketFilter = .all, store: MockTicketStore = familyStore) -> TicketsModel {
    TicketsModel(project: Project.sample(projectID)!, focus: focus, filter: filter, store: store)
}

@Suite("The store")
struct TicketStoreTests {
    @Test("Lists the tickets and bundles of the projects asked for")
    func listsByProject() {
        #expect(familyStore.tickets(of: ["ORD"]).map(\.id) == ["ORD-2", "ORD-1"])
        #expect(familyStore.bundles(of: ["SHOP"]).map(\.id) == ["SHOP-B1"])
        #expect(familyStore.ticket("PAY-1")?.projectID == "PAY")
        #expect(familyStore.ticket("NOPE-1") == nil)
    }

    @Test("Counts a status with or without the sub projects")
    func countsByStatus() {
        #expect(familyStore.count(of: .inProgress, in: "SHOP", includingSubprojects: false) == 1)
        #expect(familyStore.count(of: .inProgress, in: "SHOP", includingSubprojects: true) == 2)
        #expect(familyStore.count(of: .draft, in: "SHOP", includingSubprojects: true) == 2)
    }

    @Test("The sample store holds the sample tickets")
    func sampleStore() {
        let store = SampleTicketStore()
        #expect(store.tickets(of: ["ORD"]).count == 6)
        #expect(store.tickets(of: Set(Project.tree.family(of: "SHOP").map(\.id))).count == 12)
        #expect(store.bundles(of: ["ORD"]).map(\.id) == ["ORD-B3", "ORD-B2"])
    }
}

@Suite("The list")
struct TicketListTests {
    @Test("A parent's list groups its tickets by project, the parent first, in tree order")
    func groupsByProject() {
        let shop = model("SHOP")
        #expect(shop.isGrouped)
        #expect(shop.groups.map(\.id) == ["SHOP", "ORD", "PAY"])
        #expect(shop.visibleTickets.map(\.id) == ["SHOP-1", "SHOP-2", "ORD-2", "ORD-1", "PAY-1"])
        #expect(shop.listState == .grouped(shop.groups))
    }

    @Test("A filter keeps the groups and drops the empty ones")
    func filterKeepsGroups() {
        let shop = model("SHOP", filter: .status(.draft))
        #expect(shop.groups.map(\.id) == ["SHOP", "PAY"])
        #expect(shop.visibleTickets.map(\.id) == ["SHOP-2", "PAY-1"])
    }

    @Test("A project without sub projects lists its tickets in the store's order")
    func flatList() {
        let orders = model("ORD")
        #expect(!orders.isGrouped)
        #expect(orders.listState == .loaded(orders.visibleTickets))
        #expect(orders.visibleTickets.map(\.id) == ["ORD-2", "ORD-1"])
    }

    @Test("A project filter lets through the project and its own sub projects")
    func projectFilter() {
        let shop = model("SHOP", filter: .project("ORD"))
        #expect(shop.visibleTickets.map(\.id) == ["ORD-2", "ORD-1"])
        #expect(model("SHOP", filter: .project("SHOP")).visibleTickets.count == 5)
    }

    @Test("A bundle filter lets through the bundle's tickets")
    func bundleFilter() {
        #expect(model("ORD", filter: .bundle("ORD-B1")).visibleTickets.map(\.id) == ["ORD-2", "ORD-1"])
    }

    @Test("A project without tickets reads as empty")
    func emptyProject() {
        #expect(model("AZD").listState == .empty)
        #expect(model("AZD", filter: .status(.done)).listState == .empty)
    }

    @Test("A filter with no match says so, and Show All Tickets clears it")
    func noMatch() {
        let tools = model("TLS", filter: .status(.done))
        #expect(tools.listState == .noMatch("No ticket is done."))
        tools.showAllTickets()
        #expect(tools.filter == .all)
        #expect(tools.listState == .grouped(tools.groups))
        #expect(model("ORD", filter: .status(.draft)).listState == .noMatch("No ticket is a draft."))
        #expect(model("SHOP", filter: .project("GW")).listState == .noMatch("Edge Gateway has no tickets."))
    }

    @Test("The sidebar and the Filter menu list their sections in one order")
    func sectionOrder() {
        #expect(model("SHOP").filterSections == [.status, .projects, .bundles])
        #expect(model("ORD").filterSections == [.status, .bundles])
        #expect(model("TLS").filterSections == [.status, .projects, .bundles])
        #expect(model("AZD").filterSections == [.status, .bundles])
    }

    @Test("Counts cover the window's tickets before any filter")
    func counts() {
        let shop = model("SHOP", filter: .status(.done))
        #expect(shop.count(.all) == 5)
        #expect(shop.count(.status(.inProgress)) == 2)
        #expect(shop.count(.project("ORD")) == 2)
        #expect(shop.count(.project("SHOP")) == 5)
        let orders = model("ORD")
        #expect(orders.doneCount(of: orders.bundles[0]) == 1)
    }

    @Test("A parent's sidebar lists only its own bundles")
    func ownBundles() {
        #expect(model("SHOP").bundles.map(\.id) == ["SHOP-B1"])
        #expect(model("ORD").bundles.map(\.id) == ["ORD-B1"])
    }

    @Test("The filter's name and whether one applies")
    func filterNames() {
        let shop = model("SHOP")
        #expect(!shop.isFiltered)
        shop.filter = nil
        #expect(!shop.isFiltered)
        shop.filter = .project("PAY")
        #expect(shop.isFiltered)
        #expect(shop.title(of: .project("PAY")) == "Payments")
        #expect(shop.title(of: .bundle("SHOP-B1")) == "Cluster move")
        #expect(shop.title(of: .status(.inReview)) == TicketStatus.inReview.title)
        #expect(shop.title(of: .all) == "All Tickets")
    }
}

@Suite("Selection and route focus")
struct TicketSelectionTests {
    @Test("Without a focus, the first row of the list is selected")
    func firstRow() {
        #expect(model("ORD").selection == "ORD-2")
        // The parent's own tickets come first in its list, though the store lists them later.
        #expect(model("SHOP").selection == "SHOP-1")
        #expect(model("AZD").selection == nil)
        #expect(!model("SHOP").opensSelection)
    }

    @Test("The first focus arrives with the window and opens its page on an iPhone")
    func initialFocus() {
        let shop = model("SHOP", focus: "PAY-1")
        #expect(shop.selection == "PAY-1")
        #expect(shop.selectedTicket?.id == "PAY-1")
        #expect(shop.opensSelection)
    }

    @Test("A route to the ticket selected before selects it again after the user picked another")
    func sameTicketAgain() {
        let orders = model("ORD", focus: "ORD-1")
        orders.selection = "ORD-2"
        orders.select(focus: "ORD-1")
        #expect(orders.selection == "ORD-1")
    }

    @Test("A route to a ticket the filter hides shows every ticket")
    func focusClearsHidingFilter() {
        let orders = model("ORD", filter: .status(.done))
        orders.select(focus: "ORD-2")
        #expect(orders.filter == .all)
        #expect(orders.selection == "ORD-2")
        let shown = model("ORD", filter: .status(.inProgress))
        shown.select(focus: "ORD-2")
        #expect(shown.filter == .status(.inProgress))
    }

    @Test("A focus that names no ticket of the window is reported as missing")
    func unknownFocus() {
        let orders = model("ORD", focus: "ORD-999")
        #expect(orders.selectedTicket == nil)
        #expect(orders.missingSelection == "ORD-999")
        #expect(orders.chatSubject == nil)
        orders.select(focus: "ORD-2")
        #expect(orders.missingSelection == nil)
        let filtered = model("ORD", filter: .status(.done))
        filtered.select(focus: "PAY-1")
        #expect(filtered.filter == .status(.done))
        #expect(filtered.missingSelection == "PAY-1")
        #expect(model("ORD").missingSelection == nil)
    }

    @Test("The chat asks about the selected ticket, in its own project")
    func chatSubject() {
        let shop = model("SHOP", focus: "ORD-2")
        #expect(shop.chatSubject == ChatReference(tool: .tickets, projectID: "ORD", focus: "ORD-2", title: "ORD-2"))
        shop.selection = nil
        #expect(shop.chatSubject == nil)
    }

    @Test("A sub project's ticket shows its bundle in a parent's window")
    func bundleInParent() {
        let shop = model("SHOP")
        #expect(shop.bundles(of: familyStore.ticket("ORD-2")!).map(\.id) == ["ORD-B1"])
        #expect(shop.bundles(of: familyStore.ticket("SHOP-1")!).map(\.id) == ["SHOP-B1"])
        #expect(shop.bundles(of: familyStore.ticket("PAY-1")!).isEmpty)
    }
}

@Suite("Comments")
struct TicketCommentTests {
    @Test("Each ticket keeps its own comment draft")
    func draftPerTicket() {
        let orders = model("ORD")
        orders.setCommentDraft("Backoff is in.", for: "ORD-2")
        #expect(orders.commentDraft(for: "ORD-1") == "")
        #expect(orders.commentDraft(for: "ORD-2") == "Backoff is in.")
        orders.setCommentDraft("", for: "ORD-2")
        #expect(orders.commentDrafts.isEmpty)
    }
}

@Suite("New Ticket")
struct NewTicketTests {
    @Test("The sheet opens empty, for the window's project")
    func opensEmpty() {
        let shop = model("SHOP")
        shop.draft.title = "Left over"
        shop.startNewTicket()
        #expect(shop.isComposing)
        #expect(shop.draft == NewTicketDraft(projectID: "SHOP"))
        #expect(shop.newTicketProjects.map(\.id) == ["SHOP", "ORD", "PAY", "GW"])
    }

    @Test("The project picked in the sidebar is the new ticket's project")
    func defaultsToFilteredProject() {
        let shop = model("SHOP", filter: .project("PAY"))
        shop.startNewTicket()
        #expect(shop.draft.projectID == "PAY")
        shop.filter = .status(.draft)
        shop.startNewTicket()
        #expect(shop.draft.projectID == "SHOP")
        #expect(model("ORD").newTicketProjects.map(\.id) == ["ORD"])
    }

    @Test("A title of spaces only can't be created; a created ticket is selected")
    func blankTitle() async {
        let store = SampleTicketStore()
        let orders = TicketsModel(project: Project.sample("ORD")!, focus: nil, filter: .status(.done), store: store)
        orders.startNewTicket()
        orders.draft.title = "  \n "
        #expect(!orders.draft.canCreate)
        await orders.createNewTicket()
        #expect(orders.isComposing)
        orders.draft.title = " Slow search "
        #expect(orders.draft.canCreate)
        await orders.createNewTicket()
        #expect(!orders.isComposing)
        #expect(orders.selectedTicket?.title == "Slow search")
        #expect(orders.selectedTicket?.status == .draft)
        #expect(orders.filter == .all)
    }

    @Test("A failed creation keeps the sheet open and shows why")
    func failedCreation() async {
        let orders = model("ORD")
        orders.startNewTicket()
        orders.draft.title = "Slow search"
        await orders.createNewTicket()
        #expect(orders.isComposing)
        #expect(orders.failure == "This store doesn't change tickets.")
    }

    @Test("Cancel closes the sheet")
    func cancel() {
        let orders = model("ORD")
        orders.startNewTicket()
        orders.cancelNewTicket()
        #expect(!orders.isComposing)
    }
}

@Suite("The reader")
struct TicketsReaderTests {
    let store = MockTicketStore(allTickets: [
        ticket("ORD-142", in: "ORD", .inProgress, priority: .urgent, title: "Retry storm between checkout and payments"),
        ticket("ORD-141", in: "ORD", .draft, priority: .low, title: "Document cursor pagination"),
        ticket("ORD-130", in: "ORD", .done, priority: .low, title: "Customer id in logs"),
    ])

    @Test("Reads a ticket in whole sentences")
    func readsTicket() throws {
        let reading = try #require(TicketsReader.read("ORD-142", store: store))
        #expect(reading.action == "Read ticket ORD-142")
        #expect(reading.detail == "“Retry storm between checkout and payments” is in progress, with urgent priority.")
        #expect(TicketsReader.read("ORD-141", store: store)?.detail == "“Document cursor pagination” is a draft, with low priority.")
        #expect(TicketsReader.read("ORD-130", store: store)?.detail == "“Customer id in logs” is done. Its priority was low.")
    }

    @Test("Suggests the questions the ticket's status raises")
    func suggestions() {
        #expect(TicketsReader.read("ORD-142", store: store)?.suggestions == ["What's left before ORD-142 can go to review?", "Summarize ORD-142"])
        #expect(TicketsReader.read("ORD-141", store: store)?.suggestions == ["Is ORD-141 ready to create?", "Summarize ORD-141"])
        #expect(TicketsReader.read("ORD-130", store: store)?.suggestions == ["What did ORD-130 change?", "Summarize ORD-130"])
    }

    @Test("Every status and priority has its sentence")
    func everyCombination() {
        for status in TicketStatus.allCases {
            for priority in TicketPriority.allCases {
                let detail = TicketsReader.detail(of: ticket("X-1", in: "ORD", status, priority: priority, title: "T"))
                #expect(detail.hasPrefix("“T”"))
                #expect(detail.contains(priority.rawValue))
            }
        }
    }

    @Test("A focus that names no ticket reads nothing")
    func unknownTicket() {
        #expect(TicketsReader.read("ORD-999", store: store) == nil)
        #expect(TicketsReader.read("", store: store) == nil)
    }

    @Test("The public reader answers from the sample tickets")
    func sampleReader() {
        #expect(TicketsReader.read("ORD-142", store: nil)?.action == "Read ticket ORD-142")
        #expect(TicketsReader.read("TKIT-4", store: nil) != nil)
    }
}

@Suite("Changes")
struct TicketChangeTests {
    private func orders() -> (TicketsModel, SampleTicketStore) {
        let store = SampleTicketStore()
        return (TicketsModel(project: Project.sample("ORD")!, focus: "ORD-141", store: store), store)
    }

    @Test("The next step moves a ticket one status forward; the status menu sets any")
    func status() async {
        let (model, store) = orders()
        let draft = model.selectedTicket!
        await model.nextStep(of: draft)
        #expect(store.ticket("ORD-141")?.status == .created)
        await model.setStatus(.done, of: ["ORD-141"])
        #expect(model.selectedTicket?.status == .done)
        await model.nextStep(of: model.selectedTicket!)
        #expect(store.changes.count == 2)
        #expect(TicketStatus.allCases.map(\.next) == [.created, .inProgress, .inReview, .done, nil])
    }

    @Test("A comment is sent with its files; the field empties only once it is added")
    func comments() async {
        let (model, store) = orders()
        #expect(!model.canComment(on: "ORD-141"))
        model.attach([URL(fileURLWithPath: "/tmp/a.log")], to: "ORD-141")
        #expect(model.canComment(on: "ORD-141"))
        model.setCommentDraft("Looks good", for: "ORD-141")
        await model.sendComment(on: "ORD-141")
        #expect(model.commentDraft(for: "ORD-141") == "")
        #expect(model.files(for: "ORD-141").isEmpty)
        #expect(store.changes == [.addComment("ORD-141", text: "Looks good", files: [URL(fileURLWithPath: "/tmp/a.log")])])
        let failing = TicketsModel(project: Project.sample("ORD")!, focus: "ORD-2", store: familyStore)
        failing.setCommentDraft("Kept", for: "ORD-2")
        await failing.sendComment(on: "ORD-2")
        #expect(failing.commentDraft(for: "ORD-2") == "Kept")
        #expect(failing.failure != nil)
    }

    @Test("Editing saves the title, description, priority and labels together")
    func editing() async {
        let (model, store) = orders()
        model.startEditing(model.selectedTicket!)
        model.edit?.title = "Cursor pagination"
        model.edit?.labels = "docs, , api "
        model.edit?.priority = nil
        await model.saveEditing()
        #expect(model.edit == nil)
        let ticket = store.ticket("ORD-141")!
        #expect(ticket.title == "Cursor pagination" && ticket.labels == ["docs", "api"] && ticket.priority == nil)
    }

    @Test("The editor's binding outlives Save and Cancel: it reads the last edit and opens nothing again")
    func editBinding() async {
        let (model, _) = orders()
        model.startEditing(model.selectedTicket!)
        let binding = model.editBinding(model.edit!)
        binding.wrappedValue.title = "Cursor pagination"
        #expect(model.edit?.title == "Cursor pagination")
        await model.saveEditing()
        #expect(model.edit == nil)
        // SwiftUI reads and writes the closing editor's fields once more: no crash, and the editor stays closed.
        #expect(binding.wrappedValue.ticketID == "ORD-141")
        binding.wrappedValue.title = "Typed as it closed"
        #expect(model.edit == nil)
        // A binding of another ticket's edit writes nothing into the open one.
        model.startEditing(model.selectedTicket!)
        let opened = model.edit
        let other = model.editBinding(TicketEdit(ticket("ORD-2", in: "ORD")))
        other.wrappedValue.title = "Elsewhere"
        #expect(model.edit == opened)
    }

    @Test("Links keep the declared ones and add or remove one at a time")
    func links() async {
        let (model, store) = orders()
        let ticket = model.selectedTicket!
        #expect(model.linkCandidates(for: ticket).map(\.id).contains("ORD-142"))
        #expect(await model.addLink(TicketLinkDraft(kind: .dependsOn, ticketID: "ORD-142"), to: ticket))
        let linked = store.ticket("ORD-141")!
        #expect(model.declaredLinks(of: linked) == [TicketLinkDraft(kind: .dependsOn, ticketID: "ORD-142")])
        #expect(!model.linkCandidates(for: linked).map(\.id).contains("ORD-142"))
        await model.removeLink(linked.links.first { $0.isDeclared }!, from: linked)
        #expect(model.declaredLinks(of: store.ticket("ORD-141")!).isEmpty)
    }

    @Test("Deleting asks first, then clears the selection of a deleted ticket")
    func deleting() async {
        let (model, store) = orders()
        model.confirmation = .deleteTickets(["ORD-141"])
        await model.confirm(.deleteTickets(["ORD-141"]))
        #expect(store.ticket("ORD-141") == nil)
        #expect(model.selection != "ORD-141")
    }

    @Test("A new bundle is created from its tickets and selected in the sidebar")
    func bundles() async {
        let (model, store) = orders()
        model.startNewBundle(with: ["ORD-141"])
        #expect(model.bundleDraft?.ticketIDs == ["ORD-141"])
        await model.saveBundle()
        #expect(model.bundleDraft == nil)
        guard case .bundle(let id)? = model.filter else { Issue.record("no bundle filter"); return }
        #expect(store.allBundles.first { $0.id == id }?.ticketIDs == ["ORD-141"])
        let bundle = store.allBundles.first { $0.id == id }!
        await model.setStatus(.done, of: bundle)
        #expect(store.allBundles.first { $0.id == id }?.status == .done)
        await model.confirm(.deleteBundle(id))
        #expect(model.filter == .all)
    }

    @Test("⌘V in a comment attaches the pasteboard's files; text pastes as text")
    func pasteIntoComment() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("HephaestusV3Tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TicketsPaste-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)
        let orders = model("ORD")
        board.clearContents()
        board.writeObjects([file as NSURL])
        #expect(orders.paste(into: "ORD-2", from: board))
        #expect(orders.files(for: "ORD-2") == [file])
        board.clearContents()
        board.setString("text", forType: .string)
        #expect(!orders.paste(into: "ORD-2", from: board))
    }

    @Test("New Bundle… from a sub project's ticket makes the bundle in that ticket's project")
    func newBundleInTicketsProject() {
        let shop = model("SHOP")
        shop.startNewBundle(with: ["ORD-2"])
        #expect(shop.bundleDraft?.projectID == "ORD")
        shop.startNewBundle()
        #expect(shop.bundleDraft?.projectID == "SHOP")
    }

    @Test("A new bundle lists no done ticket unless checked; a bundle's edit lists them all; New Bundle says why it can't")
    func bundlePicker() {
        let orders = model("ORD")
        let new = BundleDraft(bundleID: nil, projectID: "ORD", title: "", ticketIDs: [])
        #expect(orders.bundleCandidates(for: new).map(\.id) == ["ORD-2"])
        var checked = new
        checked.ticketIDs = ["ORD-1"]
        #expect(orders.bundleCandidates(for: checked).map(\.id) == ["ORD-2", "ORD-1"])
        let editing = BundleDraft(bundleID: "ORD-B1", projectID: "ORD", title: "Checkout", ticketIDs: ["ORD-2"])
        #expect(orders.bundleCandidates(for: editing).map(\.id) == ["ORD-2", "ORD-1"])
        #expect(orders.newBundleUnavailable == nil)
        let allDone = MockTicketStore(allTickets: [ticket("ORD-1", in: "ORD", .done)], allBundles: [])
        #expect(model("ORD", store: allDone).newBundleUnavailable == "Every ticket of this project is done.")
        #expect(model("ORD", store: MockTicketStore(allTickets: [], allBundles: [])).newBundleUnavailable
                == "This project has no tickets to bundle yet.")
    }

    @Test("The pickers' filter matches an id or a title, case and accents ignored")
    func pickerFilter() {
        let one = ticket("ORD-142", in: "ORD", title: "Retry storm between checkout and paymENTS")
        #expect(TicketPickerFilter.matches(one, ""))
        #expect(TicketPickerFilter.matches(one, " 142 "))
        #expect(TicketPickerFilter.matches(one, "Payments"))
        #expect(TicketPickerFilter.matches(ticket("ORD-1", in: "ORD", title: "Café"), "cafe"))
        #expect(!TicketPickerFilter.matches(one, "refund"))
    }

    @Test("A comment typed, files waiting or an edit open are unsaved edits, which hold the automatic restart")
    func unsavedEdits() {
        let orders = model("ORD")
        #expect(!orders.hasUnsavedEdits)
        orders.isComposing = true
        #expect(orders.hasUnsavedEdits && TicketsWindows.hasUnsavedEdits)
        orders.isComposing = false
        #expect(!orders.hasUnsavedEdits)
    }

    @Test("The store's phase shows as loading or failed in the list")
    func phases() {
        let loading = TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore(phase: .loading))
        #expect(loading.listState == .loading)
        #expect(loading.missingSelection == nil)
        let failed = TicketsModel(project: Project.sample("ORD")!, focus: nil, store: SampleTicketStore(phase: .failed("Nope")))
        #expect(failed.listState == .failed(message: "Nope"))
    }
}

@Suite("Copying ticket ids")
struct TicketIDCopyTests {
    @Test("Copy ID writes the ids one per line, in the list's order")
    func text() {
        #expect(TicketIDCopy.text(["ORD-142"]) == "ORD-142")
        #expect(TicketIDCopy.text(["ORD-142", "ORD-140"]) == "ORD-142\nORD-140")
    }
}
