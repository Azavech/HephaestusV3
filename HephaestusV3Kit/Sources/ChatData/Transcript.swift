import Darwin
import FileStorage
import Foundation
import MCPKit

/// `.hephaestus/chats/<CHAT-ID>.jsonl`: a chat's transcript, one `{"op", "item"}` line per item added or
/// replaced, appended and never rewritten (docs/data.md › Chat transcript file).
public enum Transcript {
    public enum Op: String, Sendable {
        case add, update
    }

    /// The items of a transcript, its lines replayed in order: `add` appends an item, or replaces the one with
    /// its id; `update` replaces the item with its id, or appends it. A line that isn't JSON, has another `op`,
    /// an item V3 doesn't read or lacks a required key is skipped.
    public static func replay(_ data: Data) -> [ChatItem] {
        var items: [ChatItem] = []
        var index: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let value = try? JSONValue.parse(Data(line)), value["op"]?.stringValue.flatMap(Op.init(rawValue:)) != nil,
                  let json = value["item"], let item = ChatItem(json: json) else { continue }
            if let position = index[item.id] {
                items[position] = item
            } else {
                index[item.id] = items.count
                items.append(item)
            }
        }
        return items
    }

    /// One line: compact JSON, then LF.
    public static func line(_ op: Op, _ item: ChatItem) -> Data {
        var data = JSONValue.object(["op": .string(op.rawValue), "item": item.json]).data
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Appends lines in one `write` with `O_APPEND`, creating the file (mode 0644) when it is missing. With
    /// `endingLine`, first appends LF when the file doesn't end with one, so that a line a crash cut short stays
    /// apart from the next.
    public static func append(_ lines: Data, to url: URL, endingLine: Bool) throws(StorageError) {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw .writeFailed(path: url.path, reason: String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var data = lines
        if endingLine, let last = lastByte(of: url), last != UInt8(ascii: "\n") {
            data.insert(UInt8(ascii: "\n"), at: data.startIndex)
        }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw .writeFailed(path: url.path, reason: String(cString: strerror(errno))) }
    }

    private static func lastByte(of url: URL) -> UInt8? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        try? handle.seek(toOffset: end - 1)
        return try? handle.read(upToCount: 1)?.first
    }
}
