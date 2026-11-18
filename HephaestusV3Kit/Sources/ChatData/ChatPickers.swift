import ExternalTools
import FileStorage
import Foundation
import MCPKit
import ProjectData
import TextFormats

/// What a picker request asks the user to choose (docs/data.md › Picker requests): V2's six requests, each its
/// own transcript item type.
public enum PickerKind: String, Sendable, Hashable, CaseIterable {
    case symbol, color, sound, shortcut, font, animation

    /// The MCP tool that asks: `ask_symbol`…
    public var toolName: String { "ask_\(rawValue)" }

    /// The first word of the answer's message and of the notification's input: `Symbol`…
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The answer's marker scheme: `sf` for a symbol, the kind's name for the others.
    public var markerScheme: String { self == .symbol ? "sf" : rawValue }

    /// Only Swift application projects ask for sounds, shortcuts and animations.
    public var needsApplicationProject: Bool { self == .sound || self == .shortcut || self == .animation }

    /// V2's refusal in another project.
    var projectRefusal: String {
        switch self {
        case .sound: "ask_sound is only available in Swift application projects."
        default: "\(toolName) is available only in Swift application projects."
        }
    }

    /// V2's conflict while a request of this kind waits in the chat.
    var waitingConflict: String {
        self == .animation ? "An animation request is already waiting for an answer in this chat."
            : "A \(rawValue) request is already waiting for an answer in this chat."
    }

    /// V2's conflict when the request already has its answer.
    var answeredConflict: String { "This \(rawValue) request was already answered." }
}

/// A suggestion of a picker request: a value, or for a color request asked in light and dark a pair.
public struct PickerSuggestion: Sendable, Hashable {
    /// The value; a pair's light color.
    public var value: String
    /// A pair's dark color; nil for one value.
    public var dark: String?

    public init(_ value: String, dark: String? = nil) {
        self.value = value
        self.dark = dark
    }

    public var isPair: Bool { dark != nil }

    /// A string, or a pair `{"light", "dark"}`, as V2 wrote it.
    var json: JSONValue {
        guard let dark else { return .string(value) }
        return ["light": .string(value), "dark": .string(dark)]
    }

    init?(json: JSONValue) {
        if let value = json.stringValue {
            self.init(value)
        } else if let light = json["light"]?.stringValue, let dark = json["dark"]?.stringValue {
            self.init(light, dark: dark)
        } else {
            return nil
        }
    }
}

/// A shortcut the app of a shortcut request already uses, and its command.
public struct ShortcutInUse: Sendable, Hashable {
    public var shortcut: String
    public var command: String

    public init(shortcut: String, command: String) {
        self.shortcut = shortcut
        self.command = command
    }
}

/// A picker request: Claude asks the user to choose a symbol, a color, a sound, a shortcut, a font or an
/// animation (docs/data.md › Picker requests). The item's type is its kind; its keys are V2's.
public struct PickerItem: Sendable, Hashable, Identifiable {
    public var kind: PickerKind
    public var id: String
    public var created: Date
    /// The request's id; the item's `id` too.
    public var requestID: String
    /// Markdown.
    public var question: String
    /// 2 to 10, in Claude's order.
    public var suggestions: [PickerSuggestion]
    /// One of `suggestions`.
    public var recommended: PickerSuggestion
    /// A color request: Claude asked for a light and dark pair.
    public var lightAndDark: Bool
    /// A font request: the text the card draws in the chosen font.
    public var sample: String?
    /// A shortcut request: the app's own shortcuts.
    public var inUse: [ShortcutInUse]
    /// Nil until the user answers: then a marker, the user's own text, or `Skipped`.
    public var answer: String?
    /// The keys V3 doesn't read, kept as read and written back.
    public var otherKeys: [String: JSONValue]

    public init(kind: PickerKind, id: String, created: Date, question: String, suggestions: [PickerSuggestion], recommended: PickerSuggestion,
                lightAndDark: Bool = false, sample: String? = nil, inUse: [ShortcutInUse] = [], answer: String? = nil) {
        self.kind = kind
        self.id = id
        self.created = created
        requestID = id
        self.question = question
        self.suggestions = suggestions
        self.recommended = recommended
        self.lightAndDark = lightAndDark
        self.sample = sample
        self.inUse = inUse
        self.answer = answer
        otherKeys = [:]
    }

