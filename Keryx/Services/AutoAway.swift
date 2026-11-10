import AppKit
import CoreGraphics
import KeryxProtocol

/// Marks you away on every network while the screen is locked or asleep, or
/// after a while without touching the Mac, and back when you return. It only
/// undoes what it did: an /away of your own stays as you left it.
@MainActor
final class AutoAway {
    private let preferences: Preferences
    private let sessions: () -> [Session]
    private var locked = false
    /// Sessions Keryx marked away, not you.
    private(set) var marked: Set<UUID> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var ticker: Task<Void, Never>?

    init(preferences: Preferences, sessions: @escaping () -> [Session]) {
        self.preferences = preferences
        self.sessions = sessions
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        watch(distributed, "com.apple.screenIsLocked", locked: true)
        watch(distributed, "com.apple.screenIsUnlocked", locked: false)
        watch(workspace, NSWorkspace.screensDidSleepNotification.rawValue, locked: true)
        watch(workspace, NSWorkspace.screensDidWakeNotification.rawValue, locked: false)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.update()
            }
        }
    }

    private func watch(_ center: NotificationCenter, _ name: String, locked: Bool) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.locked = locked
                self?.update()
            }
        }
        observers.append((center, token))
    }

    /// Seconds since the last keystroke, click or mouse move anywhere.
    private static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private var shouldBeAway: Bool {
        guard preferences.autoAway else { return false }
        if locked { return true }
        let minutes = preferences.autoAwayMinutes
        return minutes > 0 && Self.idleSeconds >= TimeInterval(minutes * 60)
    }

    func update() { apply(away: shouldBeAway) }

    /// The reason to connect with (`draft/pre-away`) when you're away already.
    var reasonIfAway: String? { shouldBeAway ? reason : nil }

    private var reason: String {
        let custom = preferences.awayMessage.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? String(localized: "Away") : custom
    }

    /// Brings every connected session in line: away while you are, present
    /// again (where Keryx set it) once you're back. New connections catch up
    /// on the next pass.
    func apply(away: Bool) {
        for session in sessions() {
            guard session.status == .connected else {
                marked.remove(session.id)
                continue
            }
            // It connected already away on our say-so: ours to undo later.
            if session.connectedAway {
                session.connectedAway = false
                marked.insert(session.id)
            }
            if away {
                guard !session.isAway, !session.awayByUser, !marked.contains(session.id) else { continue }
                session.send(IRCMessage(command: "AWAY", parameters: [reason]))
                marked.insert(session.id)
            } else if marked.remove(session.id) != nil, !session.awayByUser {
                session.send(IRCMessage(command: "AWAY"))
            }
        }
    }
}
