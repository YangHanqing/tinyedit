import SwiftUI

/// The title-bar row of the hidden-title-bar window: the traffic lights sit over its leading edge.
/// Reads only the selected buffer's metadata (language, directory, preview flag), never per-keystroke state.
struct TitleBar: View {
    @Environment(AppState.self) private var appState

    /// Clearance for the traffic lights and the sidebar button; mirrored on the trailing side so the title stays centered.
    private static let sideInset: CGFloat = 108
    /// Where the sidebar button starts: just past the traffic lights.
    private static let sidebarButtonInset: CGFloat = 74

    var body: some View {
        let buffer = appState.selectedBuffer
        ZStack(alignment: .trailing) {
            TitleBarDragArea()
            title(buffer)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.sideInset)
                .allowsHitTesting(false)   // clicks on the title reach the drag area beneath
            HStack {
                TitleBarButton(symbol: "sidebar.left", help: String(localized: "Sidebar (⌃⌘S)"),
                               active: appState.sidebarVisible) { appState.toggleSidebar() }
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.sidebarButtonInset)
            HStack(spacing: 2) {
                if buffer?.language == .markdown {
                    TitleBarButton(symbol: appState.previewVisible ? "eye.fill" : "eye",
                                   help: String(localized: "Markdown Preview (⇧⌘V)"),
                                   active: appState.previewVisible) { appState.togglePreview() }
                }
                TitleBarButton(symbol: "command", help: String(localized: "Command Palette (⇧⌘P)"), active: false) {
                    appState.togglePalette()
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 32)   // the title-bar height, so the text centers on the traffic lights
        .background(Color.chromeBackground)
    }

    /// Icon and file name, then the parent directory in a weaker color. The directory gives up width
    /// first and truncates in the middle; Untitled shows the app name and no path.
    @ViewBuilder private func title(_ buffer: EditorBuffer?) -> some View {
        let directory = buffer?.directoryPath
        let name = buffer.flatMap { $0.isUntitled ? nil : ($0.fileDisplayName ?? $0.title) } ?? "TinyEdit"
        HStack(spacing: 6) {
            Image(nsImage: NSImage(named: appState.settings.appIcon.imageName) ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .layoutPriority(1)
            if let directory, buffer?.isUntitled == false {
                Text(TitlePathFormatting.abbreviate(directory: directory, home: TitlePathFormatting.userHome))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .toolTip(directory.map { TitlePathFormatting.filePath(directory: $0, filename: name) } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Borderless icon button with a hover background, like the tab bar's buttons.
private struct TitleBarButton: View {
    let symbol: String
    let help: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.accent : Color.textSecondary)
                .frame(width: 28, height: 22)
                .background(hovering ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
    }
}

/// The blank title-bar space. The SwiftUI row covers AppKit's hidden title bar, and a view that lets
/// mouse-downs move the window only gets a background drag, never the title bar's double-click. So this
/// view takes the mouse-down itself: a click drags the window, a double-click does the system's
/// "Double-click a window's title bar to" action.
private struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                Self.performDoubleClickAction(window)
            } else {
                window.performDrag(with: event)
            }
        }

        /// AppKit registers "Maximize" as the default. "Fill" (macOS 15 and later) has no public API,
        /// so it zooms too.
        private static func performDoubleClickAction(_ window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}
