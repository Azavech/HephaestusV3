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

    /// The ticket a comment answer's run may change: its caller is `comment-answer <ticket id>`.
    public static func commentAnswerTicket(_ caller: String) -> String? {
        let prefix = InternalSkill.commentAnswer.name + " "
        return caller.hasPrefix(prefix) ? String(caller.dropFirst(prefix.count)).uppercased() : nil
    }

    /// Nil lets the call run; an error refuses it. A change set to Ask First waits for the user's answer to a
    /// card in the chat, except an implement chat's change of its own items: `bundleTickets` gives a bundle's
    /// tickets for it; without it, only the chat's own ticket or bundle counts.
    @MainActor
    public static func check(_ caller: MCPCaller, _ operation: ToolOperation, _ arguments: JSONValue, chats: ChatSession,
                             defaults: UserDefaults = .standard, mode given: ChatPermissionMode? = nil,
                             bundleTickets: @MainActor (String) -> [String]? = { _ in nil },
                             projectFamily: @MainActor (String) -> Set<String> = { [$0] }) async -> ToolError? {
        if case .internalSkill(let name) = caller {
            // The app runs the skill in the background, for its answer alone: it reads, and opens no window. A comment
            // answer also changes its own ticket's title, description, links and status, as V2's did.
            if operation.permission == .read && operation.name != "open_in_app" { return nil }
            if let ticket = commentAnswerTicket(name), ["update_ticket", "set_ticket_status"].contains(operation.name),
               arguments["ticketID"]?.stringValue?.uppercased() == ticket {
                return nil
            }
            return ToolError(.forbidden, skillRefusal)
        }
        guard case .chat(let chatID) = caller else { return nil }
        func rule(_ key: String) -> ChangePermission {
            defaults.string(forKey: key).flatMap(ChangePermission.init(rawValue:)) ?? .askFirst
        }
        // The chat's permission mode, as V2's: Plan Only changes nothing; Don't Ask refuses what would ask; Allow
        // All runs it. Never stays a refusal.
        let mode = given ?? ChatPermissionMode(stored: chats.chats[chatID]?.file.settings.permissionMode ?? "")
        // A GET or HEAD api_call reads, and closing the chat itself or the chats it started changes nothing of the
        // user's: they run under Plan Only as V2's did.
        let operationText = arguments["operation"]?.stringValue ?? ""
        let readsAPI = operation.permission == .callAPIs && (operationText.hasPrefix("GET ") || operationText.hasPrefix("HEAD "))
        let closesOwn = operation.permission == .closeChats && (arguments["chatIDs"]?.arrayValue ?? []).compactMap(\.stringValue).allSatisfy {
            $0.uppercased() == chatID || chats.chats[$0.uppercased()]?.file.orchestratorChatID == chatID
        }
        if mode == .plan, ![.read, .renameChats, .askUser].contains(operation.permission), !readsAPI, !closesOwn {
            return ToolError(.forbidden, "The chat is in Plan Only: Claude plans and changes nothing.")
        }
        func ask(_ refusal: String) async -> ToolError? {
            switch mode {
            case .bypassPermissions: return nil
            case .dontAsk: return ToolError(.forbidden, "The chat doesn't ask (Don't Ask): \(refusal)")
            default:
                switch await chats.requestApproval(chatID, tool: operation.name, input: arguments) {
                case .allowed: return nil
                case .refused: return ToolError(.forbidden, "The user didn't allow this call.")
                case .expired: return ToolError(.forbidden, "No one answered the card in 29 minutes: the call didn't run.")
                }
            }
        }
        let permission: ChangePermission
        let refusal: String
        switch operation.permission {
        case .read, .renameChats, .askUser:
            return nil
        case .closeChats:
            // Its own chat, and the chats it started, close without asking (V2's orchestrators); another one asks first.
            let others = (arguments["chatIDs"]?.arrayValue ?? []).compactMap(\.stringValue).map { $0.uppercased() }.filter {
                $0 != chatID && chats.chats[$0]?.file.orchestratorChatID != chatID
            }
            if others.isEmpty { return nil }
            return await ask("closing another chat asks first.")
        case .changeTickets:
            permission = rule(ChatPreferences.ticketChangesKey)
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
            // An implement chat changes its own items without a card (the user's choice): every ticketID and bundleID
            // the call names is its own.
            let named = ["ticketID", "bundleID"].compactMap { arguments[$0]?.stringValue?.uppercased() }
            if permission == .askFirst, !named.isEmpty,
               named.allSatisfy({ chats.ownsItem($0, chat: chatID, bundleTickets: bundleTickets) }) {
                return nil
            }
            // `watch_ci` names no item: it links the calling chat's own ticket or bundle, and refuses other chats.
            if permission == .askFirst, operation.name == "watch_ci" { return nil }
        case .deleteTickets:
            permission = rule(ChatPreferences.ticketChangesKey) == .never ? .never : .askFirst
            refusal = "The user doesn't let Claude change tickets from chats (Settings ▸ Chat)."
        case .changeProjects:
            permission = rule(ChatPreferences.projectChangesKey)
            refusal = "The user doesn't let Claude change projects from chats (Settings ▸ Chat)."
        case .removeProjects:
            // Its own project would end the chat's Claude in the middle of the call, as V2 refused.
            let removed = (arguments["projectID"]?.stringValue ?? "").uppercased()
            if let own = chats.chats[chatID]?.projectID, projectFamily(removed).contains(own) {
                return ToolError(.forbidden, "A chat can't remove its own project or a project above it.")
            }
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
            return await ask(refusal.replacingOccurrences(of: "doesn't let", with: "asks before letting"))
        }
    }
}

