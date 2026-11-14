import Foundation

/// Runs `body` with a new empty folder in the system's temporary folder, deleted afterwards. Tests
/// never touch the user's folders.
func withTemporaryFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileStorageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

func withTemporaryFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileStorageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    return try await body(folder)
}
