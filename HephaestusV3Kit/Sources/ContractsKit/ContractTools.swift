import ContractData
import Foundation
import MCPKit
import ProjectData
import ToolsFoundation

/// The API operations the MCP server offers Claude (docs/mcp.md › API tools): the operations of a project's
/// contract, and a call of one, built as the Contracts window builds it, with the credentials and headers kept
/// on this Mac, which Claude never sees.
public enum ContractTools {
    @MainActor
    public static func operations(contracts: LiveContractStore, projects: ProjectSession) -> [ToolOperation] {
        [apiOperations(contracts, projects), apiCall(contracts, projects)]
    }

    static let projectID = ToolSchema.string("Project identifier, 2 to 8 letters, such as ORD.")

    @MainActor
    static func document(_ contracts: LiveContractStore, _ projects: ProjectSession, _ arguments: JSONValue) async throws(ToolError) -> OpenAPIContract {
        let id = try arguments.string("projectID").uppercased()
        guard projects.snapshot.project(id) != nil else { throw ToolError(.notFound, "Project \(id) not found.") }
        switch await contracts.document(of: id) {
        case .success(let document)?: return document
        case .failure(let error)?: throw ToolError(.invalid, "The contract can't be read: \(error.description)")
        case nil: throw ToolError(.notFound, "Project \(id) has no contract: no \(LiveContractStore.path) in its folder.")
        }
    }

    @MainActor
    static func apiOperations(_ contracts: LiveContractStore, _ projects: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "api_operations",
            description: "Returns the operations of the project's OpenAPI contract, openapi/contract.yaml, with its $ref pointers resolved: key (METHOD and path, what api_call takes), operationId, summary, description, tags, parameters, the request body's media types with their example, and the documented responses.",
            inputSchema: .object(properties: [("projectID", projectID)], required: ["projectID"]),
            permission: .read,
            describe: { arguments in
                let id = (arguments["projectID"]?.stringValue ?? "").uppercased()
                return ToolCallText(action: String(localized: "Read the contract of \(id)", bundle: #bundle),
                                    item: ToolItem(tool: "contracts", projectID: id, focus: "", title: id))
            }
        ) { @MainActor arguments throws(ToolError) in
            let document = try await document(contracts, projects, arguments)
            return ["title": .string(document.title), "version": .string(document.version), "operations": .array(document.operations.map { operation in
                var object: [String: JSONValue] = [
                    "key": .string(operation.key), "summary": .string(operation.summary), "description": .string(operation.description),
                    "tags": .array(operation.tags.map(JSONValue.string)),
                    "parameters": .array(operation.parameters.map { parameter in
                        ["name": .string(parameter.name), "in": .string(parameter.location.rawValue), "required": .bool(parameter.isRequired),
                         "type": .string(parameter.type), "description": .string(parameter.description)]
                    }),
                    "responses": .array(operation.responses.map { ["code": .string($0.code), "description": .string($0.description)] }),
                ]
                if let id = operation.operationID { object["operationId"] = .string(id) }
                if let body = operation.requestBody {
                    object["requestBody"] = ["required": .bool(body.isRequired), "mediaTypes": .array(body.mediaTypes.map {
                        ["name": .string($0.name), "example": .string($0.example)]
                    })]
                }
                return .object(object)
            })]
        }
    }

    @MainActor
    static func apiCall(_ contracts: LiveContractStore, _ projects: ProjectSession) -> ToolOperation {
        ToolOperation(
            name: "api_call",
            description: "Sends the request of one operation of the project's contract to one of its environments, as the Contracts window sends it, with the credentials and headers stored for the contract on this Mac. Returns the status, the headers, the body (text, at most 100000 characters) and the duration.",
            inputSchema: .object(properties: [
                ("projectID", projectID),
                ("operation", .string("The operation's key from api_operations: its method and path, such as GET /orders/{id}.")),
                ("environment", .string("An environment of the project; without it, the project's current environment.")),
                ("parameters", .map("Parameter values by name, or by in:name when two share a name.", of: .string())),
                ("body", .string("The request body, as text.")),
                ("mediaType", .string("The body's media type; without it, the first the operation takes.")),
                ("headers", .map("Headers to add, by name; each replaces a header of the same name.", of: .string())),
            ], required: ["projectID", "operation"]),
            permission: .callAPIs,
            describe: { arguments in
                let id = (arguments["projectID"]?.stringValue ?? "").uppercased()
                let key = arguments["operation"]?.stringValue ?? ""
                let environment = arguments["environment"]?.stringValue
                return ToolCallText(action: String(localized: "Called \(key) of \(id)", bundle: #bundle),
                                    request: environment.map { String(localized: "Claude wants to call \(key) of \(id) on \($0)", bundle: #bundle) }
                                        ?? String(localized: "Claude wants to call \(key) of \(id)", bundle: #bundle),
                                    preview: arguments["body"]?.stringValue,
                                    item: ToolItem(tool: "contracts", projectID: id, focus: "", title: key))
            }
        ) { @MainActor arguments throws(ToolError) in
            let document = try await document(contracts, projects, arguments)
            let key = try arguments.string("operation")
            guard let operation = document.operation(key: key) else { throw ToolError(.notFound, "Operation \(key) not found in the contract.") }
            let id = try arguments.string("projectID").uppercased()
            guard let project = projects.snapshot.project(id) else { throw ToolError(.notFound, "Project \(id) not found.") }
            let name = arguments["environment"]?.stringValue ?? project.resolved.currentEnvironment
            guard let entry = project.resolved.environments.first(where: { $0.name == name }) else {
                throw ToolError(.notFound, "Environment \(name ?? "") not found in project \(id).")
            }
            var parameters: [String: String] = [:]
            for (given, value) in arguments["parameters"]?.objectValue ?? [:] {
                guard let text = value.stringValue else { continue }
                if given.contains(":") {
                    parameters[given] = text
                } else if let parameter = operation.parameters.first(where: { $0.name == given }) {
                    parameters[RequestValues.key(parameter)] = text
                }
            }
            var values = contracts.values(parameters: parameters, body: arguments["body"]?.stringValue ?? "",
                                          mediaType: arguments["mediaType"]?.stringValue ?? operation.requestBody?.mediaTypes.first?.name,
                                          projectID: id)
            for (name, value) in (arguments["headers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                values.headers.append((name, value.stringValue ?? ""))
            }
            let response: ContractResponse
            do throws(ContractSendError) {
                response = try await contracts.call(document, operation, values: values, name: entry.name, base: entry.baseURL,
                                                    allowsInvalidCertificates: entry.allowInvalidCertificates)
            } catch {
                throw ToolError(.unavailable, "The request failed: \(error.message)")
            }
            // Off the main actor, as the window's Send: a large answer takes time to read.
            let body = await Task.detached { () -> String in
                let text = response.text ?? "Binary body (\(response.body.count) bytes)"
                let count = text.count
                return count > 100_000 ? String(text.prefix(100_000)) + "… [truncated \(count - 100_000) characters]" : text
            }.value
            return ["status": .int(response.status), "headers": .array(response.headers.map(JSONValue.string)), "body": .string(body),
                    "durationMs": .int(response.durationMs)]
        }
    }
}
