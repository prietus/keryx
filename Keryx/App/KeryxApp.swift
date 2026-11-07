import SwiftUI

@main
struct KeryxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Keryx", id: "main") {
            RootView()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    model.preferences.applyAppearance()
                    model.updateBadge()
                }
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands { KeryxCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct KeryxCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Network…") { model.editingNetwork = NetworkConfig() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Conversation") { model.showFind = true }
                .keyboardShortcut("f")
            Button("Search All History") { model.showGlobalSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Mentions") { model.showMentions = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandMenu("Conversation") {
            Button("Go To…") { model.showPalette.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Previous") { model.selectAdjacent(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next") { model.selectAdjacent(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Next Unread") { model.selectAdjacent(1, unreadOnly: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            Divider()
            Button("Mark All as Read") {
                for session in model.orderedSessions { for buffer in session.buffers { session.markRead(buffer) } }
                model.updateBadge()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Close Conversation") {
                if let session = model.selectedSession, let buffer = model.selectedBuffer, buffer.kind != .status {
                    model.close(buffer, in: session)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(model.showMembers ? String(localized: "Hide Cast") : String(localized: "Show Cast")) { model.showMembers.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Bigger Text") { model.preferences.bodySize = min(20, model.preferences.bodySize + 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.preferences.bodySize = max(12, model.preferences.bodySize - 1) }
                .keyboardShortcut("-")
            Button(model.preferences.privacyMode ? String(localized: "Turn Off Privacy Mode") : String(localized: "Privacy Mode")) {
                model.preferences.privacyMode.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Network Protocol") { model.showProtocolLog = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.quit() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
