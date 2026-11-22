import FileStorage
import Foundation

/// `.hephaestus/chats/<CHAT-ID>.yml`: a chat's metadata (docs/data.md › Chat file), with its
/// `origin`; the chat's transcript is the `.jsonl` file next to it.
public struct ChatFile: Codable, Sendable, Hashable {
    /// What started the chat. The app starts `project` chats, and `feedback` chats from Send Feedback; it reads
    /// the other kinds as they are.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case project, ticket, bundle, feedback, ci, setup
    }

    public var schema: Int
    /// An uppercase UUID: the file's name, and the Claude CLI's session id.
    public var id: String
    /// One line, 1 to 100 characters.
    public var title: String
    public var kind: Kind
    public var ticketID: String?
    public var bundleID: String?
    /// The orchestrating chat, for ticket and CI chats; written only when set.
    public var orchestratorChatID: String?
    /// The virtual machine image, for Auto Setup chats; written only when set.
    public var imageID: String?
    public var created: Date
    /// The last change: of the metadata, a message sent, a turn ended.
    public var updated: Date
    public var settings: ChatSettings
    /// True once the Claude CLI has created the session: later launches resume it.
    public var sessionStarted: Bool
    public var closed: Bool
    /// Implement chats only; written only when true.
    public var questionsBlocked: Bool
    /// V3 addition: the tool whose chat panel started the chat (a `ToolKind` value, such as `tickets`); nil
    /// for a chat of the Chat window and for the other kinds. Written only when set.
    public var origin: String?
    /// Keys the app doesn't read, `contextUsage` among them, written back after the known ones.
    public var unknownKeys: YAMLMapping

    public init(id: String, title: String, kind: Kind = .project, created: Date, settings: ChatSettings = ChatSettings(),
                origin: String? = nil) {
        schema = 1
        self.id = id
        self.title = title
        self.kind = kind
        self.created = created
        updated = created
        self.settings = settings
        sessionStarted = false
        closed = false
        questionsBlocked = false
        self.origin = origin
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = [
        "schema", "id", "title", "kind", "ticket", "bundle", "orchestrator", "image", "created", "updated", "settings",
        "sessionStarted", "closed", "questionsBlocked", "origin",
        // Runtime keys: never in a file, ignored when they are.
        "projectID", "state", "backgroundWork", "compactingSince", "costUSD", "mentionedIDs",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        id = try c.required("id")
        try c.check("id", id, ChatIDs.isChatID, "chat id")
        title = try c.value("title", default: "New Chat")
        kind = try c.required("kind")
        ticketID = try c.optional("ticket")
        bundleID = try c.optional("bundle")
        orchestratorChatID = try c.optional("orchestrator")
        imageID = try c.optional("image")
        created = try c.requiredDate("created")
        updated = try c.optionalDate("updated") ?? created
        settings = try c.value("settings", default: ChatSettings())
        sessionStarted = try c.value("sessionStarted", default: false)
        closed = try c.value("closed", default: false)
        questionsBlocked = try c.value("questionsBlocked", default: false)
        origin = try c.optional("origin")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
        if let message = kindViolation {
            throw c.invalid("kind", message)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(id, "id")
        try c.encode(title, "title")
        try c.encode(kind, "kind")
        try c.encodeOptional(ticketID, "ticket")
        try c.encodeOptional(bundleID, "bundle")
        try c.encodeIfPresent(orchestratorChatID, "orchestrator")
        try c.encodeIfPresent(imageID, "image")
        try c.encodeDate(created, "created")
        try c.encodeDate(updated, "updated")
        try c.encode(settings, "settings")
        try c.encode(sessionStarted, "sessionStarted")
        try c.encode(closed, "closed")
        if questionsBlocked { try c.encode(true, "questionsBlocked") }
        try c.encodeIfPresent(origin, "origin")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// The rules of the kinds (docs/data.md › Chat kinds); nil when the file follows them.
    var kindViolation: String? {
        switch kind {
        case .ticket where ticketID == nil: return "a ticket chat names its ticket"
        case .bundle where bundleID == nil: return "a bundle chat names its bundle"
        case .ci where orchestratorChatID == nil || (ticketID == nil) == (bundleID == nil):
            return "a CI chat names its orchestrator, and its ticket or its bundle"
        case .setup where imageID == nil: return "an Auto Setup chat names its image"
        default: break
        }
        if orchestratorChatID != nil, kind != .ticket, kind != .ci { return "only ticket and CI chats have an orchestrator" }
        if imageID != nil, kind != .setup { return "only Auto Setup chats have an image" }
        if questionsBlocked, kind != .ticket { return "only ticket chats block questions" }
        return nil
    }
}

/// A chat's model and effort, and its other settings, kept as read (docs/data.md › Chat settings).
public struct ChatSettings: Codable, Sendable, Hashable {
    /// The CLI's model value: `default`, or a value of the CLI's model list such as `opus`.
    public var model: String
    public var effort: Effort
    /// The chat's permission mode, a `ChatPermissionMode` value, as V2's Permissions menu set it.
    public var permissionMode: String
    /// Ultracode: standing dynamic-workflow orchestration, as V2's toggle set it.
    public var ultracode: Bool
    /// The context window, a `ChatContextWindow` value.
    public var contextWindow: String
    public var unknownKeys: YAMLMapping

    public static let defaultModel = "default"

    public init(model: String = ChatSettings.defaultModel, effort: Effort = .high) {
        self.model = model
        self.effort = effort
        permissionMode = "manual"
        ultracode = false
        contextWindow = "auto"
        unknownKeys = [:]
    }

    static let knownKeys: Set<String> = ["model", "effort", "permissionMode", "ultracode", "contextWindow"]

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        model = try c.value("model", default: Self.defaultModel)
        try c.check("model", model, ChatSettings.isModel, "model")
        effort = try c.value("effort", default: .high)
        permissionMode = try c.value("permissionMode", default: "manual")
        ultracode = try c.value("ultracode", default: false)
        contextWindow = try c.value("contextWindow", default: "auto")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(model, "model")
        try c.encode(effort, "effort")
        try c.encode(permissionMode, "permissionMode")
        try c.encode(ultracode, "ultracode")
        try c.encode(contextWindow, "contextWindow")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// A model value: not empty, no white space.
    public static func isModel(_ value: String) -> Bool {
        !value.isEmpty && !value.contains { $0.isWhitespace }
    }
}

/// How hard Claude thinks, as the CLI's `--effort` takes it.
public enum Effort: String, Codable, Sendable, Hashable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// Chat ids: uppercase UUIDs.
public enum ChatIDs {
    /// A new id.
    public static func make() -> String { UUID().uuidString }

    /// True for an uppercase UUID, as chat ids are written.
    public static func isChatID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString == value
    }
}

/// A chat's permission mode, as V2's Permissions menu had them (docs/data.md › Chat settings): what the CLI asks
/// before, and what the app's tools may change without a card.
public enum ChatPermissionMode: String, Sendable, Hashable, CaseIterable {
    /// Ask Every Time: the default.
    case manual
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    /// The mode a chat's stored value names; Ask Every Time for an unknown one.
    public init(stored: String) {
        self = ChatPermissionMode(rawValue: stored) ?? .manual
    }

    /// What `set_permission_mode` and the CLI's `init` call it: `default` for Ask Every Time.
    public var cliValue: String { self == .manual ? "default" : rawValue }

    /// How the session start line names a mode the CLI reports, as V2's: a mode it doesn't know as reported.
    public static func systemLineLabel(_ cliMode: String) -> String {
        switch cliMode == "default" ? .manual : ChatPermissionMode(rawValue: cliMode) {
        case .manual?: "Ask every time"
        case .acceptEdits?: "Accept edits"
        case .plan?: "Plan only"
        case .auto?: "Auto"
        case .dontAsk?: "Don't ask"
        case .bypassPermissions?: "Allow all"
        case nil: cliMode
        }
    }
}

/// A chat's context window, as V2's Context menu had them: the model's own, or where the CLI compacts.
public enum ChatContextWindow: String, Sendable, Hashable, CaseIterable {
    case auto
    case window200K = "200k"
    case window1M = "1m"

    public init(stored: String) {
        self = ChatContextWindow(rawValue: stored) ?? .auto
    }

    /// `--autocompact`'s value; nil for Auto, which passes none.
    public var autocompact: String? {
        switch self {
        case .auto: nil
        case .window200K: "200000"
        case .window1M: "1000000"
        }
    }
}
