import Foundation

/// A keyboard shortcut written as macOS menus write it (docs/text.md › Shortcut notation), as V2's `KeyShortcut`:
/// its modifiers ⌃ ⌥ ⇧ ⌘, each at most once and in this order, then one key, such as `⇧⌘K`. The chats check the
/// suggestions of `ask_shortcut` with it; the shortcut card and the shortcut markers draw its key caps.
public struct KeyShortcut: Sendable, Hashable {
    /// The modifiers in the order of the notation.
    public enum Modifier: String, Sendable, CaseIterable, Comparable {
        case control = "⌃"
        case option = "⌥"
        case shift = "⇧"
        case command = "⌘"

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    /// The modifiers, in the order of the notation.
    public let modifiers: [Modifier]
    /// The key: a character key, `Space` or `F1` to `F20`.
    public let key: String

    /// The keys written with a word.
    public static let space = "Space"
    public static let functionKeys = (1...20).map { "F\($0)" }

    /// Reads a notation; nil for any other text.
    public init?(_ notation: String) {
        var modifiers: [Modifier] = []
        var rest = Substring(notation)
        while let first = rest.first, let modifier = Modifier(rawValue: String(first)) {
            guard modifiers.last.map({ $0 < modifier }) ?? true else { return nil }
            modifiers.append(modifier)
            rest = rest.dropFirst()
        }
        self.init(modifiers: modifiers, key: String(rest))
    }

    /// The shortcut of `key` with `modifiers`, put in the order of the notation; nil when the notation can't
    /// write the key.
    public init?<Modifiers: Sequence>(modifiers: Modifiers, key: String) where Modifiers.Element == Modifier {
        guard Self.isKey(key) else { return nil }
        self.modifiers = Array(Set(modifiers)).sorted()
        self.key = key
    }

    /// The notation: the modifiers, then the key.
    public var notation: String {
        modifiers.map(\.rawValue).joined() + key
    }

    /// One key cap per modifier and one for the key, in the order written.
    public var keyCaps: [String] {
        modifiers.map(\.rawValue) + [key]
    }

    /// The card's answer: `![](shortcut:<shortcut>)`, a key `(`, `)` or `\` written with a `\` before it.
    public var marker: String {
        let key = ["(", ")", "\\"].contains(self.key) ? "\\" + self.key : self.key
        return "![](shortcut:" + modifiers.map(\.rawValue).joined() + key + ")"
    }

    /// The key caps of a notation; nil for any other text.
    public static func keyCaps(of notation: String) -> [String]? {
        KeyShortcut(notation)?.keyCaps
    }

    /// `Space`, `F1` to `F20`, or one character that isn't white space, a control or private-use character or a
    /// modifier glyph, and that stays the same in uppercase.
    public static func isKey(_ key: String) -> Bool {
        if key == space || functionKeys.contains(key) { return true }
        guard key.count == 1, let character = key.first else { return false }
        if character.isWhitespace || Modifier(rawValue: key) != nil { return false }
        let control = character.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .privateUse
        }
        return !control && key.uppercased() == key
    }

    /// The keys macOS gives no character for, by virtual key code.
    public static let namedKeys: [UInt16: String] = [
        0x24: "↩", 0x4C: "⌤", 0x35: "⎋", 0x30: "⇥", 0x31: space, 0x33: "⌫", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    /// Key codes whose key the notation can't write, whatever character they give: Help and the keypad Clear key.
    static let unwritableKeyCodes: Set<UInt16> = [0x72, 0x47]

    /// The key of a key press (docs/ui/chat.md › Shortcut card): the named key of its key code, or the character it
    /// types without any modifier, a letter in uppercase; nil when the notation can't write it.
    public static func recordedKey(keyCode: UInt16, unmodifiedCharacters: String?) -> String? {
        if let named = namedKeys[keyCode] { return named }
        guard !unwritableKeyCodes.contains(keyCode), let characters = unmodifiedCharacters else { return nil }
        let key = characters.uppercased()
        return isKey(key) ? key : nil
    }
}

/// The standard macOS shortcuts and their actions (docs/text.md › Standard macOS shortcuts), from Apple's article
/// "Mac keyboard shortcuts", as V2 listed them. The shortcut card warns when the selected shortcut is one of them.
public enum StandardShortcuts {
    public struct Entry: Sendable, Hashable {
        public let shortcut: String
        public let action: String
    }

