import FileStorage
import Foundation
import Testing
@testable import ProjectData

@Suite("Project file")
struct ProjectFileTests {
    @Test("A file V2 wrote is written back byte for byte, the keys V3 doesn't use included")
    func completeFileRoundTrip() throws {
        let data = try fixture("project-complete.yml")
        let project = try YAMLCoding.decode(ProjectFile.self, from: data)
        #expect(project.id == "HEPH")
        #expect(project.type == .swiftApplication)
        #expect(project.color == "#34C759")
        #expect(project.subprojects == ["backend", "apps/ios"])
        #expect(project.keptV2Keys.keys == ["webTabs", "skills", "chatDefaults", "dashboardWidgets", "deletedChats", "commentAnswers"])
        #expect(String(decoding: try YAMLCoding.encodeData(project), as: UTF8.self) == String(decoding: data, as: UTF8.self))
    }

    @Test("Every example decodes, round-trips to an equal value, and keeps all its keys")
    func examples() throws {
        for name in ["project-complete.yml", "project-minimal.yml", "project-service.yml", "project-subproject.yml"] {
            let data = try fixture(name)
            let project = try YAMLCoding.decode(ProjectFile.self, from: data)
            let written = try YAMLCoding.encodeData(project)
            #expect(try YAMLCoding.decode(ProjectFile.self, from: written) == project, "\(name)")
            let source = String(decoding: data, as: UTF8.self)
            let output = String(decoding: written, as: UTF8.self)
            for line in source.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("-") {
                let key = line.prefix { $0 != ":" }
                #expect(output.contains("\n\(key):") || output.hasPrefix("\(key):"), "\(name): \(key)")
            }
        }
    }

