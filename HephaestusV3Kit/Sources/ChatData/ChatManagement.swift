import FileStorage
import Foundation
import MCPKit

/// How much of the context window a chat's conversation used when the app last asked the CLI (docs/data.md ›
/// Context usage), as V2 stored it in the chat's file under `contextUsage`.
public struct ContextUsage: Sendable, Hashable {
    /// The conversation's tokens, the CLI's `totalTokens`.
    public var usedTokens: Int
    /// The context window, the CLI's `maxTokens`.
    public var windowTokens: Int
    /// The autocompact buffer the CLI keeps free, at whose start it compacts.
    public var bufferTokens: Int
    public var received: Date

    public init(usedTokens: Int, windowTokens: Int, bufferTokens: Int, received: Date) {
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
        self.bufferTokens = bufferTokens
        self.received = received
    }

    /// The tokens left before the CLI compacts: the window less the buffer and what's used, at least 0.
    public var left: Int { max(0, windowTokens - bufferTokens - usedTokens) }

    /// The part left, from 0 to 100, rounded; nil when the buffer isn't below the window.
    public var percentLeft: Int? {
        let usable = windowTokens - bufferTokens
        guard usable > 0 else { return nil }
        return Int((Double(left) / Double(usable) * 100).rounded())
    }

    /// The value of a `get_context_usage` answer: `totalTokens`, `maxTokens`, and the `tokens` of the
    /// `categories` entry whose `id` is `autocompact_buffer` (0 without one); nil when they break the rules.
    public static func from(_ response: JSONValue?, received: Date) -> ContextUsage? {
        guard let used = response?["totalTokens"]?.intValue, used >= 0, let window = response?["maxTokens"]?.intValue, window > 0 else { return nil }
        let buffer = (response?["categories"]?.arrayValue ?? []).first { $0["id"]?.stringValue == "autocompact_buffer" }?["tokens"]?.intValue ?? 0
        guard buffer >= 0, buffer < window else { return nil }
        return ContextUsage(usedTokens: used, windowTokens: window, bufferTokens: buffer, received: received)
    }

    var yaml: RawYAML {
        func int(_ value: Int) -> RawYAML { .scalar(RawYAML.Scalar(String(value), tag: "tag:yaml.org,2002:int", style: .plain)) }
        return .mapping(["usedTokens": int(usedTokens), "windowTokens": int(windowTokens), "bufferTokens": int(bufferTokens),
                         "received": ISODate.scalar(received)], style: .block)
    }

    init?(yaml: RawYAML?) {
        guard case .mapping(let mapping, _)? = yaml else { return nil }
        func text(_ key: String) -> String? {
            if case .scalar(let scalar)? = mapping[key] { return scalar.text }
            return nil
        }
        guard let used = text("usedTokens").flatMap(Int.init), let window = text("windowTokens").flatMap(Int.init),
              let buffer = text("bufferTokens").flatMap(Int.init), let received = text("received").flatMap(ISODate.date(from:)) else { return nil }
        self.init(usedTokens: used, windowTokens: window, bufferTokens: buffer, received: received)
    }
}

extension ChatFile {
    /// The chat's last context usage; nil before the first. Kept with the file's other keys, where V2 wrote it.
    public var contextUsage: ContextUsage? {
        get { ContextUsage(yaml: unknownKeys["contextUsage"]) }
        set { unknownKeys["contextUsage"] = newValue?.yaml }
    }
}

extension ChatSession {
    // MARK: Context usage

    /// Asks the CLI how much of the context the conversation uses, unless an answer is awaited; then once more
    /// when it comes. A request not answered in 30 s is forgotten.
    func askContextUsage(_ run: ChatRun) {
        guard run.contextRequestID == nil else {
            run.contextAskedAgain = true
            return
        }
        let id = run.controlID()
        run.contextRequestID = id
        run.contextAskedAgain = false
        run.connection.write(ClaudeInput.control(id, ["subtype": "get_context_usage"]))
        Task { [weak self, weak run] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, let run, run.contextRequestID == id else { return }
            run.contextRequestID = nil
            if run.contextAskedAgain { self.askContextUsage(run) }
        }
    }

    /// The CLI's answer: a valid value replaces the chat's; another leaves it.
    func received(contextUsage response: JSONValue?, success: Bool, for run: ChatRun) {
        run.contextRequestID = nil
        if success, let usage = ContextUsage.from(response, received: now()) {
            change(run.chatID) { $0.contextUsage = usage }
        }
        if run.contextAskedAgain { askContextUsage(run) }
    }

    /// The number of compactions the chat's transcript records: its `Conversation compacted` lines.
    public func compactions(in chatID: String) -> Int {
        (transcripts[chatID] ?? []).count { item in
            if case .system(let line) = item { return line.text.hasPrefix("Conversation compacted") }
            return false
        }
    }

    // MARK: Closing, reopening, deleting

