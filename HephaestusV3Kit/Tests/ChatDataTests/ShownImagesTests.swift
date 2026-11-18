import Foundation
import MCPKit
import Testing
@testable import ChatData

/// docs/data.md › Images item.
@Suite("Shown images")
@MainActor
struct ShownImagesTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    @Test("The signature decides the format, whatever the extension")
    func signatures() {
        #expect(ImagesItem.contentType(ofSignature: png) == "image/png")
        #expect(ImagesItem.contentType(ofSignature: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ImagesItem.contentType(ofSignature: Data("GIF89a....".utf8)) == "image/gif")
        #expect(ImagesItem.contentType(ofSignature: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == "image/webp")
        #expect(ImagesItem.contentType(ofSignature: Data("%PDF-1.7".utf8)) == nil)
    }

    @Test("The images are copied into the chat, an item at the place of the call; a broken rule stores nothing")
    func post() async throws {
        let world = try await ChatWorld()
        defer { Task { await world.close() } }
        let id = try await world.session.send("Show me", references: [], to: nil, projectID: "ORD")
        try png.write(to: world.repo.appendingPathComponent("icon.jpg"))
        let pdf = world.root.appendingPathComponent("doc.png")
        try Data("%PDF-1.7".utf8).write(to: pdf)
        let item = try world.session.postImages(id, paths: ["icon.jpg", "icon.jpg"], caption: "  The icon\n")
        #expect(item.caption == "The icon" && item.images.map(\.contentType) == ["image/png", "image/png"] && item.images.map(\.name) == ["icon.jpg", "icon.jpg"])
        let folder = world.repo.appendingPathComponent(".hephaestus/chats/\(id)")
        #expect(item.images.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id)-\($0.name)").path) })
        guard case .images(let recorded)? = world.items(id).last else { Issue.record("No item"); return }
        #expect(recorded == item)
        #expect(Transcript.replay(Transcript.line(.add, .images(item))) == [.images(item)], "Written and read back")

        let count = world.items(id).count
        #expect(throws: ChatError.invalid("show_image needs 1 to 10 images.")) { try world.session.postImages(id, paths: [], caption: nil) }
        #expect(throws: ChatError.invalid("missing.png is not a readable file.")) { try world.session.postImages(id, paths: ["missing.png"], caption: nil) }
        #expect(throws: ChatError.invalid("\(pdf.path) is not a PNG, JPEG, GIF or WebP image.")) {
            try world.session.postImages(id, paths: ["icon.jpg", pdf.path], caption: nil)
        }
        #expect(world.items(id).count == count)
        world.launcher.chats.forEach { $0.finish(.exited(0)) }
    }
}
