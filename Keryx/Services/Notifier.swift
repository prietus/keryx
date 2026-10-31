import Foundation
import AppKit
@preconcurrency import UserNotifications

/// Local notifications for mentions, private messages, invites and buddies
/// coming online. Clicking one opens its conversation.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with (session, buffer) when a notification is clicked.
    var onOpen: ((UUID, UUID) -> Void)?
    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorized = granted
        }
    }

    func present(_ event: NotifiableEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.text
        content.sound = event.kind == .buddyOnline ? nil : .default
        content.threadIdentifier = event.bufferID.uuidString
        content.userInfo = ["session": event.sessionID.uuidString, "buffer": event.bufferID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        if event.kind != .buddyOnline { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Clears delivered notifications for a conversation once it's read.
    func clear(buffer: UUID) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.threadIdentifier == buffer.uuidString }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func setBadge(_ count: Int) {
        // AppModel starts before NSApplication exists (it's the App's @State);
        // RootView sets the badge again once the window is up.
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let s = (info["session"] as? String).flatMap(UUID.init(uuidString:)),
              let b = (info["buffer"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run {
            NSApp.activate()
            onOpen?(s, b)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
