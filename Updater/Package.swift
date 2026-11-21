// swift-tools-version: 6.2
import PackageDescription

// The Updater's code (docs/updater.md): the HephaestusUpdater helper of the app links it, and so does HephaestusV3Kit's
// ToolsScenes, for the app's side. A package of its own, as GuestAgent is, so that HephaestusV3Kit keeps its one
// product and its HephaestusV3Kit scheme. No dependency, no default isolation.
let package = Package(
    name: "Updater",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "UpdateData", targets: ["UpdateData"]),
    ],
    targets: [
        // GitHub's latest release, its release.json and disk image, their checks, the install, and the Updater's
        // process and notifications.
        .target(name: "UpdateData"),
        .testTarget(name: "UpdateDataTests", dependencies: ["UpdateData"]),
    ]
)