    /// The message that gives Claude the answer: `<Kind>: <answer>`, such as `Symbol: ![](sf:star)`.
    public var answerMessage: String {
        "\(kind.title): \(answer ?? Self.skipped)"
    }

    /// What a skipped request's answer reads.
    public static let skipped = "Skipped"

    /// The marker of a value of this request's kind: `![](sf:<name>)`, `![](color:<color>)`…; a shortcut's key
    /// `(`, `)` or `\` escaped.
    public func marker(_ value: String) -> String {
        if kind == .shortcut, let shortcut = KeyShortcut(value) { return shortcut.marker }
        return "![](\(kind.markerScheme):\(value))"
    }

    /// The color card's answer for a pair: `Light ![](color:<light>), Dark ![](color:<dark>)`.
    public static func pairMarker(light: String, dark: String) -> String {
        "Light ![](color:\(light)), Dark ![](color:\(dark))"
    }

    /// A suggestion as the transcript's card lists it: its marker, a pair as the pair's answer.
    public func line(_ suggestion: PickerSuggestion) -> String {
        if let dark = suggestion.dark { return Self.pairMarker(light: suggestion.value, dark: dark) }
        return marker(suggestion.value)
    }
}

// MARK: JSON

extension PickerItem {
    /// The keys of the kind, in V2's form, after the unknown keys.
    var json: JSONValue {
        var object = otherKeys
        object["type"] = .string(kind.rawValue)
        object["id"] = .string(id)
        object["created"] = .string(ISODate.string(from: created))
        object["requestID"] = .string(requestID)
        object["question"] = .string(question)
        object["suggestions"] = .array(suggestions.map(\.json))
        object["recommended"] = recommended.json
        object["answer"] = answer.map(JSONValue.string) ?? .null
        switch kind {
        case .color: object["lightAndDark"] = .bool(lightAndDark)
        case .font: object["sample"] = .string(sample ?? "")
        case .shortcut: object["inUse"] = .array(inUse.map { ["shortcut": .string($0.shortcut), "command": .string($0.command)] })
        case .symbol, .sound, .animation: break
        }
        return .object(object)
    }

    static let knownKeys: Set<String> = ["type", "id", "created", "requestID", "question", "suggestions", "recommended", "answer",
                                         "lightAndDark", "sample", "inUse"]

    /// A request of a transcript line, as V2 wrote it; nil without its question, suggestions or recommendation.
    init?(kind: PickerKind, id: String, created: Date, object: [String: JSONValue]) {
        guard let question = object["question"]?.stringValue,
              let suggestions = object["suggestions"]?.arrayValue?.compactMap(PickerSuggestion.init(json:)), !suggestions.isEmpty,
              let recommended = object["recommended"].flatMap(PickerSuggestion.init(json:)) else { return nil }
        self.init(kind: kind, id: id, created: created, question: question, suggestions: suggestions, recommended: recommended,
                  lightAndDark: object["lightAndDark"]?.boolValue ?? false, sample: object["sample"]?.stringValue,
                  inUse: (object["inUse"]?.arrayValue ?? []).compactMap { entry in
                      guard let shortcut = entry["shortcut"]?.stringValue, let command = entry["command"]?.stringValue else { return nil }
                      return ShortcutInUse(shortcut: shortcut, command: command)
                  },
                  answer: object["answer"]?.stringValue)
        requestID = object["requestID"]?.stringValue ?? id
        otherKeys = object.filter { !Self.knownKeys.contains($0.key) }
    }
}

// MARK: Rules

/// The catalogues a request's suggestions are checked against; those a kind doesn't need stay nil.
public struct PickerCatalogSnapshot: Sendable {
    public var symbols: SFSymbolCatalog?
    public var sounds: SoundCatalog?
    public var fonts: FontCatalog?

