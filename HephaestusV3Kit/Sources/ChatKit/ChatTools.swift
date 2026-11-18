import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// What a chat's Claude may do without asking, as the user set it (docs/mcp.md › Permissions). The MCP server
/// asks before each call of a chat's Claude; the external token's calls run as before; a run of an internal
/// skill only reads.
public enum ChatGate {
    /// The refusal of anything but a read to an internal skill's run.
    static let skillRefusal = "An internal skill's run only reads."

    /// Nil lets the call run; an error refuses it. A change set to Ask First waits for the user's answer to a
    /// card in the chat.
    @MainActor
    public static func check(_ caller: MCPCaller, _ operation: ToolOperation, _ arguments: JSONValue, chats: ChatSession,
                             defaults: UserDefaults = .standard) async -> ToolError? {
        if case .internalSkill = caller {
            // The app runs the skill in the background, for its answer alone: it reads, and opens no window.
            return operation.permission == .read && operation.name != "open_in_app" ? nil : ToolError(.forbidden, skillRefusal)
        }
        guard case .chat(let chatID) = caller else { return nil }
        func rule(_ key: String) -> ChangePermission {
            defaults.string(forKey: key).flatMap(ChangePermission.init(rawValue:)) ?? .askFirst
        }
        let permission: ChangePermission
        let refusal: String
        switch operation.permission {
        case .read, .renameChats, .askUser:
            return nil
        case .closeChats:
            // Its own chat closes without asking; another one asks first.
            let others = (arguments["chatIDs"]?.arrayValue ?? []).compactMap(\.stringValue).filter { $0.uppercased() != chatID }
            if others.isEmpty { return nil }
            let allowed = await chats.requestApproval(chatID, tool: operation.name, input: arguments)
            return allowed ? nil : ToolError(.forbidden, "The user didn't allow this call.")
        case .changeTickets:
            permission = rule(ChatPreferences.ticketChangesKey)
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
        case .deleteTickets:
            permission = rule(ChatPreferences.ticketChangesKey) == .never ? .never : .askFirst
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
        case .changeProjects:
            permission = rule(ChatPreferences.projectChangesKey)
            refusal = "The user doesn't let Claude change projects from chats (Settings ▸ Chat)."
        case .removeProjects:
            permission = rule(ChatPreferences.projectChangesKey) == .never ? .never : .askFirst
            refusal = "The user doesn't let Claude change projects from chats (Settings ▸ Chat)."
        case .callAPIs:
            // A request that reads runs; another follows Call APIs that change data.
            let operation = arguments["operation"]?.stringValue ?? ""
            if operation.hasPrefix("GET ") || operation.hasPrefix("HEAD ") { return nil }
            permission = rule(ChatPreferences.apiCallsKey)
            refusal = "The user doesn't let Claude call APIs that change data from chats (Settings ▸ Chat)."
        case .operateClusters:
            permission = rule(ChatPreferences.clusterChangesKey)
            refusal = "The user doesn't let Claude operate deployments from chats (Settings ▸ Chat)."
        case .operateMachines:
            permission = rule(ChatPreferences.machineChangesKey)
            refusal = "The user doesn't let Claude operate virtual machines from chats (Settings ▸ Chat)."
        case .startBuilds:
            // Never by default; Ask First at most.
            permission = defaults.string(forKey: ChatPreferences.buildStartsKey) == ChangePermission.askFirst.rawValue ? .askFirst : .never
            refusal = "The user doesn't let Claude start or cancel builds from chats (Settings ▸ Chat)."
        }
        switch permission {
        case .always:
            return nil
        case .never:
            return ToolError(.forbidden, refusal)
        case .askFirst:
            let allowed = await chats.requestApproval(chatID, tool: operation.name, input: arguments)
            return allowed ? nil : ToolError(.forbidden, "The user didn't allow this call.")
        }
    }
}

/// The chat operations the MCP server offers Claude (docs/mcp.md › Chat tools).
public enum ChatTools {
    @MainActor
    public static func operations(chats: ChatSession, projects: ProjectSession) -> [ToolOperation] {
        [listChats(chats, projects), getChat(chats), renameChat(chats), closeChat(chats), askQuestions(chats)]
    }

    static let chatID = ToolSchema.string("Chat id, an uppercase UUID.")

