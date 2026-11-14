import ContractData
import Foundation
import Observation
import ProjectData
import SwiftUI
import ToolsFoundation

/// A contract as the window reads it: none, on its way, read, or unreadable with the parser's message.
enum ContractLoad: Hashable {
    case none
    case loading
    case loaded(Contract)
    case failed(String)

    var value: Contract? { if case .loaded(let contract) = self { contract } else { nil } }
}

/// Where the contracts come from: `LiveContractStore` in the app; `SampleContractStore` in previews.
protocol ContractStore: AnyObject {
    func contract(of project: Project) -> ContractLoad
    /// Reads the project's contract again.
    func refresh(_ project: Project) async
    /// Sends the draft's request to the environment; throws why no answer came.
    func send(_ draft: RequestDraft, to environment: DeploymentEnvironment, of project: Project) async throws(ContractSendError) -> SampleResponse
    /// The answer of the operation's last call in this run of the app.
    func lastResponse(of operation: Operation, in project: Project) -> SampleResponse?
    /// Makes the environment the project's current one.
    func setEnvironment(_ name: String, of project: Project)
    /// The credentials the contract asks for, and the added headers, as stored.
    func access(of project: Project) -> ContractAccess?
    func setAccess(_ access: ContractAccess, of project: Project)
}

struct ContractSendError: Error, Hashable {
    let message: String
}

/// The schemes the contract names with their stored values, and the added headers (docs/ui/contracts.md ›
/// Credentials and headers).
struct ContractAccess: Hashable {
    struct Scheme: Hashable, Identifiable {
        enum Kind: Hashable { case apiKey(String), basic, bearer }
        let name: String
        let kind: Kind
        let description: String
        var values: [String: String]
        var id: String { name }
    }

    var schemes: [Scheme]
    var headers: [StoredHeader]
}

/// The samples: fixed contracts whose operations carry their last call.
final class SampleContractStore: ContractStore {
    func contract(of project: Project) -> ContractLoad {
        contract(of: project.id).map(ContractLoad.loaded) ?? .none
    }

    func contract(of projectID: Project.ID) -> Contract? {
        Contract.sample(for: projectID)
    }

    func refresh(_ project: Project) async {}

