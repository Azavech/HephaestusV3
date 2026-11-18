import ExternalTools
import FileStorage
import Foundation
import MCPKit
import Testing
import TextFormats
@testable import ChatData

extension PickerCatalogs.Sources {
    /// Catalogues of a temporary folder, never the Mac's: the symbols `star`, `star.fill`, `filter` (keyword
    /// `funnel`), `character.book.closed.ja` and `future.symbol` (macOS 99); the sounds `Glass.aiff` and `Ping.aiff`;
    /// a runtime `iOS 26.1` with `sms-received1.caf` and `New/Anticipate.caf`; the family `Avenir Next` with
    /// `Regular`, `Italic`, `Demi Bold` and `Bold`.
    static func fixtures(in folder: URL) throws -> PickerCatalogs.Sources {
        let symbols = folder.appendingPathComponent("Symbols")
        let sounds = folder.appendingPathComponent("Sounds")
        let runtime = folder.appendingPathComponent("Runtime")
        let uiSounds = runtime.appendingPathComponent(SoundCatalog.runtimeSoundsFolder)
        for path in [symbols, sounds, uiSounds.appendingPathComponent("New")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let availability: [String: Any] = [
            "symbols": ["star": "2019", "star.fill": "2019", "filter": "2020", "character.book.closed.ja": "2020", "future.symbol": "2099"],
            "year_to_release": ["2019": ["macOS": "11.0"], "2020": ["macOS": "12.0"], "2099": ["macOS": "99.0"]],
        ]
        try PropertyListSerialization.data(fromPropertyList: availability, format: .xml, options: 0)
            .write(to: symbols.appendingPathComponent("name_availability.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["filter": ["funnel", "sort"]], format: .xml, options: 0)
            .write(to: symbols.appendingPathComponent("symbol_search.plist"))
        for file in [sounds.appendingPathComponent("Glass.aiff"), sounds.appendingPathComponent("Ping.aiff"), sounds.appendingPathComponent(".hidden.aiff"),
                     uiSounds.appendingPathComponent("sms-received1.caf"), uiSounds.appendingPathComponent("New/Anticipate.caf")] {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let avenir = FontFamily(name: "Avenir Next", faces: [
            FontFace(name: "Regular", weight: 0, italic: false, postScriptName: "AvenirNext-Regular"),
            FontFace(name: "Italic", weight: 0, italic: true, postScriptName: "AvenirNext-Italic"),
            FontFace(name: "Demi Bold", weight: 0.3, italic: false, postScriptName: "AvenirNext-DemiBold"),
            FontFace(name: "Bold", weight: 0.4, italic: false, postScriptName: "AvenirNext-Bold"),
        ])
        return PickerCatalogs.Sources(symbolsFolder: symbols, macOSVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0),
                                      soundsFolder: sounds, runtimes: { ([SoundCatalog.Runtime(name: "iOS 26.1", root: runtime)], []) },
                                      installedFonts: { [avenir] })
    }
}

/// docs/data.md › Picker requests: each kind's rules and messages, the items V2 wrote, the catalogues.
@Suite("Picker requests")
struct PickerRuleTests {
    private static let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func catalogs() async throws -> (PickerCatalogSnapshot, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PickerTests-\(UUID().uuidString)")
        let catalogs = PickerCatalogs(sources: try .fixtures(in: folder))
        let project = folder.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sounds"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: project.appendingPathComponent("Sounds/alert.caf").path, contents: Data())
        let files = ProjectFiles(git: nil)
        return (PickerCatalogSnapshot(symbols: await catalogs.symbols(), sounds: await catalogs.sounds(project: project, files: files),
                                      fonts: await catalogs.fonts(project: project, files: files)), folder)
    }

    private func refusal(_ kind: PickerKind, _ input: JSONValue) async throws -> String? {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        do throws(ToolError) {
            _ = try PickerItem.request(kind, from: input, catalogs: snapshot, created: Self.created)
            return nil
        } catch {
            #expect(error.code == .invalid)
            return error.message
        }
    }

    @Test("Symbols: each rule refuses with its message, in order", arguments: [
        (["question": " ", "suggestions": ["star", "filter"], "recommended": "star"], "ask_symbol needs a question."),
        (["question": "Icon?", "suggestions": ["star"], "recommended": "star"], "ask_symbol needs 2 to 10 suggestions."),
        (["question": "Icon?", "suggestions": ["star", " star "], "recommended": "star"], "ask_symbol has an empty or repeated suggestion."),
        (["question": "Icon?", "suggestions": ["star", "future.symbol"], "recommended": "star"], "future.symbol is not an SF Symbol of this Mac."),
        (["question": "Icon?", "suggestions": ["star", "filter"], "recommended": "star.fill"], "ask_symbol: the recommended symbol must be one of the suggestions."),
    ] as [(JSONValue, String)])
    func symbolRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.symbol, input) == message)
    }

