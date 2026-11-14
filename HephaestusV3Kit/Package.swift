// swift-tools-version: 6.2
import PackageDescription

// One target per tool. Tool targets depend only on ToolsFoundation and AZDesign, never on each
// other: a tool reaches another tool's window by sending a `Route`, which ToolsScenes opens.
let isolation: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let design: Target.Dependency = .product(name: "AZDesign", package: "AZDesign")
/// Fira Code, for the code views: logs, JSON bodies, consoles.
let code: Target.Dependency = .product(name: "AZDesignCode", package: "AZDesign")
/// Each target keeps its own String Catalog, filled by `scripts/sync-strings.sh`. Code looks its strings
/// up in its own bundle: `Text("…", bundle: #bundle)`, `String(localized: "…", bundle: #bundle)`.
let strings: [Resource] = [.process("Localizable.xcstrings")]

/// A tool's target: ToolsFoundation, AZDesign and its code font, its own strings, and the data target of its
/// own feature, once that feature has come over from V2.
func toolTarget(_ name: String, data: [Target.Dependency] = []) -> Target {
    .target(name: name, dependencies: ["ToolsFoundation", design, code] + data, resources: strings, swiftSettings: isolation)
}

/// A target's unit tests, in Swift Testing. The data targets' tests keep their targets' default isolation
/// (`settings: []`).
func testTarget(_ name: String, resources: [Resource]? = nil, settings: [SwiftSetting] = isolation) -> Target {
    .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], resources: resources, swiftSettings: settings)
}

/// YAML, approved by the owner: the format of the `.hephaestus/` files and of the app's data folder.
let yams: Target.Dependency = .product(name: "Yams", package: "Yams")

let package = Package(
    name: "HephaestusV3Kit",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "ToolsScenes", targets: ["ToolsScenes"]),
    ],
    dependencies: [
        // AZDesign by version, from its GitHub repo (workspace rule): bump the version to update it.
        .package(url: "git@github.com:Azavech/AZDesign.git", from: "0.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // Data, without UI: no SwiftUI, and nothing isolated to the main actor unless it says so.
        // Files: YAML in V2's layout, atomic writes, own writes, the folder lock, the Trash, file events.
        .target(name: "FileStorage", dependencies: [yams]),
        // Child processes: process groups and timeouts, the login shell's environment, git, ssh, kubectl.
        .target(name: "ExternalTools"),
        // The data folder, the import from HephaestusV2 and the project files.
        .target(name: "ProjectData", dependencies: ["FileStorage", "ExternalTools"]),
        // The MCP server: JSON-RPC over HTTP on 127.0.0.1, serving the tools' operations to Claude.
        .target(name: "MCPKit"),
        // Tickets and bundles: their files, rules and changes.
        .target(name: "TicketData", dependencies: ["FileStorage", "ProjectData"]),
        .target(name: "TextFormats", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),

        // Shared vocabulary: projects, tools, routes and the few components every tool uses.
        .target(name: "ToolsFoundation", dependencies: [design], resources: strings, swiftSettings: isolation),

        // The project selector: the Projects window, the switcher of every tool window, the menu bar panel.
        toolTarget("ProjectsKit", data: ["ProjectData", "ExternalTools", "MCPKit"]),

        // The tools. The Dashboard draws the grid and its edit mode; each tool provides the widgets of
        // its own data, and ToolsScenes hands them to it.
        toolTarget("DashboardsKit", data: ["ProjectData"]),
        toolTarget("TicketsKit", data: ["TicketData", "TextFormats", "MCPKit"]),
        toolTarget("ServiceMapKit"),
        toolTarget("ContractsKit"),
        toolTarget("BuildsKit"),
        toolTarget("MachinesKit"),
        // Claude as one more client of the tools: the Chat window and the panel beside each tool.
        toolTarget("ChatKit"),

        // The only target that knows every tool: scenes, menu commands and route handling.
        .target(
            name: "ToolsScenes",
            dependencies: [
                "ToolsFoundation", "ProjectData", "FileStorage", "MCPKit", "TicketData", "ProjectsKit",
                "DashboardsKit", "TicketsKit", "ServiceMapKit", "ContractsKit", "BuildsKit", "MachinesKit", "ChatKit",
                design,
            ],
            resources: strings,
            swiftSettings: isolation
        ),

        testTarget("FileStorage", settings: []),
        testTarget("ExternalTools", settings: []),
        testTarget("ProjectData", resources: [.copy("Fixtures")], settings: []),
        testTarget("MCPKit", settings: []),
        testTarget("TicketData", resources: [.copy("Fixtures")], settings: []),
        testTarget("TextFormats", resources: [.copy("Fixtures")], settings: []),
        testTarget("ToolsFoundation"),
        testTarget("ProjectsKit"),
        testTarget("DashboardsKit"),
        testTarget("TicketsKit"),
        testTarget("ServiceMapKit"),
        testTarget("ContractsKit"),
        testTarget("BuildsKit"),
        testTarget("MachinesKit"),
        testTarget("ChatKit"),
        testTarget("ToolsScenes"),
    ]
)
