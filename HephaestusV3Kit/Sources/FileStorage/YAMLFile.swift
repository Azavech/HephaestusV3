import Foundation

/// Reading and writing one YAML file: the read rules, an atomic write, and the record of the write.
public enum YAMLFile {
    /// Reads and decodes a file. Throws `StorageError.readFailed` for a missing or unreadable file,
    /// `invalidFile` for a file that breaks a read rule.
    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws(StorageError) -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .readFailed(path: url.path, reason: (error as NSError).localizedDescription)
        }
        return try decode(type, from: data, path: url.path)
    }

    /// Decodes a file's bytes; `path` names the file in the error.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws(StorageError) -> T {
        do {
            return try YAMLCoding.decode(type, from: data)
        } catch {
            throw .invalidFile(path: path, reason: FileFormatError.describe(error))
        }
    }

    /// True when the file is missing (rather than unreadable or invalid).
    public static func isMissing(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// Encodes a value and writes it atomically, then records the write in `ownWrites`.
    /// - Returns: the SHA-256 of the written bytes.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to url: URL, ownWrites: OwnWrites? = nil,
                                           newFileMode: mode_t = AtomicFile.defaultMode) throws(StorageError) -> String {
        let data: Data
        do {
            data = try YAMLCoding.encodeData(value)
        } catch {
            throw .writeFailed(path: url.path, reason: "cannot encode: \(error)")
        }
        let digest: String
        do {
            digest = try AtomicFile.write(data, to: url, newFileMode: newFileMode)
        } catch let error as StorageError {
            throw error
        } catch {
            throw .writeFailed(path: url.path, reason: String(describing: error))
        }
        ownWrites?.recordWrite(path: AtomicFile.resolvedDestination(url).path, sha256: digest)
        return digest
    }
}
