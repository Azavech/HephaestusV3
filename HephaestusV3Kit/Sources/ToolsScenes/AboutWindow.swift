import AppKit
import AZDesign
import SwiftUI
import UpdateData

/// Hephaestus V3 ▸ About Hephaestus V3, in place of the standard About panel: it opens the About window, or brings it
/// to front.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutMenuItem()
        }
    }
}

private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "About Hephaestus V3", bundle: #bundle, comment: "App menu item")) {
            openWindow(id: SceneID.about)
        }
    }
}

/// The About window (docs/ui/updates.md › About window): the icon, the name, the version and the update area,
/// centred, 360 points wide. Each time it appears, the app asks the Updater for a check.
struct AboutView: View {
    let controller: UpdateController
    /// Not Now hides the two buttons until the window closes.
    @State private var notNowClicked = false

    var body: some View {
        AboutContent(version: controller.appVersion, area: controller.aboutArea(notNowClicked: notNowClicked),
                     install: controller.install, notNow: { notNowClicked = true }, tryAgain: controller.tryAgain)
            .onAppear {
                notNowClicked = false
                controller.aboutWindowAppeared()
            }
    }
}

/// The About window's content, for any version and update area.
struct AboutContent: View {
    let version: AppVersion
    let area: UpdateArea
    var install: () -> Void = {}
    var notNow: () -> Void = {}
    var tryAgain: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "Hephaestus V3")
                .font(.title)
                .foregroundStyle(.textPrimary)
            Text(UpdateTexts.aboutLine(version))
                .textSelection(.enabled)
                .foregroundStyle(.textSecondary)
                .accessibilityIdentifier("about.version")
            VStack(spacing: 10) {
                UpdateLine(area: area)
                    .accessibilityIdentifier("about.update")
                switch area.controls {
                case .none:
                    EmptyView()
                case .tryAgain:
                    Button(String(localized: "Try Again", bundle: #bundle), action: tryAgain)
                        .accessibilityIdentifier("about.tryAgain")
                case .installOrNotNow:
                    HStack(spacing: 8) {
                        Button(String(localized: "Not Now", bundle: #bundle), action: notNow)
                            .accessibilityIdentifier("about.notNow")
                        Button(String(localized: "Install", bundle: #bundle, comment: "The About window's button that installs an update"), action: install)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("about.install")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The line of an update area, with its small progress indicator.
struct UpdateLine: View {
    let area: UpdateArea

    var body: some View {
        HStack(spacing: 6) {
            if area.showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(UpdateTexts.line(area.line))
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The update texts the windows show, in ToolsScenes' catalog; the Updater's own messages stay as it wrote them.
enum UpdateTexts {
    static func aboutLine(_ version: AppVersion) -> String {
        String(localized: "Version \(version.version) (\(String(version.build)))", bundle: #bundle,
               comment: "The About window's and Settings ▸ Updates' version: Version 1.0.43 (78)")
    }

    static func line(_ line: UpdateArea.Line) -> String {
        switch line {
        case .unavailable(let reason), .message(let reason):
            reason
        case .installing:
            String(localized: "Installing…", bundle: #bundle, comment: "An update installs")
        case .notResponding:
            String(localized: "The Updater isn't responding.", bundle: #bundle)
        case .checking:
            String(localized: "Checking for updates…", bundle: #bundle)
        case .noUpdate:
            String(localized: "No update available", bundle: #bundle)
        case .available(let version):
            String(localized: "\(version.display) available", bundle: #bundle, comment: "An update: v1.0.44(80) available")
        case .restartFailed:
            String(localized: "The Updater didn't answer; the update wasn't installed.", bundle: #bundle)
        }
    }

    static func tooltip(_ tooltip: UpdateItem.Tooltip) -> String {
        switch tooltip {
        case .available(let version):
            String(localized: "Update \(version.display) available — click to install", bundle: #bundle, comment: "The status bar's Update item")
        case .downloading(let version):
            String(localized: "Downloading update \(version.display)…", bundle: #bundle, comment: "The status bar's Update item")
        case .ready(let version, true):
            String(localized: "Update \(version.display) ready — restarts when idle", bundle: #bundle, comment: "The status bar's Update item")
        case .ready(let version, false):
            String(localized: "Update \(version.display) ready", bundle: #bundle, comment: "The status bar's Update item")
        }
    }
}

private let previewVersion = AppVersion(version: "1.0.43", build: 78)
private let previewUpdate = AppVersion(version: "1.0.44", build: 80)

#Preview("About, Update Available", traits: .sizeThatFitsLayout) {
    AboutContent(version: previewVersion,
                 area: UpdateArea.about(.init(status: UpdaterStatus(state: .ready, version: previewUpdate.version, build: previewUpdate.build))))
}

#Preview("About, Up to Date, Dark", traits: .sizeThatFitsLayout) {
    AboutContent(version: previewVersion, area: UpdateArea.about(.init(status: UpdaterStatus(state: .upToDate))))
        .preferredColorScheme(.dark)
}

#Preview("About, Checking", traits: .sizeThatFitsLayout) {
    AboutContent(version: previewVersion, area: UpdateArea.about(.init(awaitingCheck: true)))
}

#Preview("About, Error", traits: .sizeThatFitsLayout) {
    AboutContent(version: previewVersion,
                 area: UpdateArea.about(.init(status: UpdaterStatus(state: .error, message: UpdaterTexts.repositoryHidden(ReleaseFeed.repository)))))
}

#Preview("About, Development Build", traits: .sizeThatFitsLayout) {
    AboutContent(version: AppVersion(version: "1.0", build: 0), area: UpdateArea.about(.init(unavailableReason: UpdaterTexts.developmentBuild)))
}
