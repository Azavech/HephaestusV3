import FileStorage
import Foundation
import MemoryData
import Testing
import ToolsFoundation
@testable import MemoriesKit

/// docs/ui/memories.md: the tab's model on memory folders of a temporary folder.
@Suite("Memories")
struct MemoriesModelTests {
    let root: String
    let home: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MemoriesKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.path
        home = url.appendingPathComponent("home").path
    }

    func model(_ scope: MemoryScope = .global) -> MemoriesModel {
        let home = home
        let managed = root + "/managed"
        return MemoriesModel(directory: ProjectDirectory(projects: []),
                             locations: { MemoryLocations(home: home, environment: [:], managedFolder: managed) },
                             trash: .folder(URL(fileURLWithPath: root + "/Trash")), saveDelay: .zero, scope: scope)
    }

    func write(_ relative: String, _ text: String) throws {
        let path = home + "/.claude/memory/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOfFile: home + "/.claude/memory/" + relative, encoding: .utf8)
    }

    @Test("Empty, then a new memory is listed under its type and shown in Edit")
    @MainActor func create() throws {
        let model = model()
        model.reload()
        #expect(model.isEmpty)
        try model.create(name: "go-style", description: "How the user writes Go", type: .feedback)
        #expect(!model.isEmpty)
        #expect(model.memories(of: .feedback).map(\.name) == ["go-style"])
        #expect(model.selection == .memory("go-style.md"))
        #expect(model.bodyMode == .edit)
        #expect(read("MEMORY.md") == "- [go-style](go-style.md) — How the user writes Go\n")
        #expect(model.showsIndexRow)
    }

    @Test("The body and the type are saved by themselves; the name renames the file on commit")
    @MainActor func editing() throws {
        try write("role.md", "---\nname: role\ndescription: r\nmetadata:\n  type: user\n---\nOld\n")
        let model = model()
        model.reload()
        model.select(row: .memory("role.md"))
        model.draft.body = "New\n"
        #expect(model.hasUnsavedChanges)
        model.saveNow()
        #expect(read("role.md")?.hasSuffix("---\nNew\n") == true)
        model.setType(.reference)
        #expect(read("role.md")?.contains("type: reference") == true)
        model.draft.name = "Bad Name"
        model.commitName()
        #expect(model.nameMessage == "Use 1–64 lowercase letters, digits and single hyphens.")
        model.draft.name = "job"
        model.commitName()
        #expect(model.nameMessage == nil)
        #expect(model.selection == .memory("job.md"))
        #expect(read("job.md")?.hasPrefix("---\nname: job\n") == true)
        #expect(model.memories(of: .reference).map(\.file) == ["job.md"])
    }

    @Test("The filter keeps names and descriptions; Move to Trash removes the memory and its line")
    @MainActor func filterAndDelete() throws {
        try write("a.md", "---\nname: alpha\ndescription: first one\n---\n")
        try write("b.md", "---\nname: beta\ndescription: second\n---\n")
        try write("MEMORY.md", "- [alpha](a.md) — first\n- [beta](b.md) — second\n")
        let model = model()
        model.reload()
        model.filter = "FIRST"
        #expect(model.memories(of: .other).map(\.name) == ["alpha"])
        #expect(!model.showsIndexRow)
        model.filter = ""
        model.select(row: .memory("a.md"))
        #expect(model.deletableFile == "a.md")
        try model.delete("a.md")
        #expect(model.selection == nil)
        #expect(read("a.md") == nil)
        #expect(read("MEMORY.md") == "- [beta](b.md) — second\n")
    }

    @Test("MEMORY.md is edited whole")
    @MainActor func index() throws {
        try write("MEMORY.md", "- old\n")
        let model = model()
        model.reload()
        model.select(row: .index)
        #expect(model.draft.body == "- old\n")
        model.draft.body = "- new\n"
        model.saveNow()
        #expect(read("MEMORY.md") == "- new\n")
    }

    @Test("A scope is read from a route's focus")
    func scope() {
        #expect(MemoryScope(focus: "global") == .global)
        #expect(MemoryScope(focus: nil) == .global)
        #expect(MemoryScope(focus: "ORD") == .project("ORD"))
        #expect(MemoryScope.project("ORD").focus == "ORD")
    }
}
