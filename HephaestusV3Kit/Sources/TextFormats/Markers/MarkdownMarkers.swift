import Foundation
import Markdown

/// What the renderers need to read Markdown markers (docs/text.md › Markers): V2's six kinds, `![](sf:…)`,
/// `![](color:…)`, `![](sound:…)`, `![](shortcut:…)`, `![](font:…)` and `![](animation:…)`. The views that draw
/// them set it; without it, such an image is refused as any other.
public struct MarkdownMarkerOptions: Sendable {
    /// Whether the Mac that draws the text has an SF Symbol of this name; an unavailable one shows its source.
    public var isSymbolAvailable: @Sendable (String) -> Bool

    public init(isSymbolAvailable: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.isSymbolAvailable = isSymbolAvailable
    }
}

/// The markers of Markdown and of plain text (docs/text.md › Markers), as V2's `MarkdownSymbolMarkers`. The
/// renderer reads them in Markdown; `inlines(in:options:projectIdentifiers:)` reads them in plain text, such as
/// a suggestion's line or an answer of the chat's cards.
public enum MarkdownMarkers {
    /// The kinds, by their scheme.
    public enum Kind: String, Sendable, CaseIterable {
        case symbol = "sf"
        case color
        case sound
        case shortcut
        case font
        case animation
    }

    /// The inline of a marker of `kind` whose value is `value`; nil when its value isn't accepted, so that the
    /// marker shows its source: an unavailable symbol, a color that is neither a hex color nor a system color
    /// name, a shortcut, a font or an animation that breaks its notation. A sound's name is never checked.
    static func inline(_ kind: Kind, value: String, options: MarkdownMarkerOptions) -> MarkdownInline? {
        guard !value.isEmpty else { return nil }
        switch kind {
        case .symbol:
            return options.isSymbolAvailable(value) ? .symbol(value) : nil
        case .color:
            return SystemColors.isColor(value) ? .color(value) : nil
        case .sound:
            return .sound(value)
        case .shortcut:
            return KeyShortcut.keyCaps(of: value).map { .shortcut(value, keyCaps: $0) }
        case .font:
            return FontNotation(value).map { .font(value, label: $0.label) }
        case .animation:
            return AnimationExpression.isValid(value) ? .animation(value) : nil
        }
    }

    /// The kind and value of an image source with a marker's scheme, the value being the source after the first
    /// `:`; nil for another source.
    static func marker(ofSource source: String) -> (kind: Kind, value: String)? {
        guard let colon = source.firstIndex(of: ":"),
              let kind = Kind(rawValue: source[..<colon].lowercased()) else { return nil }
        // `sound:` names may start with anything; the others follow `MarkdownLinks.scheme`.
        if kind != .sound, MarkdownLinks.scheme(of: source) != kind.rawValue { return nil }
        return (kind, String(source[source.index(after: colon)...]))
    }

    /// The plain text as `.text`, marker and `.itemID` inlines: each marker its kind's inline, or its source as
    /// text when its value isn't accepted; the text outside markers gets the ids of `projectIdentifiers`, never
    /// the text of a marker.
    public static func inlines(in text: String, options: MarkdownMarkerOptions, projectIdentifiers: Set<String> = []) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        func append(_ inline: MarkdownInline) {
            if case .text(let added) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + added)
            } else {
                result.append(inline)
            }
        }
        for piece in pieces(in: text, kinds: Set(Kind.allCases)) {
            switch piece {
            case .text(let text):
                MarkdownItemIDs.inlines(in: text, projectIdentifiers: projectIdentifiers).forEach(append)
            case .marker(let kind, let value, let source):
                append(inline(kind, value: value, options: options) ?? .text(source))
            }
        }
        return result
    }

    /// A piece of a text split at its plain-text markers.
    enum Piece: Equatable {
        case text(String)
        /// A marker: its kind, its value and its source as written.
        case marker(Kind, value: String, source: String)
    }

    /// A text split at its plain-text markers of `kinds`.
    static func pieces(in text: String, kinds: Set<Kind>) -> [Piece] {
        var pieces: [Piece] = []
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "!", let found = marker(in: text, at: index, kinds: kinds) {
                if !pending.isEmpty { pieces.append(.text(pending)) }
                pending = ""
                pieces.append(.marker(found.kind, value: found.value, source: String(text[index..<found.end])))
                index = found.end
            } else {
                pending.append(text[index])
                index = text.index(after: index)
            }
        }
        if !pending.isEmpty { pieces.append(.text(pending)) }
        return pieces
    }

    /// A plain-text marker starting at `start`: `![`, an alt text without `[`, `]` or line break, `](`, the
    /// kind's scheme and `:` in any letter case, its value, and `)`. The value of `sf`, `color` and `shortcut` is
    /// one or more characters other than `(`, `)` and white space, in a shortcut `\` followed by a character
    /// standing for that character; of `font`, one or more characters other than `(`, `)` and line breaks; of
    /// `sound` and `animation`, characters without line break up to the first `)` that closes no `(` of the
    /// value, at least one for a sound.
    private static func marker(in text: String, at start: String.Index, kinds: Set<Kind>) -> (kind: Kind, value: String, end: String.Index)? {
        var index = start
        func take(_ expected: String, ignoringCase: Bool = false) -> Bool {
            var cursor = index
            for character in expected {
                guard cursor < text.endIndex else { return false }
                let matches = ignoringCase ? text[cursor].lowercased() == String(character) : text[cursor] == character
                guard matches else { return false }
                cursor = text.index(after: cursor)
            }
            index = cursor
            return true
        }
        guard take("![") else { return nil }
        while index < text.endIndex, text[index] != "]" {
            let character = text[index]
            if character == "[" || character.isNewline { return nil }
            index = text.index(after: index)
        }
        guard take("](") else { return nil }
        guard let kind = Kind.allCases.first(where: { kinds.contains($0) && take($0.rawValue + ":", ignoringCase: true) }) else { return nil }
        let valueStart = index
        switch kind {
        case .sound, .animation:
            var depth = 0
            while index < text.endIndex {
                let character = text[index]
                if character.isNewline { return nil }
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                index = text.index(after: index)
            }
            guard index < text.endIndex, kind == .animation || index > valueStart else { return nil }
            return (kind, String(text[valueStart..<index]), text.index(after: index))
        case .font:
            while index < text.endIndex, text[index] != ")" {
                let character = text[index]
                if character == "(" || character.isNewline { return nil }
                index = text.index(after: index)
            }
            guard index > valueStart, index < text.endIndex else { return nil }
            return (kind, String(text[valueStart..<index]), text.index(after: index))
        case .symbol, .color, .shortcut:
            var value = ""
            while index < text.endIndex, text[index] != ")" {
                var character = text[index]
                if character == "(" || character.isWhitespace { return nil }
                if kind == .shortcut, character == "\\" {
                    index = text.index(after: index)
                    guard index < text.endIndex, !text[index].isWhitespace else { return nil }
                    character = text[index]
                }
                value.append(character)
                index = text.index(after: index)
            }
            guard !value.isEmpty, index < text.endIndex else { return nil }
            return (kind, value, text.index(after: index))
        }
    }
}

/// The UTF-8 bytes of a parsed text and the offset of each line, to read a node's source from its range: lines
/// and columns count from 1, columns in UTF-8 bytes, the upper bound excluded.
struct MarkdownSourceLines {
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    /// The source text of a range; nil when the range falls outside the text.
    func text(in range: SourceRange) -> String? {
        guard let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end,
              end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1 else { return nil }
        return lineStarts[location.line - 1] + location.column - 1
    }
}
