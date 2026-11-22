import Foundation
import Testing
import UpdateData
@testable import ToolsScenes

/// The app side of updates: the restart alert's text, the texts of the About window and the Update item, and the
/// controller of an app that isn't in /Applications. No Updater starts, and no notification is posted.
@MainActor
@Suite("Updates")
struct UpdateTests {
    @Test("A quit asks with the restart alert's parts while something works; an idle app quits at once")
    func quitMessage() {
        #expect(QuitConfirmation.message(RunningWork()) == nil)
        #expect(QuitConfirmation.message(RunningWork(sheet: true)) == nil, "A sheet alone doesn't ask")
        #expect(QuitConfirmation.message(RunningWork(chats: 2)) == UpdateController.restartMessage(RunningWork(chats: 2)))
    }

    @Test("The restart alert says what the restart stops or loses, and nothing when the app is idle")
    func restartMessage() {
        #expect(UpdateController.restartMessage(RunningWork()) == "")
        #expect(UpdateController.restartMessage(RunningWork(sheet: true)) == "")
        #expect(UpdateController.restartMessage(RunningWork(chats: 1)) == "1 chat will be stopped.")
        #expect(UpdateController.restartMessage(RunningWork(chats: 2, machines: 1, drafts: true))
            == "2 chats will be stopped. 1 virtual machine will be stopped. Unsent drafts will be lost.")
        #expect(RunningWork().isIdle)
        #expect(!RunningWork(drafts: true).isIdle)
        #expect(!RunningWork(sheet: true).isIdle)
    }

    @Test("The texts of the update area, the Update item's tooltips and the version")
    func texts() {
        let update = AppVersion(version: "1.0.44", build: 80)
        #expect(UpdateTexts.aboutLine(AppVersion(version: "1.0.43", build: 78)) == "Version 1.0.43 (78)")
        #expect(UpdateTexts.line(.available(update)) == "v1.0.44(80) available")
        #expect(UpdateTexts.line(.noUpdate) == "No update available")
        #expect(UpdateTexts.line(.checking) == "Checking for updates…")
        #expect(UpdateTexts.line(.message("Nope.")) == "Nope.")
        #expect(UpdateTexts.tooltip(.available(update)) == "Update v1.0.44(80) available — click to install")
        #expect(UpdateTexts.tooltip(.downloading(update)) == "Downloading update v1.0.44(80)…")
        #expect(UpdateTexts.tooltip(.ready(update, restartsWhenIdle: true)) == "Update v1.0.44(80) ready — restarts when idle")
        #expect(UpdateTexts.tooltip(.ready(update, restartsWhenIdle: false)) == "Update v1.0.44(80) ready")
        #expect(UpdateSettingsView.intervalLabel(60) == "Every hour")
        #expect(UpdateSettingsView.intervalLabel(45) == "Every 45 minutes")
    }

    @Test("A test runner isn't /Applications/HephaestusV3.app: no Updater, the reason, no Update item")
    func notInstalled() {
        let controller = UpdateController(bundle: .main, environment: [:])
        controller.start(dataFolder: nil)
        #expect(!controller.isRunning)
        #expect(controller.unavailableReason != nil)
        #expect(controller.updateItem == nil)
        #expect(!controller.updateNowVisible)
        #expect(controller.aboutArea(notNowClicked: false).row == 1)
        controller.install()
        #expect(!controller.installChosen)
    }
}