    /// Every shortcut of the list, in the order of the docs table.
    public static let entries: [Entry] = [
        ("⌘X", "Cut"), ("⌘C", "Copy"), ("⌘V", "Paste"), ("⌘Z", "Undo"), ("⇧⌘Z", "Redo"), ("⌘A", "Select All"),
        ("⌘F", "Find"), ("⌘G", "Find Again"), ("⇧⌘G", "Find Previous"), ("⌘H", "Hide"), ("⌥⌘H", "Hide Others"),
        ("⌘M", "Minimize"), ("⌥⌘M", "Minimize All"), ("⌘O", "Open"), ("⌘P", "Print"), ("⌘Q", "Quit"), ("⌘S", "Save"),
        ("⌘T", "New Tab"), ("⌘W", "Close Window"), ("⌥⌘W", "Close All Windows"), ("⌥⌘⎋", "Force Quit"),
        ("⌘Space", "Spotlight"), ("⌥⌘Space", "Spotlight in Finder"), ("⌃⌘Space", "Character Viewer"),
        ("⌃⌘F", "Full Screen"), ("Space", "Quick Look"), ("⌘⇥", "Switch Apps"), ("⌘`", "Switch Windows"),
        ("⇧⌘3", "Screenshot"), ("⇧⌘4", "Screenshot"), ("⇧⌘5", "Screenshot or Recording"), ("⇧⌘N", "New Folder"),
        ("⌃⌘N", "New Folder with Selection"), ("⌘,", "Settings"),
        ("⌃⌘Q", "Lock Screen"), ("⇧⌘Q", "Log Out"), ("⌥⇧⌘Q", "Log Out Immediately"),
        ("⌥⌘D", "Show or Hide Dock"), ("⌃↑", "Mission Control"), ("⌃↓", "Application Windows"),
        ("⇧⌘6", "Ask Siri About Selection"), ("⇧⌘Space", "Ask Siri About Window"), ("⌃Space", "Previous Input Source"),
        ("⌃⌥Space", "Next Input Source"),
        ("⌃⌥⌘8", "Invert Colors"), ("⌃⌥⌘,", "Reduce Contrast"), ("⌃⌥⌘.", "Increase Contrast"), ("⌃F2", "Focus Menu Bar"),
        ("⌃F3", "Focus Dock"), ("⌃F4", "Focus Window"), ("⌃F5", "Focus Toolbar"), ("⌃F6", "Focus Floating Window"),
        ("⌃⇧F6", "Focus Previous Panel"), ("⌃F7", "Tab Focus Mode"), ("⌃F8", "Focus Status Menu"),
        ("⇧⌘`", "Previous Window"), ("⌥⌘`", "Focus Window Drawer"), ("⇥", "Next Control"), ("⇧⇥", "Previous Control"),
        ("⌃⇥", "Next Control"), ("⌃⇧⇥", "Previous Control Group"), ("←", "Move to Adjacent Item"),
        ("→", "Move to Adjacent Item"), ("↑", "Move to Adjacent Item"), ("↓", "Move to Adjacent Item"),
        ("⌃←", "Move to Adjacent Control"), ("⌃→", "Move to Adjacent Control"), ("⌥⌘F5", "Accessibility Shortcuts"),
    ].map { Entry(shortcut: $0.0, action: $0.1) }

    private static let actions: [String: String] = Dictionary(entries.map { ($0.shortcut, $0.action) }) { first, _ in first }

    /// The action of a standard macOS shortcut; nil for any other shortcut.
    public static func action(for shortcut: String) -> String? {
        actions[shortcut]
    }
}
