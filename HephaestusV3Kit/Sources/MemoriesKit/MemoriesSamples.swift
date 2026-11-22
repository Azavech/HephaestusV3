import FileStorage
import Foundation
import MemoryData
import SwiftUI
import ToolsFoundation

/// Memories for the previews: a home folder of their own under the temporary folder, with global memories, and
/// memories for the sample projects Orders and Shop, whose folder Orders inherits.
@MainActor
enum MemoriesSamples {
    static func model(scope: MemoryScope = .global, row: MemoryRow? = nil, mode: MemoryBodyMode = .preview) -> MemoriesModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HephaestusV3-MemoriesPreview-\(UUID().uuidString)").path
        let locations = MemoryLocations(home: home, environment: [:], managedFolder: home + "/managed")
        write(locations.globalFolder, [
            "MEMORY.md": """
                - [user-role](user-role.md) — The user builds macOS apps and Go services
                - [go-style](go-style.md) — Wrap errors with context; no panics in services
                - [commit-messages](commit-messages.md) — What changed and why, in the present tense
                - [release-steps](release-steps.md) — How a release is cut

                """,
            "user-role.md": memory("user-role", "The user builds macOS apps and Go services", "user",
                                   "Writes SwiftUI daily; asks for Go explanations in terms of Swift.\n"),
            "go-style.md": memory("go-style", "Wrap errors with context; no panics in services", "feedback", """
                Wrap every error with what was being done: `fmt.Errorf("load order %s: %w", id, err)`.

                **Why:** the logs of a service are read without its code at hand.

                **How to apply:** in every Go service; `panic` only in `main`, for a configuration that can't work.

                """),
            "commit-messages.md": memory("commit-messages", "What changed and why, in the present tense", "feedback",
                                         "One line of what changed, then why, as the user writes them.\n"),
            "release-steps.md": memory("release-steps", "How a release is cut", "reference",
                                       "Tag on main, let CI build and notarize, then check the update arrives.\n"),
        ])
        let directory = ProjectDirectory.previewSamples
        if let orders = directory.project("ORD"), let shop = directory.project("SHOP") {
            write(locations.projectFolder(root: orders.path), [
                "MEMORY.md": "- [orders-schema](orders-schema.md) — Items live in their own table\n",
                "orders-schema.md": memory("orders-schema", "Items live in their own table", "project",
                                           "An order's items are rows of `order_items`, never a JSON column.\n"),
            ])
            write(locations.projectFolder(root: shop.path), [
                "MEMORY.md": "- [shop-environments](shop-environments.md) — Staging and production clusters\n",
                "shop-environments.md": memory("shop-environments", "Staging and production clusters", "reference",
                                               "Staging runs on staging-eu, production on prod-eu, both in the namespace shop.\n"),
            ])
        }
        let model = MemoriesModel(directory: directory, locations: { locations }, trash: .folder(URL(fileURLWithPath: home + "/Trash")),
                                  scope: scope)
        model.reload()
        model.bodyMode = mode
        model.select(row: row)
        return model
    }

    private static func memory(_ name: String, _ description: String, _ type: String, _ body: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\nmetadata:\n  type: \(type)\n---\n\n" + body
    }

    private static func write(_ folder: String, _ files: [String: String]) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
        }
    }
}

#Preview("Global, a Memory", traits: .fixedLayout(width: 1100, height: 640)) {
    MemoriesView(model: MemoriesSamples.model(row: .memory("go-style.md")))
}

#Preview("Orders, Inherited", traits: .fixedLayout(width: 1100, height: 640)) {
    MemoriesView(model: MemoriesSamples.model(scope: .project("ORD"), row: .inherited(projectID: "SHOP", file: "shop-environments.md")))
}

#Preview("Global, Edit", traits: .fixedLayout(width: 1100, height: 640)) {
    MemoriesView(model: MemoriesSamples.model(row: .memory("go-style.md"), mode: .split))
        .preferredColorScheme(.dark)
}