    public init(symbols: SFSymbolCatalog? = nil, sounds: SoundCatalog? = nil, fonts: FontCatalog? = nil) {
        self.symbols = symbols
        self.sounds = sounds
        self.fonts = fonts
    }
}

extension PickerItem {
    /// The request an `ask_<kind>` call gives, checked against V2's rules in their order (docs/data.md › Picker
    /// requests); throws the first one broken, as `invalid`. Every value is trimmed; the item has a new id.
    public static func request(_ kind: PickerKind, from input: JSONValue, catalogs: PickerCatalogSnapshot, created: Date) throws(ToolError) -> PickerItem {
        func fail(_ message: String) -> ToolError { ToolError(.invalid, message) }
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tool = kind.toolName
        let question = trimmed(input["question"]?.stringValue ?? "")
        guard !question.isEmpty else { throw fail("\(tool) needs a question.") }
        var sample: String?
        if kind == .font {
            let text = trimmed(input["sample"]?.stringValue ?? "")
            guard !text.isEmpty else { throw fail("ask_font needs a sample text.") }
            sample = text
        }
        let entries = input["suggestions"]?.arrayValue ?? []
        guard (2...10).contains(entries.count) else { throw fail("\(tool) needs 2 to 10 suggestions.") }

        if kind == .color {
            return try colorRequest(question: question, entries: entries, input: input, created: created)
        }
        let suggestions = entries.map { trimmed($0.stringValue ?? "") }
        guard !suggestions.contains(""), Set(suggestions).count == suggestions.count else { throw fail("\(tool) has an empty or repeated suggestion.") }
        for suggestion in suggestions {
            switch kind {
            case .symbol:
                guard catalogs.symbols?.contains(suggestion) == true else { throw fail("\(suggestion) is not an SF Symbol of this Mac.") }
            case .sound:
                guard catalogs.sounds?.contains(suggestion) == true else { throw fail("\(suggestion) is not a sound of this Mac or of the project.") }
            case .shortcut:
                guard KeyShortcut(suggestion) != nil else { throw fail(shortcutNotationMessage(suggestion)) }
            case .font:
                switch FontNotation.parse(suggestion) {
                case .failure(.notation):
                    throw fail("\(suggestion) is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17.")
                case .failure(.size):
                    throw fail("\(suggestion): the size must be 1 to 999 pt, with at most one decimal.")
                case .success(let font):
                    guard catalogs.fonts?.contains(font) == true else { throw fail("\(suggestion) is not a font of this Mac.") }
                }
            case .animation:
                do throws(AnimationExpressionError) {
                    _ = try AnimationExpression(parsing: suggestion)
                } catch {
                    throw fail(AnimationExpression.message(for: error, suggestion: suggestion))
                }
            case .color:
                break
            }
        }
        let recommended = trimmed(input["recommended"]?.stringValue ?? "")
        guard suggestions.contains(recommended) else {
            let noun = kind == .symbol ? "symbol" : kind.rawValue
            throw fail("\(tool): the recommended \(noun) must be one of the suggestions.")
        }
        var inUse: [ShortcutInUse] = []
        if kind == .shortcut {
            let listed = input["inUse"]?.arrayValue ?? []
            guard listed.count <= 500 else { throw fail("ask_shortcut accepts at most 500 inUse entries.") }
            var seen: Set<String> = []
            for entry in listed {
                let shortcut = trimmed(entry["shortcut"]?.stringValue ?? "")
                let command = trimmed(entry["command"]?.stringValue ?? "")
                guard KeyShortcut(shortcut) != nil else { throw fail(shortcutNotationMessage(shortcut)) }
                guard (1...200).contains(command.count), !command.contains(where: \.isNewline) else {
                    throw fail("ask_shortcut: the command of \(shortcut) in inUse must be one line of 1 to 200 characters.")
                }
                guard seen.insert(shortcut).inserted else { throw fail("ask_shortcut: \(shortcut) appears twice in inUse.") }
                inUse.append(ShortcutInUse(shortcut: shortcut, command: command))
            }
        }
        return PickerItem(kind: kind, id: UUID().uuidString, created: created, question: question, suggestions: suggestions.map { PickerSuggestion($0) },
                          recommended: PickerSuggestion(recommended), sample: sample, inUse: inUse)
    }