    @Test("A localized variant is a symbol Claude may suggest; values are trimmed and kept in Claude's order")
    func symbolRequest() async throws {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try PickerItem.request(.symbol, from: ["question": " Icon? ", "suggestions": ["filter ", "character.book.closed.ja"], "recommended": "filter"],
                                          catalogs: snapshot, created: Self.created)
        #expect(item.question == "Icon?" && item.suggestions.map(\.value) == ["filter", "character.book.closed.ja"] && item.recommended.value == "filter")
        #expect(item.requestID == item.id && item.answer == nil)
    }

    @Test("Colors: one color, or pairs with lightAndDark; hex or system names; distinct; recommended", arguments: [
        (["question": "Color?", "suggestions": ["#FF9500", ["light": "#FFFFFF", "dark": "#000000"]], "recommended": "#FF9500"],
         "ask_color needs one color per suggestion, or lightAndDark for light and dark pairs."),
        (["question": "Color?", "lightAndDark": true, "suggestions": ["#FF9500", "#000000"], "recommended": "#FF9500"],
         "ask_color needs a light and dark pair per suggestion."),
        (["question": "Color?", "suggestions": ["#FF9500", "#FF95"], "recommended": "#FF9500"], "#FF95 is not a hex color #RRGGBB or a system color name."),
        (["question": "Color?", "suggestions": ["#FF9500", "SystemBlue"], "recommended": "#FF9500"], "SystemBlue is not a hex color #RRGGBB or a system color name."),
        (["question": "Color?", "suggestions": ["#ff9500", "#FF9500"], "recommended": "#FF9500"], "ask_color has a repeated suggestion."),
        (["question": "Color?", "suggestions": ["#FF9500", "systemBlue"], "recommended": "systemRed"], "ask_color: the recommended color must be one of the suggestions."),
    ] as [(JSONValue, String)])
    func colorRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.color, input) == message)
    }

    @Test("A pair request keeps its pairs as Claude wrote them")
    func colorPairs() async throws {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try PickerItem.request(.color, from: [
            "question": "Background?", "lightAndDark": true,
            "suggestions": [["light": "#ffffff", "dark": "#1C1C1E"], ["light": "systemBackground", "dark": "secondarySystemBackground"]],
            "recommended": ["light": "#FFFFFF", "dark": "#1c1c1e"],
        ], catalogs: snapshot, created: Self.created)
        #expect(item.lightAndDark && item.suggestions[0] == PickerSuggestion("#ffffff", dark: "#1C1C1E") && item.recommended.dark == "#1c1c1e")
        #expect(item.line(item.suggestions[1]) == "Light ![](color:systemBackground), Dark ![](color:secondarySystemBackground)")
    }

    @Test("Sounds: the Mac's, the runtimes' and the project's, in catalogue order", arguments: [
        (["question": "Sound?", "suggestions": ["macOS/Glass.aiff", "macOS/Nope.aiff"], "recommended": "macOS/Glass.aiff"], "macOS/Nope.aiff is not a sound of this Mac or of the project."),
        (["question": "Sound?", "suggestions": ["macOS/Glass.aiff", "iOS 26.1/New/Anticipate.caf"], "recommended": "macOS/Ping.aiff"],
         "ask_sound: the recommended sound must be one of the suggestions."),
    ] as [(JSONValue, String)])
    func soundRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.sound, input) == message)
    }

    @Test("The sound catalogue lists, finds and searches")
    func soundCatalog() async throws {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sounds = try #require(snapshot.sounds)
        #expect(sounds.names == ["macOS/Glass.aiff", "macOS/Ping.aiff", "iOS 26.1/New/Anticipate.caf", "iOS 26.1/sms-received1.caf", "Project/Sounds/alert.caf"])
        #expect(sounds.file(for: "Project/Sounds/alert.caf")?.lastPathComponent == "alert.caf" && sounds.file(for: "Project/x.caf") == nil)
        #expect(SoundCatalog.search("ios sms", in: sounds.names) == ["iOS 26.1/sms-received1.caf"])
        #expect(SoundCatalog.search("project", in: sounds.names) == ["Project/Sounds/alert.caf"])
        #expect(SoundCatalog.search(" ", in: sounds.names).isEmpty)
        #expect(SoundCatalog.search("aiff", in: sounds.names, excluding: ["macOS/Glass.aiff"]) == ["macOS/Ping.aiff"])
        #expect(SoundCatalog.runtimes(fromSimctlJSON: Data(#"{"runtimes":[{"name":"iOS 26.1","runtimeRoot":"/R"},{"name":"bad/name","runtimeRoot":"/X"}]}"#.utf8))
                == [SoundCatalog.Runtime(name: "iOS 26.1", root: URL(fileURLWithPath: "/R", isDirectory: true))])
        #expect(!SoundCatalog.canBeMarked("Project/a(b.caf") && SoundCatalog.canBeMarked("Project/a (1).caf"))
    }

    @Test("Shortcuts: the notation, the recommendation and inUse", arguments: [
        (["question": "Key?", "suggestions": ["⇧⌘F", "⌘⇧K"], "recommended": "⇧⌘F", "inUse": []],
         "⌘⇧K is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key."),
        (["question": "Key?", "suggestions": ["⇧⌘F", "⌘k"], "recommended": "⇧⌘F", "inUse": []],
         "⌘k is not a shortcut in menu notation: the modifiers ⌃⌥⇧⌘ in this order, then one key."),
        (["question": "Key?", "suggestions": ["⇧⌘F", "⌥⌘F"], "recommended": "⌘F", "inUse": []], "ask_shortcut: the recommended shortcut must be one of the suggestions."),
        (["question": "Key?", "suggestions": ["⇧⌘F", "⌥⌘F"], "recommended": "⇧⌘F", "inUse": [["shortcut": "⌘N", "command": ""]]],
         "ask_shortcut: the command of ⌘N in inUse must be one line of 1 to 200 characters."),
        (["question": "Key?", "suggestions": ["⇧⌘F", "⌥⌘F"], "recommended": "⇧⌘F",
          "inUse": [["shortcut": "⌘N", "command": "New"], ["shortcut": "⌘N", "command": "Other"]]], "ask_shortcut: ⌘N appears twice in inUse."),
    ] as [(JSONValue, String)])
    func shortcutRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.shortcut, input) == message)
    }

    @Test("Fonts: the sample, the notation, the size and the catalogue", arguments: [
        (["question": "Font?", "sample": " ", "suggestions": [".headline", ".body"], "recommended": ".body"], "ask_font needs a sample text."),
        (["question": "Font?", "sample": "Title", "suggestions": [".headline", "Avenir Next/Bold"], "recommended": ".headline"],
         "Avenir Next/Bold is not a font: write a text style such as .headline, or <family>/<weight>/<size> such as System Rounded/Semibold/17."),
        (["question": "Font?", "sample": "Title", "suggestions": [".headline", "Avenir Next/Bold/15.25"], "recommended": ".headline"],
         "Avenir Next/Bold/15.25: the size must be 1 to 999 pt, with at most one decimal."),
        (["question": "Font?", "sample": "Title", "suggestions": [".headline", "Avenir Next/Heavy/15"], "recommended": ".headline"],
         "Avenir Next/Heavy/15 is not a font of this Mac."),
        (["question": "Font?", "sample": "Title", "suggestions": [".headline", "System Rounded/Semibold/17"], "recommended": ".body"],
         "ask_font: the recommended font must be one of the suggestions."),
    ] as [(JSONValue, String)])
    func fontRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.font, input) == message)
    }

    @Test("Animations: syntax, preset, parameters, ranges", arguments: [
        (["question": "How?", "suggestions": [".snappy", "spring"], "recommended": ".snappy"], "spring is not a SwiftUI animation expression."),
        (["question": "How?", "suggestions": [".snappy", ".wobbly"], "recommended": ".snappy"],
         ".wobbly: use .smooth, .snappy, .bouncy, .spring, .easeIn, .easeOut, .easeInOut or .linear."),
        (["question": "How?", "suggestions": [".snappy", ".spring(bounce: 0.2, duration: 0.4)"], "recommended": ".snappy"],
         ".spring(bounce: 0.2, duration: 0.4): .spring takes (duration:bounce:)."),
        (["question": "How?", "suggestions": [".snappy", ".spring(duration: 0.4, bounce: 2)"], "recommended": ".snappy"],
         ".spring(duration: 0.4, bounce: 2): bounce must be from -1 to 1."),
        (["question": "How?", "suggestions": [".snappy", ".easeIn()"], "recommended": ".snappy"], ".easeIn() is not a SwiftUI animation expression."),
    ] as [(JSONValue, String)])
    func animationRules(input: JSONValue, message: String) async throws {
        #expect(try await refusal(.animation, input) == message)
    }

    @Test("V2's items read back with their keys, the unknown ones kept")
    func v2Items() throws {
        let lines = [
            ##"{"op":"add","item":{"type":"symbol","id":"6C9D","created":"2026-11-01T14:20:01Z","requestID":"6C9D","question":"Which icon?","suggestions":["star","filter"],"recommended":"star","answer":null,"device":"Studio"}}"##,
            ##"{"op":"add","item":{"type":"color","id":"7D0E","created":"2026-11-03T14:20:01Z","requestID":"7D0E","question":"Which background?","lightAndDark":true,"suggestions":[{"light":"#FFFFFF","dark":"#1C1C1E"},{"light":"systemBackground","dark":"secondarySystemBackground"}],"recommended":{"light":"#FFFFFF","dark":"#1C1C1E"},"answer":"Light ![](color:#FFFFFF), Dark ![](color:#2C2C2E)"}}"##,
            ##"{"op":"add","item":{"type":"shortcut","id":"8E1F","created":"2026-11-03T14:20:01Z","requestID":"8E1F","question":"Which shortcut?","suggestions":["⇧⌘F","⌥⌘F"],"recommended":"⇧⌘F","inUse":[{"shortcut":"⌘N","command":"New Ticket"}],"answer":null}}"##,
            ##"{"op":"add","item":{"type":"font","id":"9F20","created":"2026-11-03T14:20:01Z","requestID":"9F20","question":"Which font?","sample":"Replace the filter","suggestions":["System Rounded/Semibold/17",".headline"],"recommended":".headline","answer":"![](font:.headline)"}}"##,
            ##"{"op":"add","item":{"type":"animation","id":"A031","created":"2026-11-03T14:20:01Z","requestID":"A031","question":"How?","suggestions":[".snappy",".spring(duration: 0.4, bounce: 0.2)"],"recommended":".snappy","answer":null}}"##,
            ##"{"op":"add","item":{"type":"sound","id":"B142","created":"2026-11-03T14:20:01Z","requestID":"B142","question":"Which sound?","suggestions":["macOS/Glass.aiff","Project/Sounds/alert.caf"],"recommended":"macOS/Glass.aiff","answer":"Skipped"}}"##,
        ]
        let items = Transcript.replay(Data(lines.joined(separator: "\n").utf8))
        #expect(items.count == 6)
        let requests = items.compactMap { item -> PickerItem? in if case .picker(let request) = item { request } else { nil } }
        #expect(requests.map(\.kind) == [.symbol, .color, .shortcut, .font, .animation, .sound])
        #expect(requests[0].otherKeys == ["device": "Studio"] && requests[0].answer == nil)
        #expect(requests[1].lightAndDark && requests[1].recommended == PickerSuggestion("#FFFFFF", dark: "#1C1C1E"))
        #expect(requests[2].inUse == [ShortcutInUse(shortcut: "⌘N", command: "New Ticket")])
        #expect(requests[3].sample == "Replace the filter" && requests[3].answer == "![](font:.headline)")
        #expect(requests[5].answerMessage == "Sound: Skipped")
        let written = items.map { String(decoding: Transcript.line(.update, $0), as: UTF8.self) }.joined()
        #expect(written.contains(#""device":"Studio""#) && written.contains(#""lightAndDark":true"#) && written.contains(#""inUse":[{"command":"New Ticket","shortcut":"⌘N"}]"#))
        #expect(Transcript.replay(Data(written.utf8)) == items)
    }

    @Test("Answers and markers: a kind's marker, a shortcut's key escaped, the message")
    func markers() {
        var item = PickerItem(kind: .shortcut, id: "S", created: Self.created, question: "Key?", suggestions: [PickerSuggestion("⌘(")],
                              recommended: PickerSuggestion("⌘("))
        #expect(item.marker("⌘(") == #"![](shortcut:⌘\()"#)
        item.answer = item.marker("⇧⌘K")
        #expect(item.answerMessage == "Shortcut: ![](shortcut:⇧⌘K)")
        let symbol = PickerItem(kind: .symbol, id: "S", created: Self.created, question: "?", suggestions: [], recommended: PickerSuggestion("star"))
        #expect(symbol.marker("star") == "![](sf:star)")
        #expect(throws: ChatError.invalid("answer: write 1 to 10,000 characters.")) { try PickerItem.checkedAnswer("  ") }
    }

    @Test("The symbol catalogue: names of this macOS, search by name then keyword, no localized variant")
    func symbolCatalog() async throws {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        let symbols = try #require(snapshot.symbols)
        #expect(symbols.contains("character.book.closed.ja") && !symbols.contains("future.symbol") && symbols.problems.isEmpty)
        #expect(symbols.search("star") == ["star", "star.fill"])
        #expect(symbols.search("funnel") == ["filter"])
        #expect(symbols.search("book").isEmpty)
        #expect(symbols.search("star", excluding: ["star"]) == ["star.fill"])
        #expect(SFSymbolCatalog(folder: folder.appendingPathComponent("None"), macOSVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)).names.isEmpty)
    }

    @Test("The font catalogue: system designs first, the nearest weight, the search")
    func fontCatalog() async throws {
        let (snapshot, folder) = try await catalogs()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fonts = try #require(snapshot.fonts)
        #expect(fonts.families.map(\.name) == ["System", "System Rounded", "System Serif", "System Monospaced", "Avenir Next"])
        let avenir = try #require(fonts.family(named: "Avenir Next"))
        #expect(FontCatalog.nearestFace(name: "Semibold", value: 0.3, in: avenir)?.name == "Demi Bold")
        #expect(FontCatalog.nearestFace(name: "Regular", value: 0.4, in: avenir)?.name == "Regular")
        #expect(FontCatalog.nearestFace(name: "Medium", value: 0, in: avenir)?.name == "Regular", "An upright face before an italic one")
        #expect(fonts.search("avenir") == [.family("Avenir Next")])
        #expect(fonts.search("large", excludingSuggestions: [".largeTitle"]).isEmpty)
        #expect(fonts.search("").count == 5 + FontTextStyle.allCases.count)
        #expect(fonts.contains(.family(family: "System", weight: "Black", size: "9")) && !fonts.contains(.family(family: "System", weight: "Book", size: "9")))
    }

    @Test("A project's files: a walk without hidden names, build folders and sub projects")
    func projectFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Sounds", ".git", "node_modules/x", "Sub/Sounds"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Sounds/a.CAF", "Sounds/b.txt", ".git/c.caf", "node_modules/x/d.wav", "Sub/Sounds/e.mp3", "f.ttf"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }
        let files = ProjectFiles(git: nil, excluded: ["Sub"])
        #expect(await files.paths(in: root, matching: SoundCatalog.extensions) == ["Sounds/a.CAF"])
        #expect(await files.paths(in: root, matching: FontCatalog.fontFileExtensions) == ["f.ttf"])
    }
}

