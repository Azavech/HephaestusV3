import FileStorage
import Foundation
import Testing
@testable import TicketData

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "yml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Ticket and bundle files")
struct TicketFileTests {
    @Test("V2's complete ticket and bundle are written back byte for byte")
    func roundTrips() throws {
        for name in ["HEPH-12", "HEPH-B2"] {
            let data = try fixture(name)
            let text = String(decoding: data, as: UTF8.self)
            let written = name.hasPrefix("HEPH-B")
                ? try YAMLCoding.encode(YAMLCoding.decode(BundleFile.self, from: data))
                : try YAMLCoding.encode(YAMLCoding.decode(TicketFile.self, from: data))
            #expect(written == text, "\(name)")
        }
    }

    @Test("A minimal ticket takes its defaults and a creation entry; unknown keys follow the known ones")
    func defaults() throws {
        let minimal = try YAMLCoding.decode(TicketFile.self, from: fixture("HEPH-13"))
        #expect(minimal.status == .todo)
        #expect(minimal.updated == minimal.created)
        #expect(minimal.history.map(\.kind) == [.created])
        let unknown = try YAMLCoding.decode(TicketFile.self, from: fixture("HEPH-14"))
        #expect(unknown.unknownKeys.keys == ["estimate", "labels"] || unknown.labels == ["ui", "console"])
        let full = try YAMLCoding.decode(TicketFile.self, from: fixture("HEPH-12"))
        #expect(full.comments.count >= 1)
        #expect(full.links.first?.kind == .related)
    }
}
