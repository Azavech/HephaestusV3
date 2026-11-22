import AppKit

/// The app's delegate, for what the scenes can't say: whether a quit goes on (docs/ui/navigation.md › Quitting).
@MainActor
public final class HephaestusAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's data starts with the app, not with its first window: relaunched in the background by an update's
    /// restart with no window restored, it ran without its MCP server, its Updater or its chats until a window opened.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppData.shared.start() }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitConfirmation.confirm() ? .terminateNow : .terminateCancel
    }
}

/// A quit while chats or virtual machines work, or drafts wait, asks first, as V2's did; the parts are the
/// update restart's.
@MainActor
enum QuitConfirmation {
    /// The app's work, given by `AppData` once it starts.
    static var runningWork: () -> RunningWork = { RunningWork() }
    /// The update's restart asked already, or didn't need to: its quit goes on.
    static var confirmed = false

    /// True to quit: at once when nothing works, else after Quit in `Quit Hephaestus V3?`.
    static func confirm() -> Bool {
        guard !confirmed, let message = message(runningWork()) else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Hephaestus V3?", bundle: #bundle,
                                   comment: "The alert when quitting while chats or virtual machines work")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Quit", bundle: #bundle, comment: "The button that quits the app anyway"))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: #bundle))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What the alert says, or nil when the quit needs no question.
    static func message(_ work: RunningWork) -> String? {
        let message = UpdateController.restartMessage(work)
        return message.isEmpty ? nil : message
    }
}
