// swift-tools-version: 6.2
import PackageDescription

// The guest agent's code, for macOS 12 guests and later: the app's HephaestusAgent target links it and the app
// bundles the program in Contents/Helpers (docs/guest-agent.md).
let package = Package(
    name: "GuestAgent",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "GuestAgentKit", targets: ["GuestAgentKit"]),
    ],
    targets: [
        .target(name: "GuestAgentKit"),
        .testTarget(name: "GuestAgentKitTests", dependencies: ["GuestAgentKit"]),
    ]
)
