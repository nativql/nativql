import SwiftUI

@main
struct NativQLApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
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
    }
}
