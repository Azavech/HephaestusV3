import ChatData
import FileStorage
import Foundation
import MCPKit
import ProjectData
import Testing
import TextFormats
@testable import ChatKit

/// docs/ui/chat.md › Picker cards: what each card answers, and when Submit is enabled.
@Suite("Picker cards")
@MainActor
struct PickerCardTests {
    private let date = ISODate.date(from: "2026-11-14T10:00:00Z")!

    @Test("Symbol and sound: the marker of the chosen value, else the field's text")
    func symbolAndSound() {
        let request = PickerItem.preview(.symbol)
        #expect(SymbolCard.answer(request: request, choice: "star", other: "") == "![](sf:star)")
        #expect(SymbolCard.answer(request: request, choice: nil, other: " a gear \n") == "a gear")
        #expect(!SymbolCard.canSubmit(choice: nil, other: "  ") && SymbolCard.canSubmit(choice: "star", other: ""))
        #expect(SymbolCard.answer(request: .preview(.sound), choice: "macOS/Glass.aiff", other: "") == "![](sound:macOS/Glass.aiff)")
    }

    @Test("Color: one color or a pair, hex in uppercase; the toggle and the clicks")
    func color() {
        var request = PickerItem.preview(.color)
        var choice = ColorChoice(request: request)
        #expect(choice.isPair && choice.light == "#FFFFFF" && choice.dark == "#1C1C1E")
        #expect(choice.answer(other: "") == "Light ![](color:#FFFFFF), Dark ![](color:#1C1C1E)")
        #expect(choice.isHighlighted(request.suggestions[0]) && !choice.isHighlighted(request.suggestions[1]))
        choice.row = .dark
        choice.choose(PickerSuggestion("systemBlue"))
        #expect(choice.dark == "systemBlue" && choice.isHighlighted(PickerSuggestion("systemBlue")))
        choice.setPair(false)
        #expect(choice.single == "#FFFFFF" && choice.answer(other: "") == "![](color:#FFFFFF)")
        choice.choose(request.suggestions[1])
        #expect(choice.single == "systemBackground", "A pair gives its light color while the toggle is off")
        choice.single = "#ff9500"
        #expect(choice.answer(other: "") == "![](color:#FF9500)")
        choice.single = "#ff95"
        #expect(!choice.canSubmit(other: ""), "A field that holds no color")
        choice.setPair(true)
        #expect(choice.light == "#ff95" && choice.dark == "#ff95" && choice.row == .light)
        choice.choosesOther = true
        #expect(choice.answer(other: " mine ") == "mine" && !choice.isHighlighted(request.suggestions[0]))

        request.lightAndDark = false
        request.recommended = PickerSuggestion("systemBlue")
        let single = ColorChoice(request: request)
        #expect(!single.isPair && single.single == "systemBlue")
    }

