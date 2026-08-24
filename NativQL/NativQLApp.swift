import SwiftUI

extension Notification.Name {
    static let openShortcutsHelp = Notification.Name("dev.nativql.openShortcutsHelp")
}

@main
struct NativQLApp: App {
    @State private var appState = AppState()
    @State private var settings = SettingsStore()
    @State private var toastCenter = ToastCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(settings)
                .environment(toastCenter)
                .frame(minWidth: 980, minHeight: 620)
                // Fires on Cmd+Q and on last-window-close termination; tears
                // down live drivers before the process exits.
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    Task { await appState.disconnectAllIfNeeded() }
                }
        }
        .windowResizability(.contentMinSize)
        .modelContainer(NativQLModelContainer.shared())
        .commands {
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts…") {
                    NotificationCenter.default.post(name: .openShortcutsHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        Window("Keyboard Shortcuts", id: "shortcuts-help") {
            ShortcutsHelpView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