    static func shortcutNotationMessage(_ shortcut: String) -> String {
        "\(shortcut) is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key."
    }

    /// `ask_color`'s rules: one color per suggestion, or with `lightAndDark` a pair; each color a hex color or a
    /// system color name, checked in order, a pair's light before its dark; distinct suggestions; the
    /// recommendation one of them.
    private static func colorRequest(question: String, entries: [JSONValue], input: JSONValue, created: Date) throws(ToolError) -> PickerItem {
        func fail(_ message: String) -> ToolError { ToolError(.invalid, message) }
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lightAndDark = input["lightAndDark"]?.boolValue ?? false
        func read(_ value: JSONValue?) throws(ToolError) -> PickerSuggestion {
            if lightAndDark {
                guard let light = value?["light"]?.stringValue, let dark = value?["dark"]?.stringValue else {
                    throw fail("ask_color needs a light and dark pair per suggestion.")
                }
                return PickerSuggestion(trimmed(light), dark: trimmed(dark))
            }
            guard let color = value?.stringValue else {
                throw fail("ask_color needs one color per suggestion, or lightAndDark for light and dark pairs.")
            }
            return PickerSuggestion(trimmed(color))
        }
        var suggestions: [PickerSuggestion] = []
        for entry in entries {
            suggestions.append(try read(entry))
        }
        let recommended = try read(input["recommended"])
        for suggestion in suggestions {
            for color in [suggestion.value] + [suggestion.dark].compactMap({ $0 }) where !SystemColors.isColor(color) {
                throw fail("\(color) is not a hex color #RRGGBB or a system color name.")
            }
        }
        func same(_ a: PickerSuggestion, _ b: PickerSuggestion) -> Bool {
            SystemColors.isSame(a.value, b.value) && (a.dark == nil) == (b.dark == nil)
                && (a.dark.map { dark in b.dark.map { SystemColors.isSame(dark, $0) } ?? false } ?? true)
        }
        for (index, suggestion) in suggestions.enumerated() where suggestions[..<index].contains(where: { same($0, suggestion) }) {
            throw fail("ask_color has a repeated suggestion.")
        }
        guard suggestions.contains(where: { same($0, recommended) }) else {
            throw fail("ask_color: the recommended color must be one of the suggestions.")
        }
        return PickerItem(kind: .color, id: UUID().uuidString, created: created, question: question, suggestions: suggestions,
                          recommended: recommended, lightAndDark: lightAndDark)
    }

    /// `answer` trimmed, 1 to 10,000 characters.
    public static func checkedAnswer(_ answer: String) throws(ChatError) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...10_000).contains(trimmed.count) else { throw .invalid("answer: write 1 to 10,000 characters.") }
        return trimmed
    }
}

// MARK: Posting and answering

extension ChatSession {
    /// The chat's picker request waiting for the user's answer; nil when none, or when its transcript isn't read.
    public func waitingPicker(in chatID: String) -> PickerItem? {
        for case .picker(let item) in (transcripts[chatID] ?? []).reversed() where item.answer == nil {
            return item
        }
        return nil
    }

    /// Why nothing more can be asked in the chat: the conflict of the questions or request that waits; nil when
    /// none does. A chat has one request waiting at most (docs/data.md › Picker requests).
    func waitingConflict(in chatID: String) -> String? {
        if waitingQuestions(in: chatID) != nil { return "Questions already wait for the user's answers in this chat." }
        return waitingPicker(in: chatID)?.kind.waitingConflict
    }

    /// The catalogues the chat's project gives a request of `kind`.
    public func pickerCatalogs(_ kind: PickerKind, for chatID: String) async -> PickerCatalogSnapshot {
        switch kind {
        case .symbol:
            return PickerCatalogSnapshot(symbols: await catalogs.symbols())
        case .sound:
            guard let root = folder(of: chatID)?.root else { return PickerCatalogSnapshot() }
            return PickerCatalogSnapshot(sounds: await catalogs.sounds(project: root, files: projectFiles(of: chatID)))
        case .font:
            guard let root = folder(of: chatID)?.root else { return PickerCatalogSnapshot() }
            return PickerCatalogSnapshot(fonts: await catalogs.fonts(project: root, files: projectFiles(of: chatID)))
        case .color, .shortcut, .animation:
            return PickerCatalogSnapshot()
        }
    }

