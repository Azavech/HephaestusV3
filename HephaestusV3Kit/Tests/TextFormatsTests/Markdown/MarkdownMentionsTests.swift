import Foundation
import Testing
@testable import TextFormats

/// docs/ui/tickets.md › Mentioning Claude: a comment draws its mentions of Claude in the accent color.
@Suite("Mentions of Claude")
struct MarkdownMentionsTests {
    static let options = MarkdownRenderOptions(projectIdentifiers: ["HEPH"], highlightsMentions: true)

    @Test("A comment's mentions, as whole words, beside ids; not in code or links")
    func mentions() {
        #expect(MarkdownBlockRenderer.render("Hi @claude, see HEPH-2 (@CLAUDE)", options: Self.options)
            == [.paragraph([.text("Hi "), .mention("@claude"), .text(", see "), .itemID("HEPH-2", code: false), .text(" ("),
                            .mention("@CLAUDE"), .text(")")])])
        #expect(MarkdownBlockRenderer.render("@Claudette, name@Claude and `@Claude`", options: Self.options)
            == [.paragraph([.text("@Claudette, name@Claude and "), .code("@Claude")])])
        #expect(MarkdownBlockRenderer.render("[@Claude](https://example.com)", options: Self.options)
            == [.paragraph([.link(destination: "https://example.com", title: nil, content: [.text("@Claude")])])])
    }

    @Test("Without the option, a mention is text")
    func off() {
        #expect(MarkdownBlockRenderer.render("Hi @Claude", options: MarkdownRenderOptions())
            == [.paragraph([.text("Hi @Claude")])])
    }
}
