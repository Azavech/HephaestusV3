import AppKit
import ChatData
import Foundation
import Observation
import ProjectData
import ToolsFoundation
import UserNotifications

/// Settings ▸ Notifications: the three toggles of `settings.yml`, on by default (docs/ui/navigation.md ›
/// Settings ▸ Notifications).
struct NotificationChoices: Hashable, Sendable {
    var needsYou = true
    var finished = true
    var aiSummary = true

    init(needsYou: Bool = true, finished: Bool = true, aiSummary: Bool = true) {
        self.needsYou = needsYou
        self.finished = finished
        self.aiSummary = aiSummary
    }

    init(_ settings: SettingsFile) {
        needsYou = settings.notifyNeedsYou ?? true
        finished = settings.notifyFinished ?? true
        aiSummary = settings.notifyAISummary ?? true
    }
}

/// The chats' notifications, the Dock's badge and its bounce (docs/ui/chat.md › Notifications): what the chat
/// session reports becomes a macOS notification, one per chat, that opens the chat when clicked.
@MainActor
final class ChatNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let chats: ChatSession
    private let choices: () -> NotificationChoices
    /// Nil under `HEPHAESTUS_DATA_DIR`: such a process shares the installed app's bundle id, so it neither asks
    /// for the permission nor posts.
    private let center: UNUserNotificationCenter?
    /// Opens the chat of a clicked notification.
    var open: ((Route) -> Void)?
    /// Each chat's latest event: a summary that ends after a newer event is dropped.
    private var generations: [String: Int] = [:]

    init(chats: ChatSession, posts: Bool, choices: @escaping () -> NotificationChoices) {
        self.chats = chats
        self.choices = choices
        center = posts ? UNUserNotificationCenter.current() : nil
        super.init()
    }

    /// Whether this process posts: not when `HEPHAESTUS_DATA_DIR` is set.
    static var posts: Bool {
        ProcessInfo.processInfo.environment[DataFolder.overrideVariable] == nil
    }

    /// The identifier of a chat's notification: a new one replaces the one before.
    static func identifier(of chatID: String) -> String {
        "chat/\(chatID)"
    }

    /// The title of a chat's notification: `ORD · Fix the totals`.
    static func title(project: String, chat: String) -> String {
        String(localized: "\(project) · \(chat)", bundle: #bundle, comment: "A chat notification's title: the project's identifier, then the chat's title")
    }

    /// Follows the chats: their events, the chats opened, the chats waiting for the Dock's badge. Asks once for
    /// the permission to post, again when it was given without the badge.
    func start() {
        chats.onEvent = { [weak self] event in self?.receive(event) }
        chats.onOpen = { [weak self] chatID in self?.remove(chatID) }
        followWaiting()
        guard let center else { return }
        center.delegate = self
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined || settings.badgeSetting == .notSupported {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    private func receive(_ event: ChatEvent) {
        let generation = generations[event.chatID, default: 0] + 1
        generations[event.chatID] = generation
        // The bounce and the badge come whatever the toggles say.
        if event.kind == .needsYou, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        // Nothing would be posted for the chat the key window shows: no summary runs for it either.
        guard center != nil, !(NSApp.isActive && chats.isInKeyWindow(event.chatID)) else { return }
        let choices = choices()
        guard event.kind == .needsYou ? choices.needsYou : choices.finished else { return }
        guard choices.aiSummary, event.summaryInput != nil else {
            post(event, body: event.detail)
            return
        }
        // Dropped when a newer event came, the chat went, or it no longer waits: checked before the summary runs, and
        // after.
        let wanted: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return generations[event.chatID] == generation && chats.chats[event.chatID] != nil
                && (event.kind == .finished || chats.waitingChats.contains(event.chatID))
        }
        Task {
            let line = await chats.summary(of: event, stillWanted: wanted)
            guard wanted() else { return }
            post(event, body: line)
        }
    }

    private func post(_ event: ChatEvent, body: String) {
        guard let center, !(NSApp.isActive && chats.isInKeyWindow(event.chatID)) else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.title(project: event.projectID, chat: chats.chats[event.chatID]?.file.title ?? event.title)
        content.body = body
        content.sound = .default
        content.userInfo = ["chatID": event.chatID, "projectID": event.projectID]
        let request = UNNotificationRequest(identifier: Self.identifier(of: event.chatID), content: content, trigger: nil)
        center.add(request) { _ in }
    }

    /// The chat's notification goes: a window opened the chat, or shows it as it becomes key.
    private func remove(_ chatID: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(of: chatID)])
    }

    /// Shows the number of waiting chats on the Dock's icon, nothing at 0, now and at each change.
    private func followWaiting() {
        withObservationTracking {
            let count = chats.waitingChats.count
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.followWaiting() }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A notification shows as a banner also while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click brings the app forward on the chat.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let chatID = info["chatID"] as? String, let projectID = info["projectID"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            open?(.tool(.chat, project: projectID, focus: chatID))
        }
    }
}
