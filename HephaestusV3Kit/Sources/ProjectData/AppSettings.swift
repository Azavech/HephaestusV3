import FileStorage
import Foundation

/// `<data folder>/settings.yml`: the app's settings (docs/data.md › Settings file).
public struct SettingsFile: Codable, Sendable, Hashable {
    /// The MCP server's port when nothing else sets it.
    public static let defaultMCPPort = 47830

    public var schema: Int
    /// The port of the MCP server on 127.0.0.1, 1024–65535.
    public var mcpPort: Int
    /// The Claude CLI the chats run, as set in Settings ▸ Chat; nil finds it (docs/ui/chat.md › Claude CLI).
    public var claudePath: String?
    /// The model of new chats: `default`, or a value of the CLI's model list; nil for `default`.
    public var chatModel: String?
    /// The effort of new chats; nil for `high`.
    public var chatEffort: String?
    /// The cores, memory and disk new virtual machines start with; nil for 2 cores, 4 GB, 64 GB.
    public var defaultVMCores: Int?
    public var defaultVMMemoryGB: Int?
    public var defaultVMDiskGB: Int?
    /// How the windows the app opens appear: `tabs`, as tabs of the frontmost window, or `windows`, each on its
    /// own; nil, or another value, for `tabs` (Settings ▸ General).
    public var newWindows: String?
    /// The project that receives feedback tickets (Settings ▸ General); nil hides the status bar's ladybug
    /// and Help ▸ Send Feedback….
    public var feedbackProjectID: String?
    /// Settings ▸ Notifications, as V2's: a notification when a chat needs the user, when Claude finishes, and
    /// with an AI-generated summary; nil for on.
    public var notifyNeedsYou: Bool?
    public var notifyFinished: Bool?
    public var notifyAISummary: Bool?
    public var unknownKeys: YAMLMapping

    public init(schema: Int = 1, mcpPort: Int = SettingsFile.defaultMCPPort, claudePath: String? = nil, chatModel: String? = nil,
                chatEffort: String? = nil, unknownKeys: YAMLMapping = [:]) {
        self.schema = schema
        self.mcpPort = mcpPort
        self.claudePath = claudePath
        self.chatModel = chatModel
        self.chatEffort = chatEffort
        self.unknownKeys = unknownKeys
    }

    static let knownKeys: Set<String> = ["schema", "mcpPort", "claudePath", "chatModel", "chatEffort", "defaultVMCores", "defaultVMMemoryGB",
                                         "defaultVMDiskGB", "newWindows", "feedbackProjectID", "notifyNeedsYou", "notifyFinished", "notifyAISummary"]

    /// Whether the windows the app opens become tabs of the frontmost window: unless `newWindows` is `windows`.
    public var opensWindowsAsTabs: Bool {
        get { newWindows != "windows" }
        set { newWindows = newValue ? "tabs" : "windows" }
    }

    public init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        schema = try c.schema()
        mcpPort = try c.value("mcpPort", default: Self.defaultMCPPort)
        claudePath = try c.optional("claudePath")
        chatModel = try c.optional("chatModel")
        chatEffort = try c.optional("chatEffort")
        defaultVMCores = try c.optional("defaultVMCores")
        defaultVMMemoryGB = try c.optional("defaultVMMemoryGB")
        defaultVMDiskGB = try c.optional("defaultVMDiskGB")
        newWindows = try c.optional("newWindows")
        feedbackProjectID = try c.optional("feedbackProjectID")
        notifyNeedsYou = try c.optional("notifyNeedsYou")
        notifyFinished = try c.optional("notifyFinished")
        notifyAISummary = try c.optional("notifyAISummary")
        unknownKeys = try c.unknownKeys(known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(schema, "schema")
        try c.encode(mcpPort, "mcpPort")
        try c.encodeIfPresent(claudePath, "claudePath")
        try c.encodeIfPresent(chatModel, "chatModel")
        try c.encodeIfPresent(chatEffort, "chatEffort")
        try c.encodeIfPresent(defaultVMCores, "defaultVMCores")
        try c.encodeIfPresent(defaultVMMemoryGB, "defaultVMMemoryGB")
        try c.encodeIfPresent(defaultVMDiskGB, "defaultVMDiskGB")
        try c.encodeIfPresent(newWindows, "newWindows")
        try c.encodeIfPresent(feedbackProjectID, "feedbackProjectID")
        try c.encodeIfPresent(notifyNeedsYou, "notifyNeedsYou")
        try c.encodeIfPresent(notifyFinished, "notifyFinished")
        try c.encodeIfPresent(notifyAISummary, "notifyAISummary")
        try c.encodeUnknownKeys(unknownKeys, known: Self.knownKeys)
    }

    /// A port the MCP server may use: 1024–65535.
    public static func isPort(_ value: Int) -> Bool {
        (1024...65535).contains(value)
    }
}

extension DataFolder {
    /// `settings.yml`.
    public var settingsFile: URL { url.appendingPathComponent("settings.yml") }
    /// `secrets.json`, mode 0600: the MCP server's external token.
    public var secretsFile: URL { url.appendingPathComponent("secrets.json") }

    /// The settings: a missing file gives the defaults; an invalid one is set aside as `settings.yml.invalid`
    /// and gives the defaults.
    public func readSettings() -> SettingsFile {
        do {
            return try YAMLFile.read(SettingsFile.self, at: settingsFile)
        } catch {
            if case .invalidFile = error {
                let aside = invalidCopy(of: settingsFile)
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: settingsFile, to: aside)
            }
            return SettingsFile()
        }
    }

    public func writeSettings(_ settings: SettingsFile, ownWrites: OwnWrites? = nil) throws(StorageError) {
        try YAMLFile.write(settings, to: settingsFile, ownWrites: ownWrites)
    }

    /// The external token of `secrets.json`; when the file has none (or isn't a JSON object), `make()` gives
    /// one, which is written, the file's other keys kept.
    public func externalToken(make: () -> String) throws(StorageError) -> String {
        var object = readSecrets()
        if let token = object["mcpExternalToken"] as? String, token.count == 64,
           token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return token
        }
        let token = make()
        object["mcpExternalToken"] = token
        try writeSecrets(object)
        return token
    }

    /// Replaces the external token, the file's other keys kept.
    public func replaceExternalToken(with token: String) throws(StorageError) {
        var object = readSecrets()
        object["mcpExternalToken"] = token
        try writeSecrets(object)
    }

    private func readSecrets() -> [String: Any] {
        guard let data = try? Data(contentsOf: secretsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["schema": 1] }
        return object
    }

    private func writeSecrets(_ object: [String: Any]) throws(StorageError) {
        var object = object
        if object["schema"] == nil { object["schema"] = 1 }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw .writeFailed(path: secretsFile.path, reason: "cannot encode: \(error)")
        }
        do {
            try AtomicFile.write(data + Data("\n".utf8), to: secretsFile, newFileMode: AtomicFile.privateMode)
            chmod(secretsFile.path, AtomicFile.privateMode)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: secretsFile.path, reason: String(describing: error))
        }
    }
}
