import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Vertical stack order: title row, then the sidebar beside tab bar, banner, editor slot and status bar.
            // The find card floats over the editor.
            // The tab ScrollView's backing view reaches up into the title-bar safe area; keep the title above it.
            TitleBar().zIndex(1)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if appState.sidebarVisible && !appState.folders.isEmpty {
                        // Shown no wider than leaves the editor its minimum; the stored width is kept.
                        SidebarView()
                            .frame(width: SidebarLayout.shownWidth(stored: appState.sidebarWidth,
                                                                   windowWidth: geometry.size.width,
                                                                   editorMinWidth: appState.editorMinWidth))
                        // Above the editor, so the drag strip that lies over its leading edge takes the mouse.
                        SidebarDivider().zIndex(1)
                    }
                    VStack(spacing: 0) {
                        TabBar()
                        ThemeDivider()
                        BannerView()
                        editorSlot
                            .overlay(alignment: .bottom) { ToastView() }
                            .overlay(alignment: .top) { CommandPalette() }
                        ThemeDivider()
                        StatusBar()
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 480, minHeight: 320)
        .background(Color.editorBackground)
        .disabled(appState.transferring)
        .navigationTitle(windowTitle)
        .background(WindowAccessor(state: appState, title: windowTitle))
        .sheet(item: Bindable(appState).translationInput) { input in
            TranslationView(input: input).environment(appState)
        }
        .onDrop(of: [.fileURL, TabDrag.type], isTargeted: nil) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(TabDrag.type.identifier) }) {
                // A tab from another window, dropped anywhere but a tab bar, joins this window last.
                guard let dragged = TabDrag.current, Workspaces.shared.owner(ofTab: dragged) !== appState,
                      let id = TabDrag.take() else { return false }
                Task { await Workspaces.shared.moveTab(id, to: appState) }
                return true
            }
            // Collected first, so several pictures dropped together are read as one.
            loadFileURLs(providers) { appState.dropFiles($0, at: nil) }
            return true
        }
    }

    /// The Window menu, the Dock and Mission Control show it. A workspace leads with its first folder.
    private var windowTitle: String {
        let tab = appState.selectedBuffer?.displayTitle
        if let folder = appState.folders.first?.name {
            return tab.map { folder + " — " + $0 } ?? folder
        }
        return tab.map { $0 + " — TinyEdit" } ?? "TinyEdit"
    }

    /// One `EditorView` whether or not the preview shows. Two (one per `if` branch) share the host's one
    /// scroll view, and SwiftUI would update the outgoing one last with its old store: leaving a tab with the
    /// preview open would put the previous buffer back in the text view, and typing would go into it.
    private var editorSlot: some View {
        HSplitView {
            EditorView(host: appState.host,
                       store: appState.activeStore,
                       allStores: appState.allStores,
                       settings: appState.settings)
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        FindBar()
                        GoToLineCard()
                        SuggestionCard()
                    }
                }
                .frame(minWidth: SidebarLayout.paneMinWidth)
            if appState.previewVisible {
                MarkdownPreview().frame(minWidth: SidebarLayout.paneMinWidth)
            }
        }
    }
}

/// Reaches the NSWindow to disable AppKit restoration, to route the main window's red button to "hide, keep
/// state", to keep the window title (an AppKit-made window does not take `navigationTitle`), and to remember
/// the size the user drags it to.
struct WindowAccessor: NSViewRepresentable {
    let state: AppState
    let title: String

    final class Coordinator: NSObject {
        @MainActor @objc func closeWindow(_ sender: Any?) {
            Workspaces.shared.closeWindow((sender as? NSButton)?.window)
        }

        @MainActor @objc func didEndLiveResize(_ note: Notification) {
            guard let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
            WindowSize.save(window.contentRect(forFrameRect: window.frame).size)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let state = self.state
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.isRestorable = false
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            if state.isMain {
                // The other windows' delegate decides how they close.
                let button = window.standardWindowButton(.closeButton)
                button?.target = context.coordinator
                button?.action = #selector(Coordinator.closeWindow(_:))
            }
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didEndLiveResize(_:)),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
            state.window = window
            if window.title != title { window.title = title }
            #if DEBUG
            if state.isMain { ScreenshotProfile.configure(window, state: state) }
            #endif
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, window.title != title { window.title = title }
    }
}
