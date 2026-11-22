import Foundation
import Testing
@testable import ContractData

/// A temporary project folder with a contract and a schema file it refers to.
private struct ContractFolder {
    let root: URL
    let file: URL

    init(_ contract: String, files: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ContractDataTests-\(UUID().uuidString)")
        file = root.appendingPathComponent("openapi/contract.yaml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contract.utf8).write(to: file)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    func read() throws -> OpenAPIContract {
        try OpenAPIContract.read(try String(contentsOf: file, encoding: .utf8), file: file, root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private let petStore = """
    openapi: 3.0.3
    info: {title: Pet Store, version: 1.2.0}
    security: [{bearerAuth: []}]
    paths:
      /pets/{petId}:
        parameters:
          - {name: petId, in: path, required: true, schema: {type: integer}}
          - {name: verbose, in: query, schema: {type: boolean}}
        post:
          operationId: updatePet
          tags: [pets]
          parameters:
            - {name: verbose, in: query, schema: {type: string}, example: brief}
            - {name: X-Trace, in: header, schema: {type: string}}
          requestBody:
            required: true
            content:
              application/json:
                schema: {$ref: 'schemas.yaml#/Pet'}
          responses:
            '200': {description: The pet}
            default: {$ref: '#/components/responses/Error'}
        get:
          summary: Info for a pet
          responses: {'200': {description: OK}}
    components:
      responses:
        Error: {description: Something failed}
      securitySchemes:
        bearerAuth: {type: http, scheme: bearer}
        key: {type: apiKey, name: X-API-Key, in: header}
        oauth: {type: oauth2, flows: {}}
    """

private let schemas = """
    Pet:
      type: object
      required: [name]
      properties:
        id: {type: integer, readOnly: true}
        name: {type: string, example: Rex}
        born: {type: string, format: date}
        tags: {type: array, items: {type: string}}
        owner: {$ref: '#/Owner'}
        missing: {$ref: '../outside.yaml#/X'}
    Owner:
      allOf:
        - {properties: {email: {type: string, format: email}}}
        - {properties: {score: {type: number, minimum: 1.5}}}
    """

@Suite("Contracts")
struct ContractTests {
    @Test("Operations in order, parameters merged, refs resolved across files, the schemes sent")
    func read() throws {
        let folder = try ContractFolder(petStore, files: ["openapi/schemas.yaml": schemas])
        defer { folder.remove() }
        let contract = try folder.read()
        #expect(contract.title == "Pet Store" && contract.version == "1.2.0" && contract.openapi == "3.0.3")
        #expect(contract.operations.map(\.key) == ["GET /pets/{petId}", "POST /pets/{petId}"], "get before post in a path")
        let update = try #require(contract.operation("updatePet"))
        #expect(update.parameters.map { "\($0.location.rawValue):\($0.name)" } == ["path:petId", "query:verbose", "header:X-Trace"])
        #expect(update.parameters[1].type == "string" && update.parameters[1].example == "brief", "The operation's parameter replaces the path's")
        #expect(update.parameters[0].isRequired && update.parameters[0].type == "integer")
        #expect(update.responses.map(\.code) == ["200", "default"] && update.responses[1].description == "Something failed")
        #expect(contract.securitySchemes.map(\.name) == ["bearerAuth", "key"])
        #expect(contract.schemes(for: update).map(\.name) == ["bearerAuth"])
        let body = try #require(update.requestBody?.mediaTypes.first)
        #expect(body.example == """
            {
              "name": "Rex",
              "born": "2024-01-01",
              "tags": [
                "string"
              ],
              "owner": {
                "email": "user@example.com",
                "score": 1.5
              }
            }
            """, "readOnly and refs outside the folder are left out; allOf objects merge")
    }

    @Test("A parameter from another file reads its schema's refs in that file; YAML merge keys add their members")
    func parameterFileAndMergeKeys() throws {
        let contract = """
            openapi: 3.0.3
            info: {title: Lists, version: '1'}
            x-errors: &errors
              '400': {description: Bad request}
              '500': {description: Failed}
            paths:
              /items:
                get:
                  operationId: listItems
                  parameters: [{$ref: 'parameters.yaml#/Limit'}]
                  responses:
                    <<: *errors
                    '200': {description: The items}
                    '500': {description: Overloaded}
            """
        let parameters = """
            Limit: {name: limit, in: query, schema: {$ref: '#/schemas/Limit'}}
            schemas:
              Limit: {type: integer, example: 20}
            """
        let folder = try ContractFolder(contract, files: ["openapi/parameters.yaml": parameters])
        defer { folder.remove() }
        let list = try #require(try folder.read().operation("listItems"))
        let limit = try #require(list.parameters.first)
        #expect(limit.name == "limit" && limit.type.contains("integer") && limit.example == "20")
        #expect(list.responses.map(\.code).sorted() == ["200", "400", "500"])
        #expect(list.responses.first { $0.code == "500" }?.description == "Overloaded", "A key that is set wins over the merged one")
    }

    @Test("A response's text: JSON pretty-printed up to 1 MB, larger JSON and other text as received, binary none")
    func responseText() {
        func response(_ data: Data) -> ContractResponse { ContractResponse(status: 200, headers: [], body: data, durationMs: 1) }
        #expect(response(Data(#"{"b":1,"a":[true,null]}"#.utf8)).text?.contains("\n") == true, "Pretty-printed")
        #expect(response(Data("name,count\npen,2".utf8)).text == "name,count\npen,2")
        let large = "[" + Array(repeating: "1", count: 600_000).joined(separator: ",") + "]"
        #expect(response(Data(large.utf8)).text == large, "Over the limit: as received")
        #expect(response(Data([0xFF, 0xFE, 0x00])).text == nil)
    }

    @Test("A file that isn't an OpenAPI 3 contract can't be read")
    func unreadable() throws {
        let swagger = try ContractFolder("swagger: '2.0'\ninfo: {title: Old}\n")
        defer { swagger.remove() }
        #expect(throws: ContractError.unreadable("The root has no openapi value starting with 3.")) { try swagger.read() }
        let list = try ContractFolder("- a\n- b\n")
        defer { list.remove() }
        #expect(throws: ContractError.unreadable("The root is not a mapping.")) { try list.read() }
    }

    @Test("api_call's lookup takes a key only: an operationId that reads like a GET doesn't name a POST")
    func lookupByKey() throws {
        let folder = try ContractFolder("openapi: 3.0.3\ninfo: {title: Pay, version: '1'}\npaths:\n  /refunds:\n    post: {operationId: GET refunds, responses: {'200': {description: ok}}}\n")
        defer { folder.remove() }
        let contract = try folder.read()
        #expect(contract.operation(key: "GET refunds") == nil)
        #expect(contract.operation(key: "POST /refunds")?.method == "post")
        #expect(contract.operation("GET refunds")?.key == "POST /refunds", "The windows still find an operation by its operationId")
    }

    @Test("Requests: path parameters encoded, query and API keys, headers in order, added headers replace")
    func request() throws {
        let folder = try ContractFolder(petStore, files: ["openapi/schemas.yaml": schemas])
        defer { folder.remove() }
        let contract = try folder.read()
        let update = try #require(contract.operation("POST /pets/{petId}"))
        var values = RequestValues(parameters: ["path:petId": "4 2/x", "query:verbose": "a&b", "header:X-Trace": "t1"], mediaType: "application/json",
                                   body: "{}", credentials: ["bearerAuth": ["token": "secret"], "key": ["value": "k"]],
                                   headers: [(name: "x-trace", value: "t2"), (name: " ", value: "ignored")])
        let schemes = contract.securitySchemes
        #expect(RequestBuilder.url(update, base: "https://api.example.com/v1/", values: values, schemes: schemes)
            == "https://api.example.com/v1/pets/4%202%2Fx?verbose=a%26b")
        let headers = RequestBuilder.headers(update, values: values, schemes: schemes, sendsBody: true)
        #expect(headers.map(\.0) == ["X-API-Key", "Authorization", "Content-Type", "x-trace"])
        #expect(headers[1].1 == "Bearer secret" && headers[3].1 == "t2")
        values.credentials = ["basic": ["username": "u", "password": "p"]]
        let request = try #require(RequestBuilder.request(update, base: "http://127.0.0.1:8080", values: values, schemes: []))
        #expect(request.httpMethod == "POST" && request.httpBody == Data("{}".utf8))
    }

    @Test("Form bodies, and JSON written in the contract's order")
    func values() throws {
        let value = try ContractValue.parse("b: 1.50\na: [true, null, \"x\\ny\"]\nc: {}\n")
        #expect(value.json(pretty: false) == #"{"b":1.50,"a":[true,null,"x\ny"],"c":{}}"#)
        #expect(ContractSamples.text(try ContractValue.parse("name: Rex & co\nage: 3\n"), mediaType: "application/x-www-form-urlencoded; charset=utf-8")
            == "name=Rex%20%26%20co&age=3")
        #expect(ContractSamples.text(.string("plain"), mediaType: "text/plain") == "plain")
    }

    @Test("Stored values: the file read and written back, mode 0600, earlier keys left out")
    func stored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StoredValues-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = folder.appendingPathComponent(StoredValuesFile.name)
        try Data("""
            {"contracts":[{"deviceID":"6F1C","projectID":"DEMO","path":"openapi/contract.yaml","environment":"old",
              "credentials":{"bearerAuth":{"token":"example-token"}},"headers":[{"name":"X-Tenant","value":"demo"}],
              "operations":{"GET /pets/{petId}":{"parameters":{"path:petId":"42"},"bodies":{}}}}]}
            """.utf8).write(to: mine)
        let contracts = StoredValuesFile.read(mine)
        #expect(contracts.count == 1 && contracts[0].credentials["bearerAuth"]?["token"] == "example-token")
        #expect(contracts[0].headers == [StoredHeader(name: "X-Tenant", value: "demo")] && contracts[0].deviceID == "6F1C")
        #expect(contracts[0].operations["GET /pets/{petId}"]?.parameters == ["path:petId": "42"])
        let written = folder.appendingPathComponent("written.json")
        try StoredValuesFile.write(contracts, to: written)
        let mode = try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!(try String(contentsOf: written, encoding: .utf8)).contains("environment"), "Earlier keys are left out")
        #expect(StoredValuesFile.read(written) == contracts)
    }
}
