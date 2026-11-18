import FileStorage
import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Chat items › Message files.
@Suite("Message files")
struct MessageAttachmentTests {
    @Test("A V2 message's files read back, their unknown keys kept")
    func v2() throws {
        let line = #"{"op":"add","item":{"type":"user","id":"U1","created":"2026-10-31T13:00:00Z","text":"Why?","attachments":[{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","name":"build.log","path":"chats/C1/1B4E28BA-2FA1-11D2-883F-0016D3CCA427-build.log","contentType":"text/plain","size":12,"checksum":"abc"}],"sender":"MacBook","linkedItems":[]}}"#
        let items = Transcript.replay(Data(line.utf8))
        guard case .user(let message)? = items.first else { Issue.record("No message"); return }
        let file = try #require(message.attachments.first)
        #expect(file.id == "1B4E28BA-2FA1-11D2-883F-0016D3CCA427" && file.name == "build.log" && file.contentType == "text/plain" && file.size == 12)
        #expect(file.otherKeys == ["checksum": "abc"])
        #expect(Transcript.replay(Transcript.line(.add, .user(message))) == items, "Written back as read")
    }

    @Test("A stored file's attachment: its path in the chat's folder, its type from its extension")
    func stored() {
        let file = MessageAttachment.stored(id: "A", name: "screenshot.png", chatID: "C1", size: 9)
        #expect(file.path == "chats/C1/A-screenshot.png" && file.contentType == "image/png" && file.size == 9)
        #expect(MessageAttachment.contentType(ofName: "README") == "application/octet-stream")
    }

    @Test("Only a file of a chat's folder, links resolved, is found")
    func paths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MessageAttachmentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = root.appendingPathComponent(".hephaestus/chats/C1")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: chats.appendingPathComponent("L-link.txt"), withDestinationURL: outside)

        func url(_ path: String) -> URL? {
            MessageAttachment(id: "A", name: "a", path: path, contentType: "text/plain", size: 0).url(inProject: root.path)
        }
        #expect(url("chats/C1/A-a.txt")?.path == chats.appendingPathComponent("A-a.txt").path, "A file not there yet is still its place")
        #expect(url("chats/C1/../../secret.txt") == nil)
        #expect(url("chats/C1/sub/a.txt") == nil)
        #expect(url("attachments/ORD-1/a.txt") == nil)
        #expect(url("/etc/hosts") == nil)
        #expect(url("chats/C1/L-link.txt") == nil, "A link out of .hephaestus/ is refused")
    }

    @Test("A feedback message of 1.0.31 to 1.0.33 gives the files of its chat's folder that its lines name")
    func legacyFeedback() {
        let root = "/Users/you/Repo"
        let folder = "\(root)/.hephaestus/chats/C1"
        let text = """
            /hephaestus-skills:report-feedback
            The sidebar is black

            Feedback context:
            - App: Hephaestus V3 1.0.32 (54)
            - Screenshot: \(folder)/8FF0CD02-5ECC-41D0-81AB-0995DF0C8767-screenshot.png
            - Attachment: \(folder)/1B4E28BA-2FA1-11D2-883F-0016D3CCA427-app.log
            - Attachment: /tmp/elsewhere.log
            - Attachment: \(folder)/not-a-uuid-name.log
            """
        let files = FeedbackReport.files(inMessage: text, chatID: "C1", root: root)
        #expect(files.map(\.name) == ["screenshot.png", "app.log"])
        #expect(files.map(\.id) == ["8FF0CD02-5ECC-41D0-81AB-0995DF0C8767", "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"])
        #expect(files[0].path == "chats/C1/8FF0CD02-5ECC-41D0-81AB-0995DF0C8767-screenshot.png")
        #expect(FeedbackReport.files(inMessage: "- Screenshot: \(folder)/8FF0CD02-5ECC-41D0-81AB-0995DF0C8767-a.png", chatID: "C1", root: root).isEmpty,
                "Only after Feedback context:")
    }
}

@Suite("Messages with files")
@MainActor
struct MessageFilesTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    @Test("A message's files are stored in the chat's folder, kept on the message, its images sent, each path after the text")
    func send() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let inbox = world.root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let log = inbox.appendingPathComponent("build.log")
        try Data("failed".utf8).write(to: log)
        let shot = inbox.appendingPathComponent("shot.png")
        try png.write(to: shot)

        let id = try await world.session.send("Why?", references: [], to: nil, projectID: "ORD", files: [log, shot])
        guard case .user(let message)? = world.items(id).first else { Issue.record("No message"); return }
        #expect(message.text == "Why?" && message.attachments.map(\.name) == ["build.log", "shot.png"])
        let folder = world.repo.appendingPathComponent(".hephaestus/chats/\(id)")
        let stored = message.attachments.map { folder.appendingPathComponent("\($0.id)-\($0.name)") }
        #expect(stored.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let cli = try #require(world.launcher.chats.first)
        try await world.until { cli.written.contains { $0["type"]?.stringValue == "user" } }
        let user = try #require(cli.written.first { $0["type"]?.stringValue == "user" })
        let blocks = try #require(user["message"]?["content"]?.arrayValue)
        #expect(blocks.map { $0["type"]?.stringValue } == ["image", "text"])
        #expect(blocks[1]["text"]?.stringValue == "Why?\n\nAttached: file \(stored[0].path)\nAttached: file \(stored[1].path)")
        cli.finish(.exited(0))
    }

    @Test("Files alone make a message; a folder is refused before anything is made")
    func filesOnly() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let log = world.root.appendingPathComponent("app.log")
        try Data("x".utf8).write(to: log)
        let id = try await world.session.send("  ", references: [], to: nil, projectID: "ORD", files: [log])
        #expect(world.session.chats[id]?.file.title == "app.log")
        guard case .user(let message)? = world.items(id).first else { Issue.record("No message"); return }
        #expect(message.text.isEmpty && message.attachments.count == 1)
        let chats = world.session.chats.count
        await #expect(throws: ChatError.invalid("Folders cannot be attached.")) {
            _ = try await world.session.send("Look", references: [], to: nil, projectID: "ORD", files: [world.root])
        }
        #expect(world.session.chats.count == chats)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }
}

@Suite("Result images")
@MainActor
struct ResultImagesTests {
    @Test("A result's images come after its item, and the session stores them as image-<n> files of the chat's folder")
    func images() async throws {
        var mapper = StreamMapper(effort: .high, now: { Date() })
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"shot"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#
        let outputs = mapper.map(Data(line.utf8))
        #expect(outputs.count == 2)
        guard case .toolResultImages(let id, let images) = outputs[1] else { Issue.record("No images"); return }
        #expect(id == "t1" && images.first?.mediaType == "image/png" && images.first?.data == Data(base64Encoded: png))

        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let chat = try await world.session.send("Look", references: [], to: nil, projectID: "ORD")
        world.session.record(.toolResult(ToolResultItem(id: "t1#result", created: Date(), toolUseID: "t1", text: "shot", isError: false)), in: chat)
        world.session.storeResultImages(images, of: "t1", in: chat)
        guard case .toolResult(let result)? = world.items(chat).last else { Issue.record("No result"); return }
        let file = try #require(result.imageFiles.first)
        #expect(file.name == "image-1.png" && file.contentType == "image/png" && file.path == "chats/\(chat)/\(file.id)-image-1.png")
        #expect(FileManager.default.fileExists(atPath: world.repo.appendingPathComponent(".hephaestus/\(file.path)").path))
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }
}
