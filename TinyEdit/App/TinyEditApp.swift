import SwiftUI

@main
struct TinyEditApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

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
        .restorationBehavior(.disabled)
        .defaultSize(WindowSize.load(visible: NSScreen.main?.visibleFrame.size))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