    @MainActor
    static func listChats(_ chats: ChatSession, _ projects: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "list_chats",
            description: "Returns a project's chats, its sub projects' included, the latest first: id, project, title, kind, created, updated, origin, model, effort and state.",
            inputSchema: .object(properties: [("projectID", .string("Project identifier, 2 to 8 letters, such as ORD."))], required: ["projectID"]),
            permission: .read,
            describe: { arguments in
                let id = arguments["projectID"]?.stringValue?.uppercased() ?? ""
                return ToolCallText(action: String(localized: "Listed the chats of \(id)", bundle: #bundle),
                                    item: ToolItem(tool: ToolKind.chat.rawValue, projectID: id, focus: "", title: id))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("projectID").uppercased()
            guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
            let family = Set(projects.snapshot.family(of: id).map(\.id))
            return .array(chats.chats(of: family).map { json($0, chats) })
        }
    }

    @MainActor
    static func getChat(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "get_chat",
            description: "Returns a chat with its messages: the user's messages, Claude's replies, the tool calls and their results, the permission requests and their answers, in order.",
            inputSchema: .object(properties: [("chatID", chatID)], required: ["chatID"]),
            permission: .read,
            describe: { arguments in
                _ = arguments
                return ToolCallText(action: String(localized: "Read a chat", bundle: #bundle, comment: "Claude read another chat's messages"))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("chatID").uppercased()
            guard let chat = chats.chats[id] else { throw ToolError(.notFound, "Chat \(id) not found.") }
            await chats.open(id)
            var value = json(chat, chats)
            if case .object(var object) = value {
                object["items"] = .array((chats.transcripts[id] ?? []).map(\.json))
                value = .object(object)
            }
            return value
        }
    }

    @MainActor
    static func renameChat(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "rename_chat",
            description: "Renames a chat. The title is 1 to 100 characters on one line. Returns the chat.",
            inputSchema: .object(properties: [("chatID", chatID), ("title", .string("The new title."))], required: ["chatID", "title"]),
            permission: .renameChats,
            describe: { arguments in
                ToolCallText(action: String(localized: "Renamed a chat “\(arguments["title"]?.stringValue ?? "")”", bundle: #bundle,
                                            comment: "Claude renamed a chat; the value is the new title"))
            }
        ) { @MainActor arguments throws(ToolError) in
            let id = try arguments.string("chatID").uppercased()
            let title = try arguments.string("title")
            do throws(ChatError) {
                try chats.rename(id, to: title)
            } catch {
                switch error {
                case .notFound(let message): throw ToolError(.notFound, message)
                case .invalid(let message): throw ToolError(.invalid, message)
                default: throw ToolError(.internal, error.description)
                }
            }
            guard let chat = chats.chats[id] else { throw ToolError(.notFound, "Chat \(id) not found.") }
            return json(chat, chats)
        }
    }

    @MainActor
    static func closeChat(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "close_chat",
            description: "Closes chats. Without chatIDs, closes the calling chat once its current turn ends; the conversation stays, and a message reopens it. With chatIDs, closes those chats of the calling chat's project; a chat where Claude is at work, a chat of another project or an unknown one is refused, and the others still close. Closing another chat than the calling one asks the user first. Returns the chats closed, whether the calling chat closes after its turn, and each refusal with its reason.",
            inputSchema: .object(properties: [("chatIDs", .array("The chats to close, each an uppercase UUID; absent for the calling chat.", of: chatID))]),
            permission: .closeChats,
            describe: { arguments in
                let count = arguments["chatIDs"]?.arrayValue?.count ?? 0
                return ToolCallText(action: count > 1
                    ? String(localized: "Closed \(count) chats", bundle: #bundle, comment: "Claude closed several chats; the value is their number")
                    : String(localized: "Closed a chat", bundle: #bundle, comment: "Claude closed a chat"))
            }
        ) { @MainActor arguments throws(ToolError) in
            let caller = MCPCaller.current.chatID
            let listed = (arguments["chatIDs"]?.arrayValue ?? []).compactMap(\.stringValue).map { $0.uppercased() }
            guard caller != nil || !listed.isEmpty else { throw ToolError(.forbidden, "chatIDs: name the chats to close; only a chat's own Claude closes its chat without them.") }
            let result = chats.closeChats(arguments["chatIDs"] == nil ? nil : listed, caller: caller)
            return ["closed": .array(result.closed.map(JSONValue.string)), "closesAfterTurn": .bool(result.closesAfterTurn),
                    "refused": .array(result.refused.map { ["chatID": .string($0.chatID), "reason": .string($0.reason)] })]
        }
    }

    /// The refusal of a question asked through another token than a chat's.
    static let askRefusal = "Only a chat's own Claude can ask the user: there is no chat to show the questions in."

    @MainActor
    static func askQuestions(_ chats: ChatSession) -> ToolOperation {
        let option = ToolSchema.object(properties: [
            ("label", .string("The answer, one line of at most 200 characters, as it comes back when chosen.")),
            ("description", .string("What choosing it means; optional.")),
        ], required: ["label"])
        let question = ToolSchema.object(properties: [
            ("label", .string("A for the first question, B for the second, and so on, up to Z.")),
            ("question", .string("The question, in Markdown.")),
            ("kind", .string("single (the default): the user chooses one option. multiple: the user checks every option that applies.", oneOf: ["single", "multiple"])),
            ("options", .array("2 to 10 options, their labels distinct ignoring case.", of: option)),
            ("recommended", .array("The labels of the recommended options: exactly one for a single question, one or more for a multiple one.", of: .string())),
            ("minChoices", .integer("multiple only: the fewest choices, checked options and own answers together; 1 when absent.", minimum: 1)),
            ("maxChoices", .integer("multiple only: the most choices; no maximum when absent.", minimum: 1)),
        ], required: ["label", "question", "options", "recommended"])
        return ToolOperation(
            name: "ask_questions",
            description: "Shows the user questions in this chat, one at a time, and returns at once with the set's id and the number of questions shown. Each question has 2 to 10 options and the recommended ones, which the app lists first and preselects; the user can also answer in their own words or skip a question. A multiple question lets the user check several options and add answers of their own. Once every question has an answer, the user's next message gives them: \"Answers:\", then one line \"<label>: <answer>\" per question, where <answer> is the chosen option's label, the user's own text, or Skipped; a multiple question's answer follows \"<label>:\" as one line \"- <choice>\" per choice. A chat has one set of questions waiting at most. Only a chat's own Claude can ask.",
            inputSchema: .object(properties: [("questions", .array("1 to 26 questions, in the order they are asked.", of: question))], required: ["questions"]),
            permission: .askUser,
            describe: { arguments in
                let count = arguments["questions"]?.arrayValue?.count ?? 0
                return ToolCallText(action: count == 1
                    ? String(localized: "Asked a question", bundle: #bundle, comment: "Claude asked the user one question")
                    : String(localized: "Asked \(count) questions", bundle: #bundle, comment: "Claude asked the user several questions; the value is their number"))
            }
        ) { @MainActor arguments throws(ToolError) in
            guard let chatID = MCPCaller.current.chatID else { throw ToolError(.forbidden, askRefusal) }
            let questions = try QuestionsItem.questions(from: arguments)
            let item: QuestionsItem
            do throws(ChatError) {
                item = try await chats.postQuestions(chatID, questions: questions)
            } catch {
                switch error {
                case .notFound(let message): throw ToolError(.notFound, message)
                case .conflict(let message): throw ToolError(.conflict, message)
                default: throw ToolError(.internal, error.description)
                }
            }
            return ["questionSetID": .string(item.questionSetID), "shown": .int(item.questions.count)]
        }
    }

    /// A chat's JSON: its metadata and state.
    @MainActor
    static func json(_ chat: LoadedChat, _ chats: ChatSession) -> JSONValue {
        let state: String = switch chats.state(of: chat.id) {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .waitingPermission: "waitingPermission"
        case .waitingAnswers: "waitingAnswers"
        case .error: "error"
        }
        var object: [String: JSONValue] = [
            "id": .string(chat.id), "project": .string(chat.projectID), "title": .string(chat.file.title),
            "kind": .string(chat.file.kind.rawValue), "created": .string(ISODate.string(from: chat.file.created)),
            "updated": .string(ISODate.string(from: chat.file.updated)), "model": .string(chat.file.settings.model),
            "effort": .string(chat.file.settings.effort.rawValue), "state": .string(state),
        ]
        if let origin = chat.file.origin { object["origin"] = .string(origin) }
        if let ticket = chat.file.ticketID { object["ticket"] = .string(ticket) }
        if let bundle = chat.file.bundleID { object["bundle"] = .string(bundle) }
        return .object(object)
    }
}
