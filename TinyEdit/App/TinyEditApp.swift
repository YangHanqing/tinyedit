import SwiftUI

@main
struct TinyEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // No system window restoration (the session restores tabs); together with `isRestorable = false` on
        // every editor window. Works on macOS 14, where SwiftUI's `restorationBehavior` does not exist.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        // The main window. Other editor windows are AppKit windows made by `Workspaces`.
        Window("TinyEdit", id: "main") {
            RootView()
                .environment(appState)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await appState.checkSelectedFileForExternalChanges() }
                    } else {
                        appState.flushImmediately()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(WindowSize.load(visible: NSScreen.main?.visibleFrame.size))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
