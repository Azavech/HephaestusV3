import FileStorage
import Foundation

/// The values typed in the Contracts window, per contract file: credentials, added headers, and per operation
/// the parameters, the media type and the bodies edited (docs/data.md › Contracts › Stored values). V2's
/// `openapi-requests.json` format, in the data folder, mode 0600.
public struct StoredContract: Sendable, Hashable {
    public var projectID: String
    /// The contract's path in its project, such as `openapi/contract.yaml`.
    public var path: String
    public var credentials: [String: [String: String]]
    public var headers: [StoredHeader]
    public var operations: [String: StoredOperation]
    /// V2's device id, kept as read.
    public var deviceID: String?

    public init(projectID: String, path: String) {
        self.projectID = projectID
        self.path = path
        credentials = [:]
        headers = []
        operations = [:]
    }
}

public struct StoredHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct StoredOperation: Sendable, Hashable {
    /// By `<in>:<name>`.
    public var parameters: [String: String] = [:]
    public var mediaType: String?
    /// The bodies edited, by media type.
    public var bodies: [String: String] = [:]

    public init() {}
}

public enum StoredValuesFile {
    /// `<data folder>/openapi-requests.json`.
    public static let name = "openapi-requests.json"

    /// The contracts of a file; a missing, unreadable or invalid one is empty.
    public static func read(_ url: URL) -> [StoredContract] {
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contracts = object["contracts"] as? [[String: Any]] else { return [] }
        return contracts.compactMap { entry in
            guard let project = entry["projectID"] as? String, let path = entry["path"] as? String else { return nil }
            var contract = StoredContract(projectID: project, path: path)
            contract.deviceID = entry["deviceID"] as? String
            contract.credentials = entry["credentials"] as? [String: [String: String]] ?? [:]
            contract.headers = (entry["headers"] as? [[String: String]] ?? []).map { StoredHeader(name: $0["name"] ?? "", value: $0["value"] ?? "") }
            for (key, value) in entry["operations"] as? [String: [String: Any]] ?? [:] {
                var operation = StoredOperation()
                operation.parameters = value["parameters"] as? [String: String] ?? [:]
                operation.mediaType = value["mediaType"] as? String
                operation.bodies = value["bodies"] as? [String: String] ?? [:]
                contract.operations[key] = operation
            }
            return contract
        }
    }

    /// Writes the contracts atomically, mode 0600; V2's keys of earlier versions are left out.
    public static func write(_ contracts: [StoredContract], to url: URL) throws(StorageError) {
        let entries: [[String: Any]] = contracts.map { contract in
            var entry: [String: Any] = [
                "projectID": contract.projectID, "path": contract.path, "credentials": contract.credentials,
                "headers": contract.headers.map { ["name": $0.name, "value": $0.value] },
                "operations": contract.operations.mapValues { operation -> [String: Any] in
                    var value: [String: Any] = ["parameters": operation.parameters, "bodies": operation.bodies]
                    if let type = operation.mediaType { value["mediaType"] = type }
                    return value
                },
            ]
            if let device = contract.deviceID { entry["deviceID"] = device }
            return entry
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: ["contracts": entries], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw .writeFailed(path: url.path, reason: error.localizedDescription)
        }
        do {
            _ = try AtomicFile.write(data + Data("\n".utf8), to: url, newFileMode: AtomicFile.privateMode)
        } catch {
            throw .writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// V2's file, `~/Library/Application Support/HephaestusV2/openapi-requests.json`.
    public static func v2File(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/HephaestusV2/\(name)")
    }

    /// Copies V2's values once: when the data folder has no file yet and V2's exists. Returns whether it did.
    @discardableResult
    public static func importV2(from v2: URL, to url: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: v2.path) else { return false }
        let contracts = read(v2)
        guard !contracts.isEmpty else { return false }
        return (try? write(contracts, to: url)) != nil
    }
}