@Suite("Picker requests in a chat")
@MainActor
struct ChatPickerTests {
    @Test("A request waits once the turn ends; the answer goes to Claude as the user's message, once")
    func flow() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Pick an icon", references: [], to: nil, projectID: "ORD")
        let item = try await world.session.postPicker(id, kind: .symbol, input: ["question": "Which icon?", "suggestions": ["star", "filter"], "recommended": "star"])
        #expect(world.session.waitingPicker(in: id) == item)
        await #expect(throws: ToolError(.conflict, "A symbol request is already waiting for an answer in this chat.")) {
            _ = try await world.session.postPicker(id, kind: .font, input: ["question": "Font?", "sample": "x", "suggestions": [".body", ".headline"], "recommended": ".body"])
        }
        await #expect(throws: ChatError.conflict("A symbol request is already waiting for an answer in this chat.")) {
            _ = try await world.session.postQuestions(id, questions: [ChatQuestion(label: "A", question: "?", options: [.init(label: "a"), .init(label: "b")], recommended: ["a"])])
        }
        let first = try #require(world.launcher.chats.first)
        first.finish(.exited(0))
        try await world.until { world.session.state(of: id) == .waitingAnswers }

        try await world.session.answerPicker(id, requestID: item.requestID, answer: " ![](sf:filter) ")
        #expect(world.session.waitingPicker(in: id) == nil)
        guard case .picker(let done)? = world.items(id).first(where: { $0.id == item.id }) else { Issue.record("No request"); return }
        #expect(done.answer == "![](sf:filter)")
        guard case .user(let message)? = world.items(id).last else { Issue.record("No answer message"); return }
        #expect(message.text == "Symbol: ![](sf:filter)")
        let second = try #require(world.launcher.chats.last)
        #expect(second !== first, "The answer starts the chat's CLI again")
        await #expect(throws: ChatError.conflict("This symbol request was already answered.")) {
            try await world.session.answerPicker(id, requestID: item.requestID, answer: "Skipped")
        }
        second.finish(.exited(0))
    }

    @Test("Questions waiting refuse a request; a request's notification input is its kind and question")
    func questionsConflictAndNotification() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Plan", references: [], to: nil, projectID: "ORD")
        _ = try await world.session.postQuestions(id, questions: [ChatQuestion(label: "A", question: "?", options: [.init(label: "a"), .init(label: "b")], recommended: ["a"])])
        await #expect(throws: ToolError(.conflict, "Questions already wait for the user's answers in this chat.")) {
            _ = try await world.session.postPicker(id, kind: .color, input: ["question": "Color?", "suggestions": ["red", "blue"], "recommended": "red"])
        }
        let other = try await world.session.send("Colors", references: [], to: nil, projectID: "ORD")
        _ = try await world.session.postPicker(other, kind: .color, input: ["question": "Which **color**?", "suggestions": ["red", "blue"], "recommended": "red"])
        let event = try #require(world.session.chats[other].map { world.session.event(.needsYou, chatID: other, chat: $0, state: .waitingAnswers) })
        #expect(event.summaryInput == "Color request:\nWhich **color**?")
    }

    @Test("Sounds, shortcuts and animations only in an App project")
    func projectType() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Sound", references: [], to: nil, projectID: "ORD")
        let input: JSONValue = ["question": "Sound?", "suggestions": ["macOS/Glass.aiff", "macOS/Ping.aiff"], "recommended": "macOS/Glass.aiff"]
        await #expect(throws: ToolError(.forbidden, "ask_sound is only available in Swift application projects.")) {
            _ = try await world.session.postPicker(id, kind: .sound, input: input)
        }
        await #expect(throws: ToolError(.forbidden, "ask_shortcut is available only in Swift application projects.")) {
            _ = try await world.session.postPicker(id, kind: .shortcut, input: [:])
        }
        await #expect(throws: ToolError(.forbidden, "ask_animation is available only in Swift application projects.")) {
            _ = try await world.session.postPicker(id, kind: .animation, input: [:])
        }

        let app = try await ChatWorld(projectType: "swiftApplication")
        defer { Task { await app.close() } }
        let chat = try await app.session.send("Sound", references: [], to: nil, projectID: "ORD")
        let item = try await app.session.postPicker(chat, kind: .sound, input: input)
        #expect(item.kind == .sound && item.suggestions.count == 2)
        #expect(await app.session.soundFile(named: "macOS/Glass.aiff", projectRoot: app.repo.path)?.lastPathComponent == "Glass.aiff")
        #expect(await app.session.soundFile(named: "Project/../x.caf", projectRoot: app.repo.path) == nil)
    }
}