    /// The file of a sound marker's sound (docs/text.md › Markers › Sounds): a macOS or Simulator runtime sound of
    /// the Mac, or `Project/<path>` a sound file in the folder `projectRoot`; nil for any other name.
    public func soundFile(named name: String, projectRoot: String?) async -> URL? {
        let prefix = SoundCatalog.projectSource + "/"
        if name.hasPrefix(prefix) {
            guard let projectRoot else { return nil }
            let path = String(name.dropFirst(prefix.count))
            let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
            let file = root.appendingPathComponent(path).standardizedFileURL
            var isFolder: ObjCBool = false
            guard SoundCatalog.isSoundFile(path), file.path.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
            return file
        }
        return await catalogs.systemSounds().files[name]
    }

    /// How the chat's project lists its files: with git when the tools found it, its sub projects left out.
    func projectFiles(of chatID: String) -> ProjectFiles {
        projectFiles(ofProject: chats[chatID]?.projectID ?? "")
    }

    /// How a project lists its files for its sounds and fonts.
    public func projectFiles(ofProject projectID: String) -> ProjectFiles {
        let snapshot = projects.snapshot
        guard let project = snapshot.project(projectID) else { return ProjectFiles(git: nil) }
        let prefix = project.root.hasSuffix("/") ? project.root : project.root + "/"
        let excluded = snapshot.projects.compactMap { other -> String? in
            other.id != project.id && other.root.hasPrefix(prefix) ? String(other.root.dropFirst(prefix.count)) : nil
        }
        return ProjectFiles(git: Git(projects.tools, runner: runner), excluded: excluded)
    }

    /// Shows Claude's request in the chat, as `ask_<kind>` asks (docs/data.md › Picker requests): only in a Swift
    /// application project for a sound, a shortcut or an animation; a chat has one request waiting at most.
    public func postPicker(_ chatID: String, kind: PickerKind, input: JSONValue) async throws(ToolError) -> PickerItem {
        guard let chat = chats[chatID] else { throw ToolError(.notFound, "Chat \(chatID) not found.") }
        if kind.needsApplicationProject, projects.snapshot.project(chat.projectID)?.file.type != .swiftApplication {
            throw ToolError(.forbidden, kind.projectRefusal)
        }
        let catalogs = await pickerCatalogs(kind, for: chatID)
        let item = try PickerItem.request(kind, from: input, catalogs: catalogs, created: now())
        await open(chatID)
        guard chats[chatID] != nil else { throw ToolError(.notFound, "Chat \(chatID) not found.") }
        if let conflict = waitingConflict(in: chatID) { throw ToolError(.conflict, conflict) }
        record(.picker(item), in: chatID)
        refreshState(chatID)
        return item
    }

    /// Stores the user's answer to the chat's request, once, and sends Claude `<Kind>: <answer>` as the user's
    /// message, starting the chat's CLI when none runs.
    public func answerPicker(_ chatID: String, requestID: String, answer: String) async throws(ChatError) {
        guard chats[chatID] != nil else { throw .notFound("Chat \(chatID) not found.") }
        let checked = try PickerItem.checkedAnswer(answer)
        guard let waiting = item(requestID, in: chatID), case .picker(let request) = waiting else { throw .notFound("Request \(requestID) not found.") }
        guard request.answer == nil else { throw .conflict(request.kind.answeredConflict) }
        let cli = try await availableCLI()
        // The request may have its answer by now.
        guard case .picker(var item)? = item(requestID, in: chatID), item.answer == nil else { throw .conflict(request.kind.answeredConflict) }
        item.answer = checked
        record(.picker(item), in: chatID, op: .update)
        post(item.answerMessage, references: [], images: [], to: chatID, cli: cli)
        refreshState(chatID)
    }
}
