import FileStorage
import Foundation
import MCPKit

/// Something a chat's user should hear about, as V2's chat notifications (docs/data.md › Chat events).
public struct ChatEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A card or questions now wait for the user.
        case needsYou
        /// A turn ended well, and the chat is idle.
        case finished
    }

    public var chatID: String
    public var projectID: String
    public var title: String
    public var kind: Kind
    /// The line without a summary: the first line of Claude's last reply, else what the chat waits for.
    public var detail: String
    /// What `notification-summary` reads; nil when there is nothing to sum up.
    public var summaryInput: String?

    public init(chatID: String, projectID: String, title: String, kind: Kind, detail: String, summaryInput: String?) {
        self.chatID = chatID
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.detail = detail
        self.summaryInput = summaryInput
    }

    /// The most a summary has, and the part of a reply or a request it reads.
    public static let summaryLimit = 150
    static let inputLimit = 4_000

    /// A summary as Claude wrote it, made a notification's line, as V2 cleaned it: white space runs made one
    /// space, a leading `Summary:` and surrounding quotes taken off, cut at the last space before 150 characters;
    /// nil when nothing is left.
    public static func cleanSummary(_ text: String) -> String? {
        var line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if line.lowercased().hasPrefix("summary:") {
            line = String(line.dropFirst("summary:".count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "«", "»", "`"]
        while let first = line.first, let last = line.last, line.count >= 2, quotes.contains(first), quotes.contains(last) {
            line = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if line.count > summaryLimit {
            let cut = line.prefix(summaryLimit)
            line = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut).trimmingCharacters(in: .whitespaces)
        }
        return line.isEmpty ? nil : line
    }
}

extension ChatSession {
    /// A chat's state changed from one the session had seen: "needs you" when a card or questions start to wait,
    /// "finished" when a turn ends well. The first state of a chat, and a Stop, report nothing.
    func noticeTransition(_ chatID: String, from old: ChatState?, to new: ChatState) {
        guard let onEvent, let old, let chat = chats[chatID] else { return }
        let waiting: Set<ChatState> = [.waitingPermission, .waitingAnswers]
        let kind: ChatEvent.Kind
        if waiting.contains(new), !waiting.contains(old) {
            kind = .needsYou
        } else if new == .idle, [.starting, .running, .waitingPermission].contains(old), !lastTurnStopped(chatID) {
            kind = .finished
        } else {
            return
        }
        onEvent(event(kind, chatID: chatID, chat: chat, state: new))
    }

    /// The items of the last turn: those after the user's last message.
    private func lastTurn(_ chatID: String) -> ArraySlice<ChatItem> {
        let items = transcripts[chatID] ?? []
        let start = items.lastIndex { if case .user = $0 { true } else { false } }.map { $0 + 1 } ?? items.startIndex
        return items[start...]
    }

    /// Whether Stop ended the last turn: its line, or its result, says so.
    private func lastTurnStopped(_ chatID: String) -> Bool {
        lastTurn(chatID).contains { item in
            switch item {
            case .system(let line): line.text == "Stopped by the user."
            case .result(let end): end.summary == "Stopped by the user."
            default: false
            }
        }
    }

    func event(_ kind: ChatEvent.Kind, chatID: String, chat: LoadedChat, state: ChatState) -> ChatEvent {
        let items = transcripts[chatID] ?? []
        // Claude's last reply of the turn: its last text outside a sub-agent.
        let reply = lastTurn(chatID).reversed().lazy.compactMap { item -> String? in
            if case .assistant(let text) = item, text.parentToolUseID == nil { return text.text }
            return nil
        }.first
        let firstLine = reply?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var detail = firstLine.map { String($0.prefix(200)) } ?? ""
        var input: String?
        switch kind {
        case .finished:
            if detail.isEmpty { detail = "Claude finished replying" }
            input = reply.map { "Claude's reply:\n" + String($0.prefix(ChatEvent.inputLimit)) }
        case .needsYou:
            if state == .waitingAnswers, let set = waitingQuestions(in: chatID) {
                if detail.isEmpty { detail = "Waiting for your answers" }
                input = "Questions:\n" + String(set.questions.map { "\($0.label): \($0.question)" }.joined(separator: "\n").prefix(ChatEvent.inputLimit))
            } else {
                if detail.isEmpty { detail = "Waiting for your permission" }
                let request = items.lazy.compactMap { item -> PermissionRequestItem? in
                    if case .permissionRequest(let request) = item, request.isPending { return request }
                    return nil
                }.first
                input = request.map { request in
                    let name = ToolUseItem.split(request.toolName).name
                    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: request.input.foundation, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
                    return "Permission request:\nTool: \(name)\nInput: " + String(json.prefix(ChatEvent.inputLimit))
                }
            }
        }
        return ChatEvent(chatID: chatID, projectID: chat.projectID, title: chat.file.title, kind: kind, detail: detail, summaryInput: input)
    }

    /// The event's line written by `notification-summary`, 30 s at most and two at a time; the fallback detail when
    /// it fails, times out or says nothing.
    public func summary(of event: ChatEvent) async -> String {
        guard let input = event.summaryInput else { return event.detail }
        while summaryRuns >= 2 {
            await withCheckedContinuation { summaryWaiters.append($0) }
        }
        summaryRuns += 1
        defer {
            summaryRuns -= 1
            if !summaryWaiters.isEmpty { summaryWaiters.removeFirst().resume() }
        }
        let answer = try? await run(.notificationSummary, input: input, timeout: .seconds(30))
        return answer.flatMap(ChatEvent.cleanSummary) ?? event.detail
    }

    /// What a view shows, `chatID` nil for none, and whether its window is the key window. A chat that a view of
    /// the key window starts to show loses its notification, as when a window opens it.
    public func showing(_ chatID: String?, inKeyWindow: Bool, view: UUID) {
        let old = keyViews[view]
        let new = inKeyWindow ? chatID : nil
        keyViews[view] = new
        if let new, new != old { onOpen?(new) }
    }

    /// Whether a view of the key window shows the chat: its notification is not posted.
    public func isInKeyWindow(_ chatID: String) -> Bool {
        keyViews.values.contains(chatID)
    }

    /// The chats waiting for the user, for the Dock's badge and the status bar.
    public var waitingChats: [String] {
        states.filter { $0.value == .waitingPermission || $0.value == .waitingAnswers }.map(\.key)
    }

    /// The chats at work, those idle with background work included, for the status bar.
    public var runningChats: [String] {
        states.filter { $0.value == .starting || $0.value == .running || ($0.value == .idle && backgroundWork.contains($0.key)) }.map(\.key)
    }
}