/// The chat operations the MCP server offers Claude (docs/mcp.md › Chat tools).
public enum ChatTools {
    @MainActor
    public static func operations(chats: ChatSession, projects: ProjectSession) -> [ToolOperation] {
        [listChats(chats, projects), getChat(chats), renameChat(chats), closeChat(chats), askQuestions(chats), showImage(chats)]
            + PickerKind.allCases.map { askPicker($0, chats) }
    }

    static let chatID = ToolSchema.string("Chat id, an uppercase UUID.")

    @MainActor
    static func listChats(_ chats: ChatSession, _ projects: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "list_chats",
            description: "Returns a project's chats, its sub projects' included, the latest first: id, project, title, kind, created, updated, origin, model, effort, permissionMode, state, closed, backgroundWork, questionsBlocked, the orchestrator that started it, and its context usage when known.",
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
            description: "Closes chats. Without chatIDs, closes the calling chat once its current turn ends; the conversation stays, and a message reopens it. With chatIDs, closes those chats of the calling chat's project; a chat where Claude is at work, a chat of another project or an unknown one is refused, and the others still close. Closing another chat than the calling one, or the chats it started, asks the user first. Returns the chats closed, whether the calling chat closes after its turn, and each refusal with its reason.",
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
            // An implement chat asks nothing until the user writes in it (docs/data.md › Implement chats), but once
            // after a CI failure (CI chats).
            if let refusal = chats.questionsRefusal(in: chatID, questions: true) { throw ToolError(.forbidden, refusal) }
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

    /// The refusal of `show_image` for a caller that isn't a chat's Claude.
    static let showRefusal = "Only a chat's own Claude can show images."

    static func showImage(_ chats: ChatSession) -> ToolOperation {
        ToolOperation(
            name: "show_image",
            description: "Shows the user images in this chat, at the place of this call: an image you made or a screenshot you took. Give the paths of 1 to 10 PNG, JPEG, GIF or WebP files on this Mac (absolute, starting with ~/, or from the project's folder) and an optional Markdown caption shown above them. The app copies the images into the chat, so they stay after the files are deleted; the user can open each one. Any other file, or a path that can't be read, refuses the whole call. Asks the user nothing.",
            inputSchema: .object(properties: [
                ("paths", .array("1 to 10 image files, shown in this order.", of: .string())),
                ("caption", .string("Text shown above the images, in Markdown; optional.")),
            ], required: ["paths"]),
            permission: .askUser,
            describe: { arguments in
                let count = arguments["paths"]?.arrayValue?.count ?? 0
                return ToolCallText(action: count == 1
                    ? String(localized: "Showed an image", bundle: #bundle, comment: "Claude showed the user one image")
                    : String(localized: "Showed \(count) images", bundle: #bundle, comment: "Claude showed the user several images; the value is their number"))
            }
        ) { @MainActor arguments throws(ToolError) in
            guard let chatID = MCPCaller.current.chatID else { throw ToolError(.forbidden, showRefusal) }
            let paths = (arguments["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
            do throws(ChatError) {
                try chats.postImages(chatID, paths: paths, caption: arguments["caption"]?.stringValue)
            } catch {
                switch error {
                case .notFound(let message): throw ToolError(.notFound, message)
                case .invalid(let message): throw ToolError(.invalid, message)
                default: throw ToolError(.internal, error.description)
                }
            }
            return .string("images shown in the chat")
        }
    }

    /// The refusal of a picker request through another token than a chat's.
    static let pickerRefusal = "Only a chat's own Claude can ask the user: there is no chat to show the request in."

    /// The end of every picker tool's description.
    private static let pickerEnding = " A chat has one request or set of questions waiting at most. Only a chat's own Claude can ask."

    /// `ask_symbol`, `ask_color`, `ask_sound`, `ask_shortcut`, `ask_font` and `ask_animation` (docs/mcp.md): a card
    /// over the chat's composer; the answer comes later, as the user's message.
    @MainActor
    static func askPicker(_ kind: PickerKind, _ chats: ChatSession) -> ToolOperation {
        let question: (String, ToolSchema) = ("question", .string("The question, in Markdown."))
        let description: String
        var properties: [(String, ToolSchema)]
        let action: String
        switch kind {
        case .symbol:
            description = "Shows the user a card in this chat to choose one SF Symbol, and returns at once with the request's id. Give the question, 2 to 10 SF Symbol names this Mac has and the recommended one, which the card preselects; the user can also search every symbol of the Mac, answer in their own words or skip. The user's next message gives the answer: \"Symbol: ![](sf:<name>)\" for a chosen symbol, \"Symbol: <text>\" for their own words, or \"Symbol: Skipped\"."
            properties = [question, ("suggestions", .array("2 to 10 distinct SF Symbol names, such as line.3.horizontal.decrease.circle.", of: .string())),
                          ("recommended", .string("The recommended symbol: one of the suggestions."))]
            action = String(localized: "Asked for a symbol", bundle: #bundle, comment: "Claude asked the user to choose an SF Symbol")
        case .color:
            description = "Shows the user a card in this chat to choose one color, or a light and dark pair, and returns at once with the request's id. A color is a hex color #RRGGBB (sRGB, opaque) or a system color name such as systemBlue, label or accentColor. Give the question, 2 to 10 suggestions and the recommended one, which the card preselects. Set lightAndDark for a color that has a light and a dark appearance, such as a color set of an asset catalog: each suggestion and the recommended one are then objects {\"light\": \"<color>\", \"dark\": \"<color>\"}. The card shows the suggestions as swatches with every system color, the macOS color panel and a hex field; the user can switch between one color and a pair, answer in their own words or skip. The user's next message gives the answer: \"Color: ![](color:<color>)\" for one color, \"Color: Light ![](color:<color>), Dark ![](color:<color>)\" for a pair, \"Color: <text>\" for their own words, or \"Color: Skipped\"."
            properties = [question,
                          ("suggestions", .array("2 to 10 distinct suggestions: colors, or with lightAndDark objects {\"light\": \"<color>\", \"dark\": \"<color>\"}.",
                                                 of: .anyValue("A color, or with lightAndDark an object {\"light\": \"<color>\", \"dark\": \"<color>\"}."))),
                          ("recommended", .anyValue("The recommended suggestion: one of the suggestions.")),
                          ("lightAndDark", .boolean("true to ask for a light and dark pair; false when absent."))]
            action = String(localized: "Asked for a color", bundle: #bundle, comment: "Claude asked the user to choose a color")
        case .sound:
            description = "Shows the user a card in this chat to choose one sound for an app of an Apple platform, and returns at once with the request's id; only in a project of type App (a Swift application). A sound is named macOS/<file> for a file of /System/Library/Sounds, such as macOS/Glass.aiff; <runtime>/<path> for a file under System/Library/Audio/UISounds of an installed Simulator runtime, <runtime> as xcrun simctl list runtimes names it, such as iOS 26.1/sms-received1.caf; or Project/<path> for a .caf, .aiff, .wav or .mp3 file of the project, its path from the project's folder. Give the question, 2 to 10 sound names and the recommended one, which the card preselects; the user can also search every sound of the Mac and the project, play them, answer in their own words or skip. The user's next message gives the answer: \"Sound: ![](sound:<name>)\" for a chosen sound, \"Sound: <text>\" for their own words, or \"Sound: Skipped\"."
            properties = [question, ("suggestions", .array("2 to 10 distinct sound names, such as macOS/Glass.aiff.", of: .string())),
                          ("recommended", .string("The recommended sound: one of the suggestions."))]
            action = String(localized: "Asked for a sound", bundle: #bundle, comment: "Claude asked the user to choose a sound")
        case .shortcut:
            description = "Shows the user a card in this chat to choose one keyboard shortcut, and returns at once with the request's id; only in a project of type App (a Swift application). Write each shortcut as macOS menus write it: the modifiers ⌃ ⌥ ⇧ ⌘, in this order, then one key: an uppercase letter, a digit or punctuation as the key types it without Shift, ↩ ⌤ ⎋ ⇥ Space ⌫ ⌦ ← → ↑ ↓ ↖ ↘ ⇞ ⇟, or F1 to F20, such as ⇧⌘K, ⇧⌘/ or ⌃⌥Space. Give the question, 2 to 10 shortcuts, the recommended one, which the card preselects, and in inUse every shortcut the app already uses with its command. The user can also record another combination, answer in their own words or skip; the card warns when the chosen shortcut is a standard macOS shortcut or one of inUse, without refusing it. The user's next message gives the answer: \"Shortcut: ![](shortcut:<shortcut>)\" for a chosen or recorded shortcut, \"Shortcut: <text>\" for their own words, or \"Shortcut: Skipped\"."
            let entry = ToolSchema.object(properties: [("shortcut", .string("The shortcut, in the same notation.")),
                                                       ("command", .string("The command that uses it, one line of 1 to 200 characters."))],
                                          required: ["shortcut", "command"])
            properties = [question, ("suggestions", .array("2 to 10 distinct shortcuts, such as ⇧⌘K.", of: .string())),
                          ("recommended", .string("The recommended shortcut: one of the suggestions.")),
                          ("inUse", .array("Every shortcut the app already uses, at most 500, each once, such as ⌘N with New Ticket; empty when it has none.", of: entry))]
            action = String(localized: "Asked for a shortcut", bundle: #bundle, comment: "Claude asked the user to choose a keyboard shortcut")
        case .font:
            description = "Shows the user a card in this chat to choose one font, and returns at once with the request's id. A font is a Dynamic Type text style, .largeTitle, .title, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote, .caption or .caption2, or <family>/<weight>/<size>: a family of this Mac or of the project's font files, one of its weights as macOS names them, and a size of 1 to 999 points with at most one decimal, such as System Rounded/Semibold/17 or Avenir Next/Demi Bold/15; System, System Rounded, System Serif and System Monospaced are the system font's designs, with the weights Ultralight, Thin, Light, Regular, Medium, Semibold, Bold, Heavy and Black. Give the question, the sample text the card draws in the chosen font, taken from where the font will be used, 2 to 10 fonts and the recommended one, which the card preselects; the user can also search every font, change the weight and size, answer in their own words or skip. The user's next message gives the answer: \"Font: ![](font:<font>)\" for a chosen font, \"Font: <text>\" for their own words, or \"Font: Skipped\"."
            properties = [question, ("sample", .string("The text the card draws in the chosen font.")),
                          ("suggestions", .array("2 to 10 distinct fonts, such as .headline or System Rounded/Semibold/17.", of: .string())),
                          ("recommended", .string("The recommended font: one of the suggestions."))]
            action = String(localized: "Asked for a font", bundle: #bundle, comment: "Claude asked the user to choose a font")
        case .animation:
            description = "Shows the user a card in this chat to choose one animation, and returns at once with the request's id; only in a project of type App (a Swift application). An animation is a SwiftUI preset written as its expression: .smooth, .snappy or .bouncy with (duration:extraBounce:), .spring with (duration:bounce:), .easeIn, .easeOut, .easeInOut or .linear with (duration:); the parameters are optional, in this order, a parameter left out taking SwiftUI's default, such as .snappy, .spring(duration: 0.4, bounce: 0.2) or .easeInOut(duration: 0.25). duration is 0.1 to 2 seconds, bounce -1 to 1, extraBounce 0 to 1. Give the question, 2 to 10 expressions and the recommended one, which the card preselects; the card plays each one, and the user can also make their own with a preset and sliders, answer in their own words or skip. The user's next message gives the answer: \"Animation: ![](animation:<expression>)\" for a chosen animation, \"Animation: <text>\" for their own words, or \"Animation: Skipped\"."
            properties = [question, ("suggestions", .array("2 to 10 distinct animation expressions, such as .spring(duration: 0.4, bounce: 0.2).", of: .string())),
                          ("recommended", .string("The recommended animation: one of the suggestions."))]
            action = String(localized: "Asked for an animation", bundle: #bundle, comment: "Claude asked the user to choose an animation")
        }
        let required = properties.map(\.0).filter { $0 != "lightAndDark" }
        return ToolOperation(
            name: kind.toolName,
            description: description + pickerEnding,
            inputSchema: .object(properties: properties, required: required),
            permission: .askUser,
            describe: { _ in ToolCallText(action: action) }
        ) { @MainActor arguments throws(ToolError) in
            guard let chatID = MCPCaller.current.chatID else { throw ToolError(.forbidden, pickerRefusal) }
            if let refusal = chats.questionsRefusal(in: chatID) { throw ToolError(.forbidden, refusal) }
            let item = try await chats.postPicker(chatID, kind: kind, input: arguments)
            return ["requestID": .string(item.requestID)]
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
            // V2's: whether it is closed, its mode, whether it may ask, and its background work.
            "closed": .bool(chat.file.closed), "permissionMode": .string(chat.file.settings.permissionMode),
            "questionsBlocked": .bool(chat.file.questionsBlocked), "backgroundWork": .bool(chats.backgroundWork.contains(chat.id)),
        ]
        if let orchestrator = chat.file.orchestratorChatID { object["orchestrator"] = .string(orchestrator) }
        if let usage = chat.file.contextUsage {
            object["contextUsage"] = ["usedTokens": .int(usage.usedTokens), "windowTokens": .int(usage.windowTokens),
                                      "bufferTokens": .int(usage.bufferTokens)]
        }
        if let origin = chat.file.origin { object["origin"] = .string(origin) }
        if let ticket = chat.file.ticketID { object["ticket"] = .string(ticket) }
        if let bundle = chat.file.bundleID { object["bundle"] = .string(bundle) }
        return .object(object)
    }
}
