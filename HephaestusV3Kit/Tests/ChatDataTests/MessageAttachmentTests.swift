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
