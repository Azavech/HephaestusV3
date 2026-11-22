import ChatData
import ChatKit
import FileStorage
import Foundation
import Observation
import TicketData
import TicketsKit
import ProjectData
import ToolsFoundation

/// Claude's answers to the comments that mention it (docs/ui/tickets.md › Comment answers), as V2's: each new comment
/// of the user with `@Claude` runs the internal skill `comment-answer` once, without a chat, in the project's folder,
/// and the answer is posted as Claude's comment. A run may change its own ticket only; it stops after 5 minutes. Its
/// state shows under the comment, and goes with a restart.
@MainActor @Observable
final class CommentAnswerer {
    /// How long a run may take.
    static let timeout: Duration = .seconds(300)

    private(set) var states: [UUID: CommentAnswerState] = [:]
    @ObservationIgnored private var runs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tickets: [UUID: String] = [:]
    @ObservationIgnored private let session: TicketSession
    @ObservationIgnored private let projects: ProjectSession
    @ObservationIgnored private let chats: ChatSession
    /// The app's log, once the data folder is known.
    @ObservationIgnored var log = AppLog(url: nil)
    /// What the Tickets windows read, made once.
    @ObservationIgnored private(set) var reader = CommentAnswersReader(state: { _ in nil }, retry: { _ in })

    init(tickets: TicketSession, projects: ProjectSession, chats: ChatSession) {
        session = tickets
        self.projects = projects
        self.chats = chats
        reader = CommentAnswersReader(state: { [weak self] in self?.states[$0] }, retry: { [weak self] id in
            guard let self, let ticket = self.tickets[id] else { return }
            answer(id, of: ticket)
        })
    }

    /// Answers the comment `commentID` of the ticket `ticketID`, as it is now.
    func answer(_ commentID: UUID, of ticketID: String) {
        runs[commentID]?.cancel()
        tickets[commentID] = ticketID
        states[commentID] = .replying
        runs[commentID] = Task { [weak self] in await self?.run(commentID, of: ticketID) }
    }

    /// Stops the runs of the comments and tickets gone: a stopped run posts nothing.
    func follow(_ snapshot: TicketSnapshot) {
        for (commentID, ticketID) in tickets where snapshot.ticket(ticketID)?.file.comments.contains(where: { $0.id == commentID }) != true {
            runs[commentID]?.cancel()
            runs[commentID] = nil
            states[commentID] = nil
            tickets[commentID] = nil
        }
    }

    private func run(_ commentID: UUID, of ticketID: String) async {
        guard let loaded = session.snapshot.ticket(ticketID), let comment = loaded.file.comments.first(where: { $0.id == commentID }),
              let project = projects.snapshot.project(loaded.projectID) else {
            fail(commentID, "the ticket or the comment is gone")
            return
        }
        let input = """
            Project: \(project.file.name) (\(project.id)), its folder \(project.root), its docs in \(project.file.docsPath).

            Ticket: \(ticketID), \(loaded.file.title)

            Comment to answer:
            \(comment.text)
            """
        let reference = ChatItemReference(tool: "tickets", projectID: project.id, focus: ticketID, title: ticketID)
        do throws(ChatError) {
            let answer = try await chats.run(.commentAnswer, input: input, attaching: [reference], timeout: Self.timeout,
                                             scope: ticketID, workingDirectory: project.root, cliTools: ["Read", "Grep", "Glob"])
            guard !Task.isCancelled, states[commentID] != nil else { return }
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let library = session.library else {
                fail(commentID, "the answer is empty")
                return
            }
            do {
                _ = try await library.addComment(to: ticketID, text: text, files: [], by: .claude(chat: "answer"))
                await session.refresh()
                states[commentID] = nil
                runs[commentID] = nil
                tickets[commentID] = nil
            } catch {
                fail(commentID, "the answer couldn't be posted: \(error)")
            }
        } catch {
            guard !Task.isCancelled else { return }
            fail(commentID, "\(error)")
        }
    }

    private func fail(_ commentID: UUID, _ reason: String) {
        log.write(.warning, "answers", "\(tickets[commentID] ?? "?") comment \(commentID.uuidString): \(reason)")
        states[commentID] = .failed
        runs[commentID] = nil
    }
}
