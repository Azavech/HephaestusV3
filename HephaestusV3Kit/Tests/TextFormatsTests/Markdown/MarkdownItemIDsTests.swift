import Foundation
import Testing
@testable import TextFormats

/// docs/text.md › Ticket and bundle ids.
@Suite("Ticket and bundle ids")
struct MarkdownItemIDsTests {
    static let options = MarkdownRenderOptions(projectIdentifiers: ["HEPH"])

    static func blocks(_ markdown: String, _ options: MarkdownRenderOptions = options) -> [MarkdownBlock] {
        MarkdownBlockRenderer.render(markdown, options: options)
    }

    @Test("Ticket ids, bundle ids and code spans that are exactly an id become links")
    func links() {
        #expect(Self.blocks("HEPH-21, HEPH-B14 and `HEPH-21`.")
            == [.paragraph([.itemID("HEPH-21", code: false), .text(", "), .itemID("HEPH-B14", code: false), .text(" and "),
                            .itemID("HEPH-21", code: true), .text(".")])])
    }

    @Test("Other identifiers, code blocks and existing links do not link")
    func notLinks() {
        #expect(Self.blocks("ORD-21 and HEPHX-2") == [.paragraph([.text("ORD-21 and HEPHX-2")])])
        if case .codeBlock(_, _, let code, _)? = Self.blocks("```\nHEPH-21\n```").first {
            #expect(code == "HEPH-21\n")
        } else {
            Issue.record("not a code block")
        }
        #expect(Self.blocks("[HEPH-21](https://example.com)")
            == [.paragraph([.link(destination: "https://example.com", title: nil, content: [.text("HEPH-21")])])])
    }

    @Test("An id link's href holds the id")
    func href() {
        #expect(MarkdownItemIDs.id(fromHref: MarkdownItemIDs.href(for: "HEPH-21")) == "HEPH-21")
        #expect(MarkdownItemIDs.id(fromHref: "https://example.com") == nil)
    }
}
