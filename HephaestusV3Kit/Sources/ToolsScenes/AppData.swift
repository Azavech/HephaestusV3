import AppKit
import ExternalTools
import Observation
import ProjectData
import ProjectsKit
import ToolsFoundation

/// The app's data, shared by every window: the project session, and the directory the windows read, kept
/// in step with it.
@MainActor @Observable
final class AppData {
    /// The tools whose feature has come over from HephaestusV2; the others are hidden in the running app
    /// (docs/ui/navigation.md › Available tools). Previews show every tool.
    static let availableTools: Set<ToolKind> = []
    /// Whether the Virtual Machines window has come over.
    static let machinesAvailable = false

    let session: ProjectSession
    let directory = ProjectDirectory(projects: [], state: .loading)
    @ObservationIgnored private var started = false

    init() {
        session = ProjectSession(dataFolder: DataFolder.resolve())
    }

    /// Starts the session once, whichever window appears first, and stops it as the app quits.
    func start() async {
        guard !started else { return }
        started = true
        follow()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // The tools started for the projects end with the app; the lock goes with the process.
            SystemProcessRunner.shared.terminateAll()
        }
        await session.start()
    }

    /// Updates the directory now, and again each time what it reads of the session changes.
    private func follow() {
        withObservationTracking {
            directory.update(from: session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}