    func send(_ draft: RequestDraft, to environment: DeploymentEnvironment, of project: Project) async throws(ContractSendError) -> SampleResponse {
        throw ContractSendError(message: String(localized: "The samples send nothing.", bundle: #bundle))
    }

    func lastResponse(of operation: Operation, in project: Project) -> SampleResponse? { nil }
    func setEnvironment(_ name: String, of project: Project) {}
    func access(of project: Project) -> ContractAccess? { nil }
    func setAccess(_ access: ContractAccess, of project: Project) {}
}

/// The app's contracts: each project's `openapi/contract.yaml`, read with its `$ref` pointers resolved, sent with
/// the app's HTTP client; the credentials and added headers kept in `openapi-requests.json` (docs/data.md ›
/// Contracts).
@Observable
public final class LiveContractStore: ContractStore {
    /// The contract file of a project, relative to its folder.
    public static let path = "openapi/contract.yaml"

    private var loads: [Project.ID: ContractLoad] = [:]
    /// The read contracts, by project, for requests and Claude.
    @ObservationIgnored private var documents: [Project.ID: OpenAPIContract] = [:]
    private var responses: [String: SampleResponse] = [:]
    private var stored: [StoredContract]
    @ObservationIgnored private let projects: ProjectSession
    @ObservationIgnored private let valuesFile: URL?
    @ObservationIgnored private let client = ContractHTTPClient()

    public init(projects: ProjectSession) {
        self.projects = projects
        valuesFile = projects.dataFolder?.url.appendingPathComponent(StoredValuesFile.name)
        if let valuesFile { StoredValuesFile.importV2(from: StoredValuesFile.v2File(), to: valuesFile) }
        stored = valuesFile.map(StoredValuesFile.read) ?? []
        projects.observeFileEvents { [weak self] batch in
            guard let self else { return }
            for id in Array(self.loads.keys) {
                guard let root = self.projects.snapshot.project(id)?.root,
                      batch.contains(where: { $0.path.hasPrefix(root + "/openapi") || $0.kind.contains(.mustRescan) }) else { continue }
                await self.read(id)
            }
        }
    }

    func contract(of project: Project) -> ContractLoad {
        loads[project.id] ?? (project.hasContract ? .loading : .none)
    }

    func refresh(_ project: Project) async {
        await read(project.id)
    }

    /// The read contract of a project: for Claude's tools.
    public func document(of projectID: String) async -> Result<OpenAPIContract, ContractError>? {
        if documents[projectID] == nil { await read(projectID) }
        if let document = documents[projectID] { return .success(document) }
        if case .failed(let message)? = loads[projectID] { return .failure(.unreadable(message)) }
        return nil
    }

    private func read(_ projectID: String) async {
        guard let root = projects.snapshot.project(projectID)?.root else { return }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let file = folder.appendingPathComponent(Self.path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            loads[projectID] = ContractLoad.none
            documents[projectID] = nil
            return
        }
        let result = await Task.detached { () -> Result<OpenAPIContract, ContractError> in
            do throws(ContractError) {
                let text: String
                do { text = try String(contentsOf: file, encoding: .utf8) } catch { throw .unreadable(error.localizedDescription) }
                return .success(try OpenAPIContract.read(text, file: file, root: folder))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let document):
            documents[projectID] = document
            let mapped = Self.contract(document)
            if loads[projectID] != .loaded(mapped) { loads[projectID] = .loaded(mapped) }
        case .failure(let error):
            documents[projectID] = nil
            loads[projectID] = .failed(error.description)
        }
    }

    func send(_ draft: RequestDraft, to environment: DeploymentEnvironment, of project: Project) async throws(ContractSendError) -> SampleResponse {
        guard let document = documents[project.id], let operation = document.operation(draft.operation.key) else {
            throw ContractSendError(message: String(localized: "The contract isn't read.", bundle: #bundle))
        }
        let response = try await call(document, operation, values: values(for: draft, project: project), name: environment.name,
                                      base: environment.url, allowsInvalidCertificates: environment.allowsInvalidCertificates)
        let sample = Self.sample(response)
        responses[Self.responseKey(project.id, draft.operation.key)] = sample
        return sample
    }

    /// Sends an operation's request with `values` and the stored credentials and headers.
    func call(_ document: OpenAPIContract, _ operation: OpenAPIOperation, values: RequestValues, name: String, base: String?,
              allowsInvalidCertificates: Bool) async throws(ContractSendError) -> ContractResponse {
        guard let base, !base.isEmpty else {
            throw ContractSendError(message: String(localized: "Set the URL of \(name) in Project Settings.", bundle: #bundle))
        }
        guard let request = RequestBuilder.request(operation, base: base, values: values, schemes: document.schemes(for: operation)) else {
            throw ContractSendError(message: String(localized: "The request's URL isn't valid.", bundle: #bundle))
        }
        do throws(ContractCallError) {
            return try await client.send(request, allowInvalidCertificates: allowsInvalidCertificates)
        } catch {
            throw ContractSendError(message: error.message)
        }
    }

    /// The draft's values with the project's stored credentials and headers.
    func values(for draft: RequestDraft, project: Project) -> RequestValues {
        var parameters: [String: String] = [:]
        for parameter in draft.operation.parameters {
            parameters["\(parameter.location.rawValue):\(parameter.name)"] = draft[parameter]
        }
        return values(parameters: parameters, body: draft.body, mediaType: draft.operation.mediaType, projectID: project.id)
    }

    func values(parameters: [String: String], body: String, mediaType: String?, projectID: String) -> RequestValues {
        let contract = storedContract(projectID)
        return RequestValues(parameters: parameters, mediaType: mediaType, body: body, credentials: contract?.credentials ?? [:],
                             headers: (contract?.headers ?? []).map { ($0.name, $0.value) })
    }

    func lastResponse(of operation: Operation, in project: Project) -> SampleResponse? {
        responses[Self.responseKey(project.id, operation.key)]
    }

    func setEnvironment(_ name: String, of project: Project) {
        Task { try? await projects.setCurrentEnvironment(project.id, to: name) }
    }

    // MARK: Credentials and headers

    private func storedContract(_ projectID: String) -> StoredContract? {
        stored.first { $0.projectID == projectID && $0.path == Self.path }
    }

    func access(of project: Project) -> ContractAccess? {
        guard let document = documents[project.id] else { return nil }
        let contract = storedContract(project.id)
        return ContractAccess(schemes: document.securitySchemes.map { scheme in
            let kind: ContractAccess.Scheme.Kind = switch scheme.kind {
            case .apiKey(let name, let location): .apiKey("\(name) (\(location.rawValue))")
            case .basic: .basic
            case .bearer: .bearer
            }
            return ContractAccess.Scheme(name: scheme.name, kind: kind, description: scheme.description, values: contract?.credentials[scheme.name] ?? [:])
        }, headers: contract?.headers ?? [])
    }

    func setAccess(_ access: ContractAccess, of project: Project) {
        var contract = storedContract(project.id) ?? StoredContract(projectID: project.id, path: Self.path)
        for scheme in access.schemes {
            let values = scheme.values.filter { !$0.value.isEmpty }
            contract.credentials[scheme.name] = values.isEmpty ? nil : values
        }
        contract.headers = access.headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        stored.removeAll { $0.projectID == project.id && $0.path == Self.path }
        stored.append(contract)
        if let valuesFile { try? StoredValuesFile.write(stored, to: valuesFile) }
    }

    // MARK: Mapping

    private static func responseKey(_ projectID: String, _ key: String) -> String { "\(projectID) \(key)" }

    static func sample(_ response: ContractResponse) -> SampleResponse {
        let body = response.text ?? String(localized: "Binary body (\(response.body.count.formatted(.byteCount(style: .file))))", bundle: #bundle)
        return SampleResponse(status: response.status, duration: .milliseconds(response.durationMs), bytes: response.body.count, body: body)
    }

    static func contract(_ document: OpenAPIContract) -> Contract {
        Contract(title: document.title, version: document.version, operations: document.operations.map { operation in
            var mapped = Operation(
                id: operation.operationID ?? operation.key,
                method: HTTPMethod(rawValue: operation.method.uppercased()) ?? .get,
                path: operation.path, summary: operation.summary, tag: operation.tags.first ?? "default",
                parameters: operation.parameters.map { parameter in
                    Parameter(name: parameter.name, location: Parameter.Location(rawValue: parameter.location.rawValue) ?? .query,
                              type: parameter.type, isRequired: parameter.isRequired, example: parameter.example)
                },
                requestBody: operation.requestBody?.mediaTypes.first?.example,
                responses: operation.responses.map { DocumentedResponse(code: $0.code, description: $0.description) },
                lastResponse: nil
            )
            mapped.mediaType = operation.requestBody?.mediaTypes.first?.name
            mapped.details = operation.description
            return mapped
        })
    }
}

extension EnvironmentValues {
    /// The app's contracts; nil in previews.
    @Entry public var contractStore: LiveContractStore?
}
