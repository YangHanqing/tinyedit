import FinderSync
import SwiftUI

/// Settings ▸ General: whether Finder shows “New Text File with TinyEdit”. The switch is the system's (the
/// `TinyEditFinder` extension is off until the user turns it on there), so this shows its state and opens it.
/// The state is read again whenever the app becomes active, on the way back from System Settings.
struct FinderMenuSection: View {
    @State private var enabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Section {
            LabeledContent("Finder Menu") {
                if enabled {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.success)
                } else {
                    Text("Off").foregroundStyle(Color.textSecondary)
                }
            }
            Button(enabled ? "Turn Off in System Settings…" : "Turn On in System Settings…") {
                FIFinderSyncController.showExtensionManagementInterface()
            }
        } footer: {
            Text("Right-click empty space in a Finder window and choose New Text File with TinyEdit: a new tab opens, and saving it puts the file in that folder. Nothing is created until you save, and TinyEdit reads nothing in Finder.")
                .settingsFootnote()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = FIFinderSyncController.isExtensionEnabled
        }
    }
}
