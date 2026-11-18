import Foundation
import Testing
@testable import TextFormats

/// docs/text.md › Markers, Shortcut notation, Font notation, Animation expressions, System colors.
@Suite("Markers")
struct MarkdownMarkersTests {
    private let markers = MarkdownMarkerOptions(isSymbolAvailable: { $0 != "no.such.symbol" })

    private func inlines(_ markdown: String) -> [MarkdownInline] {
        guard case .paragraph(let inlines)? = MarkdownBlockRenderer.render(markdown, options: MarkdownRenderOptions(projectIdentifiers: ["ORD"], markers: markers)).first
        else { return [] }
        return inlines
    }

    @Test("Each kind of marker in Markdown, spaces included where CommonMark reads no image")
    func kinds() {
        #expect(inlines("Use ![](sf:star.fill) here") == [.text("Use "), .symbol("star.fill"), .text(" here")])
        #expect(inlines("![](color:#FF9500) or ![](color:systemBlue)") == [.color("#FF9500"), .text(" or "), .color("systemBlue")])
        #expect(inlines("Sound: ![](sound:iOS 26.1/sms-received1.caf)") == [.text("Sound: "), .sound("iOS 26.1/sms-received1.caf")])
        #expect(inlines("![](shortcut:⇧⌘K)") == [.shortcut("⇧⌘K", keyCaps: ["⇧", "⌘", "K"])])
        #expect(inlines(#"![](shortcut:⌘\()"#) == [.shortcut("⌘(", keyCaps: ["⌘", "("])])
        #expect(inlines("![](font:System Rounded/Semibold/17)") == [.font("System Rounded/Semibold/17", label: "System Rounded · Semibold · 17 pt")])
        #expect(inlines("![](font:.headline)") == [.font(".headline", label: ".headline")])
        #expect(inlines("![](animation:.spring(duration: 0.4, bounce: 0.2)) then ORD-12")
                == [.animation(".spring(duration: 0.4, bounce: 0.2)"), .text(" then "), .itemID("ORD-12", code: false)])
        #expect(inlines("![](animation:.snappy)") == [.animation(".snappy")])
    }

    @Test("A value that isn't accepted shows the marker's source as written")
    func refused() {
        #expect(inlines("![](sf:no.such.symbol)") == [.text("![](sf:no.such.symbol)")])
        #expect(inlines("![](color:#FF950080)") == [.text("![](color:#FF950080)")])
        #expect(inlines("![](shortcut:⌘⇧K)") == [.text("![](shortcut:⌘⇧K)")])
        #expect(inlines("![](font:Helvetica)") == [.text("![](font:Helvetica)")])
        #expect(inlines("![](animation:.wobbly)") == [.text("![](animation:.wobbly)")])
        #expect(inlines("![](font:Avenir Next/Bold/1000)") == [.text("![](font:Avenir Next/Bold/1000)")])
    }

    @Test("Markers stay text in code spans, code blocks and links; without the option they are images")
    func notRead() {
        #expect(inlines("`![](sf:star)`") == [.code("![](sf:star)")])
        #expect(inlines("[![](sf:star)](https://example.com)") == [.link(destination: "https://example.com", title: nil, content: [.text("![](sf:star)")])])
        guard case .codeBlock(_, _, let code, _)? = MarkdownBlockRenderer.render("```\n![](sf:star)\n```", options: MarkdownRenderOptions(markers: markers)).first
        else { Issue.record("No code block"); return }
        #expect(code == "![](sf:star)\n")
        guard case .paragraph(let plain)? = MarkdownBlockRenderer.render("![](sf:star)", options: MarkdownRenderOptions()).first else { return }
        #expect(plain == [.image(source: .blocked, alt: "", title: nil)])
    }

    @Test("Plain text: markers and ids, never ids inside a marker")
    func plainText() {
        let found = MarkdownMarkers.inlines(in: "See ORD-3: Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E) ![](sound:Project/ORD-4 (1).caf)",
                                            options: markers, projectIdentifiers: ["ORD"])
        #expect(found == [.text("See "), .itemID("ORD-3", code: false), .text(": Light "), .color("#FFFFFF"), .text(", Dark "), .color("#1C1C1E"),
                          .text(" "), .sound("Project/ORD-4 (1).caf")])
        #expect(MarkdownMarkers.inlines(in: "![x](sf:no.such.symbol)", options: markers) == [.text("![x](sf:no.such.symbol)")])
    }

    @Test("The linked ids of the transcript leave out those inside markers")
    func linkedIDs() {
        #expect(MarkdownItemIDs.linkedIDs(inMarkdown: "![](sound:Project/ORD-4 a.caf) and ORD-5") == ["ORD-5"])
    }
}

