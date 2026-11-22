import Foundation

/// Whether a comment mentions Claude (docs/ui/tickets.md › Mentioning Claude), as V2's rule: `@Claude` in any letter
/// case, as a whole word, outside code spans and code blocks. Whole word: the `@` begins the text or follows a
/// character that isn't a letter, a digit or `_`, and `Claude` ends the text or is followed by such a character.
public enum CommentMentions {
    public static func mentionsClaude(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    /// The ranges of the mentions, for drawing them.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        let code = codeRanges(in: text)
        var found: [Range<String.Index>] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: "@claude", options: [.caseInsensitive], range: search) {
            search = range.upperBound..<text.endIndex
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            guard !isWordCharacter(before), !isWordCharacter(after) else { continue }
            guard !code.contains(where: { $0.overlaps(range) }) else { continue }
            found.append(range)
        }
        return found
    }

    /// The mention being typed at the insertion point `offset` (UTF-16), for the composer's completion: the range of
    /// an `@` at the start of a word and the letters after it, up to the insertion point, while they begin `Claude` in
    /// any letter case and the word ends there. Nil otherwise.
    public static func completion(in text: String, at offset: Int) -> Range<Int>? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        let cursor = String.Index(utf16Offset: offset, in: text)
        if cursor < text.endIndex, isWordCharacter(text[cursor]) { return nil }
        var start = cursor
        var letters = 0
        while start > text.startIndex, letters <= 6 {
            let previous = text.index(before: start)
            let character = text[previous]
            if character == "@" {
                let before = previous == text.startIndex ? nil : text[text.index(before: previous)]
                guard !isWordCharacter(before), "claude".hasPrefix(text[start..<cursor].lowercased()) else { return nil }
                return previous.utf16Offset(in: text)..<offset
            }
            guard character.isLetter else { return nil }
            letters += 1
            start = previous
        }
        return nil
    }

    /// `text` with the mention being typed in `range` (UTF-16) completed as `@Claude `, and the insertion point after it.
    public static func complete(_ text: String, range: Range<Int>) -> (text: String, insertionPoint: Int) {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return (text, range.upperBound) }
        let lower = String.Index(utf16Offset: range.lowerBound, in: text)
        let upper = String.Index(utf16Offset: range.upperBound, in: text)
        let completed = text.replacingCharacters(in: lower..<upper, with: "@Claude ")
        return (completed, range.lowerBound + 8)
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// CommonMark's code: fenced blocks, indented blocks, and spans between two backtick runs of the same length.
    static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var lineStart = text.startIndex
        var fence: String?
        var fenceStart = text.startIndex
        var previousBlank = true
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) {
                    ranges.append(fenceStart..<lineEnd)
                    fence = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                fenceStart = lineStart
            } else if previousBlank, line.hasPrefix("    ") || line.hasPrefix("\t") {
                ranges.append(lineStart..<lineEnd)
            }
            previousBlank = fence == nil && line.trimmingCharacters(in: .whitespaces).isEmpty
                || (ranges.last?.upperBound == lineEnd && (line.hasPrefix("    ") || line.hasPrefix("\t")))
            lineStart = lineEnd == text.endIndex ? lineEnd : text.index(after: lineEnd)
        }
        if fence != nil { ranges.append(fenceStart..<text.endIndex) }
        // Spans: a run of backticks, then the next run of the same length.
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`", !ranges.contains(where: { $0.contains(index) }) else {
                index = text.index(after: index)
                continue
            }
            var runEnd = index
            while runEnd < text.endIndex, text[runEnd] == "`" { runEnd = text.index(after: runEnd) }
            let run = text[index..<runEnd]
            var close = runEnd
            var matched: Range<String.Index>?
            while let found = text.range(of: run, range: close..<text.endIndex) {
                let after = found.upperBound
                if after == text.endIndex || text[after] != "`", found.lowerBound == text.startIndex || text[text.index(before: found.lowerBound)] != "`" {
                    matched = index..<found.upperBound
                    break
                }
                close = found.upperBound
            }
            if let matched {
                ranges.append(matched)
                index = matched.upperBound
            } else {
                index = runEnd
            }
        }
        return ranges
    }
}
