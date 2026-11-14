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

/// A tool's target: ToolsFoundation, AZDesign and its code font, its own strings.
func toolTarget(_ name: String) -> Target {
    .target(name: name, dependencies: ["ToolsFoundation", design, code], resources: strings, swiftSettings: isolation)
}

/// A target's unit tests, in Swift Testing.
func testTarget(_ name: String) -> Target {
    .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], swiftSettings: isolation)
}

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
        .package(path: "../../../Libraries/AZDesign"),
    ],
    targets: [
        // Shared vocabulary: projects, tools, routes and the few components every tool uses.
        .target(name: "ToolsFoundation", dependencies: [design], resources: strings, swiftSettings: isolation),

        // The project selector: the Projects window, the switcher of every tool window, the menu bar panel.
        toolTarget("ProjectsKit"),

        // The tools. The Dashboard draws the grid and its edit mode; each tool provides the widgets of
        // its own data, and ToolsScenes hands them to it.
        toolTarget("DashboardsKit"),
        toolTarget("TicketsKit"),
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
                "ToolsFoundation", "ProjectsKit",
                "DashboardsKit", "TicketsKit", "ServiceMapKit", "ContractsKit", "BuildsKit", "MachinesKit", "ChatKit",
                design,
            ],
            resources: strings,
            swiftSettings: isolation
        ),

        testTarget("ToolsFoundation"),
        testTarget("ProjectsKit"),
        testTarget("DashboardsKit"),
        testTarget("TicketsKit"),
        testTarget("ServiceMapKit"),
        testTarget("ContractsKit"),
        testTarget("BuildsKit"),
        testTarget("MachinesKit"),
        testTarget("ChatKit"),
    ]
)