    @Test("A minimal file takes the defaults, and V3 adds none of V2's other keys")
    func minimalFile() throws {
        let project = try YAMLCoding.decode(ProjectFile.self, from: fixture("project-minimal.yml"))
        #expect(project == ProjectFile(id: "WEB", name: "Website", created: ISODate.date(from: "2026-10-31T09:30:00Z")!))
        #expect(try YAMLCoding.encode(project) == """
        schema: 1
        id: WEB
        name: Website
        created: 2026-10-31T09:30:00Z
        type: none
        nextTicketNumber: 1
        nextBundleNumber: 1
        docsPath: docs
        useParentSettings: true
        subprojects: []
        environments: []
        environmentOverrides: {}

        """)
    }

    @Test("A service's environments, base URLs and Kubernetes keys")
    func serviceEnvironments() throws {
        let project = try YAMLCoding.decode(ProjectFile.self, from: fixture("project-service.yml"))
        #expect(project.type == .goService)
        #expect(project.graphEnabled)
        #expect(project.environments.map(\.name) == ["local", "staging"])
        #expect(project.environments.map(\.baseURL) == ["http://127.0.0.1:8080", "https://staging.example.com"])
        let staging = project.environments[1]
        #expect(staging.allowInvalidCertificates)
        #expect(staging.namespace == "orders")
        #expect(staging.jaeger == "tracing/jaeger")
        #expect(staging.argoCDApplication == "argocd/orders-staging")
        #expect(staging.kubeconfig == "~/.kube/staging.yaml")
        #expect(project.keptV2Keys.keys == ["dashboardWidgets", "dashboardGraphWindow"])
    }

    @Test("A sub project's changes to the environments it inherits")
    func overrides() throws {
        let worker = try YAMLCoding.decode(ProjectFile.self, from: fixture("project-subproject.yml"))
        let parent = try YAMLCoding.decode(ProjectFile.self, from: fixture("project-service.yml"))
        #expect(worker.environmentOverrides.keys.sorted() == ["local", "staging"])
        let local = worker.environmentOverrides["local"]!.applied(to: parent.environments[0])
        #expect(local.baseURL == "http://127.0.0.1:8081")
        let staging = worker.environmentOverrides["staging"]!.applied(to: parent.environments[1])
        #expect(staging.baseURL == "https://worker.staging.example.com")
        #expect(!staging.allowInvalidCertificates)
        #expect(staging.namespace == "orders")
        #expect(staging.deployment == "orders-worker")
        #expect(EnvironmentOverride().isEmpty)
    }

    @Test("V3's additions: a Library type and a tint for the color")
    func v3Extensions() throws {
        let text = "id: LIB\nname: Kit\ncreated: 2026-10-31T09:30:00Z\ntype: library\ncolor: accentSecondary\n"
        let project = try YAMLCoding.decode(ProjectFile.self, from: text)
        #expect(project.type == .library)
        #expect(project.color == "accentSecondary")
        #expect(try YAMLCoding.encode(project).contains("type: library\ncolor: accentSecondary\n"))
    }

    @Test("Values are read with V2's rules: color in uppercase, trimmed icon and keys, a GitHub page without its /")
    func readNormalization() throws {
        let text = """
        id: ORD
        name: Orders
        created: 2026-10-31T09:30:00Z
        color: '#34c759'
        icon: '  hammer '
        githubPage: ' https://github.com/example/orders/ '
        environments:
        - name: local
          url: ' '
          namespace: ' orders '
          context: old-context

        """
        let project = try YAMLCoding.decode(ProjectFile.self, from: text)
        #expect(project.color == "#34C759")
        #expect(project.icon == "hammer")
        #expect(project.githubPage == "https://github.com/example/orders")
        #expect(project.environments[0].url == nil)
        #expect(project.environments[0].namespace == "orders")
        #expect(project.environments[0].unknownKeys.keys == ["context"])
        #expect(try YAMLCoding.encode(project).contains("  kubeconfig: null\n  context: old-context\n"))
    }

    @Test("A file that breaks a read rule is invalid, with the key and the rule")
    func invalidFiles() {
        let cases: [(String, String)] = [
            ("id: orders\nname: A\ncreated: 2026-10-31T09:30:00Z\n", "id: \"orders\" is not a valid project identifier"),
            ("id: ORD\ncreated: 2026-10-31T09:30:00Z\n", "name: the required key is missing or null"),
            ("id: ORD\nname: A\n", "created: the required key is missing or null"),
            ("id: ORD\nname: A\ncreated: 2026-10-31T09:30:00Z\ncolor: red\n", "color: \"red\" is not a color of the form #RRGGBB, nor a tint"),
            ("id: ORD\nname: A\ncreated: 2026-10-31T09:30:00Z\ngithubPage: https://gitlab.com/a/b\n",
             "githubPage: \"https://gitlab.com/a/b\" is not a page of the form https://github.com/<owner>/<name>"),
            ("schema: 2\nid: ORD\nname: A\ncreated: 2026-10-31T09:30:00Z\n", "schema: schema 2 was written by a newer version"),
        ]
        for (text, reason) in cases {
            let error = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(ProjectFile.self, from: text) }
            #expect(error?.reason == reason)
        }
        let type = #expect(throws: FileFormatError.self) {
            try YAMLCoding.decode(ProjectFile.self, from: "id: ORD\nname: A\ncreated: 2026-10-31T09:30:00Z\ntype: rust\n")
        }
        #expect(type?.reason.hasPrefix("type: ") == true)
    }
}

@Suite("Registry and current environments")
struct DataFilesTests {
    @Test("The registry lists absolute paths in order; other entries aren't loaded")
    func registry() throws {
        let data = try fixture("registry.yml")
        let registry = try YAMLCoding.decode(RegistryFile.self, from: data)
        #expect(registry.projects == ["/Users/example/Developer/HephaestusV2", "/Users/example/Developer/Website"])
        #expect(try YAMLCoding.encodeData(registry) == data)
        let mixed = RegistryFile(projects: ["/a", "relative", "/b/", "/c/../d", "/e"])
        #expect(mixed.loadableEntries == ["/a", "/e"])
    }

    @Test("The current environments are written in identifier order")
    func currentEnvironments() throws {
        let data = try fixture("current-environments.yml")
        let file = try YAMLCoding.decode(CurrentEnvironmentsFile.self, from: data)
        #expect(file.projects == ["DEMO": "staging", "DEMOAPI": "local"])
        #expect(try YAMLCoding.encodeData(file) == data)
        let unsorted = CurrentEnvironmentsFile(projects: ["ZED": "a", "ALPHA": "b", "MID": "c"])
        #expect(try YAMLCoding.encode(unsorted) == "schema: 1\nprojects:\n  ALPHA: b\n  MID: c\n  ZED: a\n")
    }
}