    @Test("Shortcut: the chosen or recorded shortcut, its warnings")
    func shortcut() {
        let inUse = [ShortcutInUse(shortcut: "⌘L", command: "Copy Link")]
        #expect(ShortcutCard.warnings(for: "⌘Space", inUse: inUse) == ["Used by macOS: Spotlight"])
        #expect(ShortcutCard.warnings(for: "⌘L", inUse: inUse) == ["Used by the app: Copy Link"])
        #expect(ShortcutCard.warnings(for: "⌘W", inUse: [ShortcutInUse(shortcut: "⌘W", command: "Close Tab")])
                == ["Used by macOS: Close Window", "Used by the app: Close Tab"])
        #expect(ShortcutCard.warnings(for: nil, inUse: inUse).isEmpty)
        #expect(ShortcutCard.answer(choice: .suggestion("⇧⌘F"), recorded: nil, other: "") == "![](shortcut:⇧⌘F)")
        #expect(ShortcutCard.answer(choice: .recorder, recorded: KeyShortcut("⌥⌘("), other: "") == #"![](shortcut:⌥⌘\()"#)
        #expect(!ShortcutCard.canSubmit(choice: .recorder, recorded: nil, other: "") && ShortcutCard.canSubmit(choice: .suggestion("⌘K"), recorded: nil, other: ""))
    }

    @Test("Font: the family with the menu's weight and the field's size, a text style's notation")
    func font() {
        let suggestions = ["System Rounded/Semibold/17", ".headline"]
        #expect(FontCard.answer(choice: .suggestion(0), suggestions: suggestions, weight: "Bold", size: "15.0", other: "") == "![](font:System Rounded/Bold/15)")
        #expect(FontCard.answer(choice: .suggestion(1), suggestions: suggestions, weight: "Bold", size: "x", other: "") == "![](font:.headline)")
        #expect(FontCard.answer(choice: .family("Avenir Next"), suggestions: suggestions, weight: "Demi Bold", size: "15.5", other: "") == "![](font:Avenir Next/Demi Bold/15.5)")
        #expect(FontCard.answer(choice: .textStyle(.caption2), suggestions: suggestions, weight: "", size: "", other: "") == "![](font:.caption2)")
        #expect(!FontCard.canSubmit(choice: .suggestion(0), suggestions: suggestions, size: "0.5", other: ""))
        #expect(FontCard.canSubmit(choice: .suggestion(1), suggestions: suggestions, size: "0.5", other: ""))
    }

    @Test("Animation: a suggestion as written, or the Custom row's whole expression")
    func animation() throws {
        let suggestions = [".snappy", ".spring(duration: 0.4, bounce: 0.2)"]
        var custom = AnimationCard.customStart(".spring(duration: 0.4)")
        #expect(custom.fullExpression == ".spring(duration: 0.4, bounce: 0)")
        custom.preset = .easeInOut
        #expect(AnimationCard.answer(choice: .custom, suggestions: suggestions, custom: custom, other: "") == "![](animation:.easeInOut(duration: 0.4))")
        #expect(AnimationCard.answer(choice: .suggestion(1), suggestions: suggestions, custom: custom, other: "") == "![](animation:.spring(duration: 0.4, bounce: 0.2))")
        #expect(AnimationCard.valueText(0.5, parameter: .duration) == "0.50 s" && AnimationCard.valueText(-1, parameter: .bounce) == "-1.00")
        #expect(!AnimationCard.canSubmit(choice: .other, other: " "))
    }

    @Test("A request is a block of Claude's turn; the waiting one is the conversation's")
    func turns() {
        let session = ChatSession(projects: ProjectSession(dataFolder: nil), tokens: MCPTokens(), device: "Studio")
        let store = LiveChatStore(session: session) { _, _ in nil }
        var request = PickerItem.preview(.font)
        request.answer = "Skipped"
        let turns = store.turns([.user(UserItem(id: "U", created: date, text: "Fonts?", sender: "Studio")), .picker(request)], streaming: nil)
        #expect(turns.map(\.author) == [.user, .claude])
        guard case .picker(let shown)? = turns.last?.blocks.first?.content else { Issue.record("No request"); return }
        #expect(shown == request)
        let block = ChatBlock(id: "P", .picker(request))
        #expect(ChatFind.texts(of: block).contains("![](font:.headline)") && ChatFind.texts(of: block).contains("Skipped"))
    }

    @Test("The samples answer: the request leaves, its answer goes as the user's message")
    func sampleAnswer() async throws {
        var conversation = ChatConversation(id: "C", projectID: "ORD", title: "Icons", origin: nil, createdAt: date,
                                            turns: [ChatTurn(id: "T", author: .claude, date: date, blocks: [ChatBlock(id: "B", .picker(.preview(.symbol)))])])
        conversation.waitingPicker = .preview(.symbol)
        let store = SampleChatStore(conversations: [conversation])
        try await store.answerPicker("![](sf:star)", request: "preview.symbol", of: "C")
        let answered = try #require(store.conversation("C"))
        #expect(answered.waitingPicker == nil)
        guard case .picker(let shown)? = answered.turns.first?.blocks.first?.content else { Issue.record("No request"); return }
        #expect(shown.answer == "![](sf:star)")
        guard case .text(let message)? = answered.turns.last?.blocks.first?.content else { Issue.record("No message"); return }
        #expect(message == "Symbol: ![](sf:star)")
    }
}