@Suite("Notations")
struct NotationTests {
    @Test("Shortcuts: modifiers in menu order, one key, key caps", arguments: [
        ("⇧⌘K", ["⇧", "⌘", "K"]), ("⌃⌥Space", ["⌃", "⌥", "Space"]), ("⎋", ["⎋"]), ("F5", ["F5"]), ("⌘,", ["⌘", ","]), ("⇧⌘/", ["⇧", "⌘", "/"]),
    ])
    func shortcuts(notation: String, caps: [String]) {
        #expect(KeyShortcut.keyCaps(of: notation) == caps)
    }

    @Test("Not shortcuts", arguments: ["⌘⇧K", "⌘k", "⌘", "⌘⌘K", "⌘KK", "F21", "⌘ "])
    func notShortcuts(text: String) {
        #expect(KeyShortcut(text) == nil)
    }

    @Test("Recorded keys, the standard shortcuts, the marker")
    func recording() {
        #expect(KeyShortcut.recordedKey(keyCode: 0x24, unmodifiedCharacters: "\r") == "↩")
        #expect(KeyShortcut.recordedKey(keyCode: 0x28, unmodifiedCharacters: "k") == "K")
        #expect(KeyShortcut.recordedKey(keyCode: 0x72, unmodifiedCharacters: "\u{F746}") == nil)
        #expect(KeyShortcut(modifiers: [.command, .shift], key: "K")?.notation == "⇧⌘K")
        #expect(StandardShortcuts.action(for: "⌘Space") == "Spotlight" && StandardShortcuts.action(for: "⇧⌘K") == nil)
        #expect(KeyShortcut("⌥⌘\\")?.marker == #"![](shortcut:⌥⌘\\)"#)
    }

    @Test("Fonts: text styles and families, sizes of 1 to 999 with one decimal")
    func fonts() {
        #expect(FontNotation(".headline") == .textStyle(.headline))
        #expect(FontNotation("Avenir Next/Demi Bold/15")?.label == "Avenir Next · Demi Bold · 15 pt")
        for size in ["17", "15.5", "17.0", "1", "999"] { #expect(FontNotation.isSize(size), "\(size)") }
        for size in ["0.5", "1000", "15.25", "15,5", "017", "", "0"] { #expect(!FontNotation.isSize(size), "\(size)") }
        #expect(FontNotation.parse(".bold") == .failure(.notation) && FontNotation.parse("A/B") == .failure(.notation))
        #expect(FontNotation.parse("A/B/0") == .failure(.size) && FontNotation.parse("/B/17") == .failure(.notation))
        #expect(FontNotation.sizeText(17) == "17" && FontNotation.sizeText(15.5) == "15.5" && FontNotation.sizeText(0.4) == nil)
    }

    @Test("Animations: presets, parameters in order, ranges, the Custom row's expression")
    func animations() throws {
        let spring = try AnimationExpression(parsing: ".spring( duration : 0.4 , bounce: -0.25 )")
        #expect(spring.preset == .spring && spring.values == [.duration: 0.4, .bounce: -0.25])
        #expect(try AnimationExpression(parsing: ".snappy").fullExpression == ".snappy(duration: 0.5, extraBounce: 0)")
        #expect(try AnimationExpression(parsing: ".easeInOut(duration: 0.25)").fullExpression == ".easeInOut(duration: 0.25)")
        #expect(throws: AnimationExpressionError.parameters(.easeIn)) { try AnimationExpression(parsing: ".easeIn(bounce: 0.1)") }
        #expect(throws: AnimationExpressionError.range(.duration)) { try AnimationExpression(parsing: ".linear(duration: 3)") }
        #expect(throws: AnimationExpressionError.syntax) { try AnimationExpression(parsing: ".spring(duration: 0.4)x") }
        #expect(AnimationExpression.message(for: .parameters(.smooth), suggestion: "x") == "x: .smooth takes (duration:extraBounce:).")
        #expect(AnimationExpression.message(for: .range(.extraBounce), suggestion: "x") == "x: extraBounce must be from 0 to 1.")
        #expect(AnimationExpression.format(0.30) == "0.3" && AnimationExpression.format(-0.001) == "0" && AnimationExpression.format(1) == "1")
    }

    @Test("Colors: hex colors in either case, system names with their case")
    func colors() {
        #expect(SystemColors.isColor("#ff9500") && SystemColors.isColor("systemBlue") && SystemColors.isColor("quinaryLabelColor"))
        #expect(!SystemColors.isColor("#FF95") && !SystemColors.isColor("SystemBlue") && !SystemColors.isColor("clearColor"))
        #expect(SystemColors.isSame("#ff9500", "#FF9500") && !SystemColors.isSame("red", "Red"))
        #expect(SystemColors.normalized("#ff9500") == "#FF9500" && SystemColors.names.count == 86)
        #expect(SystemColors.components(ofHex: "#FFFFFF99")?.alpha == 0.6)
    }
}
