import FileStorage
import Foundation
import TicketData
import Testing
import ToolsFoundation
@testable import TicketsKit

@Suite("Tickets from the app's data")
struct LiveTicketStoreTests {
    private let date = ISODate.date(from: "2026-11-14T10:00:00Z")!

    @Test("Statuses, priorities, authors and bundle statuses map both ways")
    func statuses() {
        for status in TicketStatus.allCases {
            #expect(LiveTicketStore.status(LiveTicketStore.fileStatus(status)) == status)
        }
        #expect(LiveTicketStore.fileStatus(.created) == .todo && LiveTicketStore.fileStatus(.inReview) == .review)
        for priority in TicketPriority.allCases {
            #expect(LiveTicketStore.priority(LiveTicketStore.filePriority(priority)) == priority)
        }
        for status in BundleStatus.allCases {
            #expect(LiveTicketStore.bundleStatus(LiveTicketStore.fileBundleStatus(status)) == status)
        }
    }

    @Test("A comment Claude added from a chat names its model and effort, as V2's did; others say Claude or You")
    @MainActor
    func commentModel() {
        var file = TicketFile(id: "ORD-2", title: "Main", status: .todo, created: date)
        var claude = CommentEntry(id: UUID(), author: .claude, created: date, text: "Done")
        claude.model = "claude-opus-5-5"
        claude.effort = "xhigh"
        file.comments = [claude, CommentEntry(id: UUID(), author: .claude, created: date, text: "External"),
                         CommentEntry(id: UUID(), author: .user, created: date, text: "Thanks")]
        let saved = LiveTicketStore.commentCaption
        defer { LiveTicketStore.commentCaption = saved }
        LiveTicketStore.commentCaption = { model, effort in "(\(model) · \(effort ?? "-"))" }
        let texts = LiveTicketStore.events(of: file).filter { $0.kind == .commented }.map(\.text)
        #expect(texts == ["Claude (claude-opus-5-5 · xhigh) commented", "Claude commented", "You commented"])
    }

    @Test("A ticket shows its declared and inverse links, whether it is blocked, and its history with its comments")
    func mapping() {
        let other = TicketFile(id: "ORD-1", title: "Other", status: .inProgress, created: date)
        var file = TicketFile(id: "ORD-2", title: "Main", status: .draft, created: date, createdBy: .claude,
                              links: [TicketLinkEntry(kind: .dependsOn, ticketID: "ORD-1"), TicketLinkEntry(kind: .related, ticketID: "ORD-9")],
                              history: [HistoryEntry(kind: .created, date: date, to: "draft", author: .claude, chat: "external")])
        file.history.append(HistoryEntry(kind: .status, date: date.addingTimeInterval(60), from: "draft", to: "todo", author: .user, device: "Studio"))
        file.comments = [CommentEntry(id: UUID(), author: .user, created: date, text: "First")]
        let loaded = LoadedTicket(file: file, projectID: "ORD", inverseLinks: [.init(kind: .blocks, ticketID: "ORD-1")])
        let ticket = LiveTicketStore.ticket(loaded, others: ["ORD-1": other, "ORD-2": file])
        #expect(ticket.status == .draft && ticket.reporter == "Claude" && ticket.priority == nil)
        #expect(ticket.isBlocked && ticket.blockedBy == ["ORD-1"])
        #expect(TicketWords.blockedHelp(ticket) == "Blocked by ORD-1")
        #expect(ticket.links.map(\.kind) == [.dependsOn, .related, .blocks])
        #expect(ticket.links[0].title == "ORD-1 · Other" && ticket.links[0].isDeclared && !ticket.links[0].isMissing)
        #expect(ticket.links[1].isMissing)
        #expect(!ticket.links[2].isDeclared)
        #expect(ticket.events.map(\.kind) == [.drafted, .commented, .statusChanged])
        #expect(ticket.events[0].text == "Claude drafted this ticket")
        #expect(ticket.events[2].text == "You moved it from Draft to Created")
        #expect(Set(ticket.events.map(\.id)).count == 3)
    }
}
