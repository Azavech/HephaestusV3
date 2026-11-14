import Foundation
import Testing

/// A fixture copied from HephaestusV2's docs/data-model.md.
func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Runs `body` with a new empty folder in the system's temporary folder, deleted afterwards. Tests never
/// touch the user's projects or data folders.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectDataTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder.resolvingSymlinksInPath())
}

/// Writes a project file with `id` in `folder`.
func makeProject(_ id: String, in folder: URL) throws {
    let file = folder.appendingPathComponent(".hephaestus/project.yml")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema: 1\nid: \(id)\nname: \(id)\ncreated: 2026-10-31T09:30:00Z\n".utf8).write(to: file)
}