    /// Closes a chat, as V2's Close and `close_chat` did: at once without a turn in progress, its CLI then ending
    /// as when idle; otherwise once the turn ends well (a Stop, an error or an exit cancels it).
    public func close(_ chatID: String) throws(ChatError) {
        guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
        if let run = runs[chatID], run.inTurn {
            run.closesAfterTurn = true
        } else {
            closeNow(chatID)
        }
    }

    func closeNow(_ chatID: String) {
        change(chatID) { $0.closed = true }
        if let run = runs[chatID], !run.connection.hasExited {
            run.end(closingInput: true, grace: Self.signalGrace)
        }
    }

    /// Reopens a closed chat: the composer shows again, and the next message resumes the session.
    public func reopen(_ chatID: String) throws(ChatError) {
        guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
        change(chatID) { $0.closed = false }
    }

    /// Deletes a chat: its process ends, then its file, its transcript and its folder of files move to the Trash.
    public func delete(_ chatID: String) throws(ChatError) {
        guard chats[chatID] != nil, let folder = folder(of: chatID) else { throw .notFound("Chat \(chatID) not found.") }
        if let run = runs[chatID] {
            run.endedByApp = true
            run.end(closingInput: false, grace: Self.signalGrace)
            runs[chatID] = nil
        }
        cancelApprovals(of: chatID, by: nil)
        for url in [folder.chatsFolder.appendingPathComponent("\(chatID).yml"), folder.chatsFolder.appendingPathComponent("\(chatID).jsonl"),
                    folder.chatsFolder.appendingPathComponent(chatID, isDirectory: true)]
            where FileManager.default.fileExists(atPath: url.path) {
            ownWrites.recordRemoval(path: url.path)
            do {
                try trash.move(url)
            } catch let error as StorageError {
                throw .storage(error)
            } catch {
                throw .storage(.trashFailed(path: url.path, reason: String(describing: error)))
            }
        }
        chats[chatID] = nil
        transcripts[chatID] = nil
        states[chatID] = nil
        streaming[chatID] = nil
        ciQuestionChats.remove(chatID)
    }
}

extension ChatSession {
    // MARK: Resume

    /// Whether the chat stopped with an error that Resume can go on from: its state is `error`, or it is idle
    /// and its newest result is an error other than a Stop. A closed chat has none.
    public func needsResume(_ chatID: String) -> Bool {
        guard let chat = chats[chatID], !chat.file.closed else { return false }
        switch state(of: chatID) {
        case .error:
            return true
        case .idle:
            for case .result(let end) in (transcripts[chatID] ?? []).reversed() {
                return end.isError && end.summary != "Stopped by the user."
            }
            return false
        default:
            return false
        }
    }

    /// Resume: sends the call of the internal skill `resume-chat`, which says how to go on.
    public func resume(_ chatID: String) async throws(ChatError) {
        guard let chat = chats[chatID] else { throw .notFound("Chat \(chatID) not found.") }
        // The app's call, not the user's words: an implement chat still asks nothing.
        _ = try await send(InternalSkill.resumeChat.command, references: [], to: chatID, projectID: chat.projectID, origin: nil, title: nil,
                           images: [], files: [], fromUser: false)
    }

    // MARK: close_chat

    /// What `close_chat` did: the chats closed, whether the calling chat closes once its turn ends, and those
    /// refused, with why.
    public struct CloseResult: Sendable, Hashable {
        public var closed: [String] = []
        public var closesAfterTurn = false
        public var refused: [(chatID: String, reason: String)] = []

        public static func == (lhs: CloseResult, rhs: CloseResult) -> Bool {
            lhs.closed == rhs.closed && lhs.closesAfterTurn == rhs.closesAfterTurn
                && lhs.refused.map(\.chatID) == rhs.refused.map(\.chatID) && lhs.refused.map(\.reason) == rhs.refused.map(\.reason)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(closed)
            hasher.combine(closesAfterTurn)
            hasher.combine(refused.map(\.chatID))
        }
    }

    /// Closes `chatIDs`, or the calling chat `caller` without them, as V2's `close_chat`: the caller's own chat
    /// closes once its turn ends; another chat of its project closes at once unless a turn runs in it; a chat of
    /// another project, an unknown one, or one at work is refused. A closed chat stays as it is.
    public func closeChats(_ chatIDs: [String]?, caller: String?) -> CloseResult {
        var result = CloseResult()
        let project = caller.flatMap { chats[$0]?.projectID }
        for id in chatIDs ?? caller.map { [$0] } ?? [] {
            guard let chat = chats[id] else {
                result.refused.append((id, "Chat \(id) not found."))
                continue
            }
            if let project, chat.projectID != project {
                result.refused.append((id, "Chat \(id) belongs to another project."))
                continue
            }
            if id == caller {
                if runs[id]?.inTurn == true {
                    runs[id]?.closesAfterTurn = true
                    result.closesAfterTurn = true
                } else {
                    closeNow(id)
                    result.closed.append(id)
                }
                continue
            }
            if chat.file.closed {
                result.closed.append(id)
            } else if state(of: id).isRunning {
                result.refused.append((id, "Claude is at work in chat \(id)."))
            } else {
                closeNow(id)
                result.closed.append(id)
            }
        }
        return result
    }
}
