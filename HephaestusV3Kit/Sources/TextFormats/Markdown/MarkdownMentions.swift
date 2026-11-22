import Foundation

/// Mentions of Claude in a comment's text (docs/ui/tickets.md › Mentioning Claude): `@Claude` in any letter case, as
/// a whole word. The renderer finds them in the text outside code and links, while `highlightsMentions` is on, and
/// the views draw them in the accent color; they are not links.
public enum MarkdownMentions {
    /// The text pieces of `inlines` split around the mentions, as `.text` and `.mention` inlines.
    static func inlines(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        inlines.flatMap { inline -> [MarkdownInline] in
            guard case .text(let text) = inline else { return [inline] }
            let ranges = ranges(in: text)
            guard !ranges.isEmpty else { return [inline] }
            var result: [MarkdownInline] = []
            var position = text.startIndex
            for range in ranges {
                if range.lowerBound > position { result.append(.text(String(text[position..<range.lowerBound]))) }
                result.append(.mention(String(text[range])))
                position = range.upperBound
            }
            if position < text.endIndex { result.append(.text(String(text[position...]))) }
            return result
        }
    }

    /// The ranges of `@Claude` as a whole word: the `@` begins the text or follows a character that isn't a letter,
    /// a digit or `_`, and `Claude` ends the text or is followed by such a character.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: "@claude", options: [.caseInsensitive], range: search) {
            search = range.upperBound..<text.endIndex
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            guard !isWordCharacter(before), !isWordCharacter(after) else { continue }
            found.append(range)
        }
        return found
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
