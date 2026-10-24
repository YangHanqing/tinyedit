import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Vertical stack order: title row, tab bar, banner, editor slot, status bar. The find card floats over the editor.
            // The tab ScrollView's backing view reaches up into the title-bar safe area; keep the title above it.
            TitleBar().zIndex(1)
            TabBar()
            ThemeDivider()
            BannerView()
            editorSlot
                .overlay(alignment: .bottom) { ToastView() }
                .overlay(alignment: .top) { CommandPalette() }
            ThemeDivider()
            StatusBar()
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 480, minHeight: 320)
        .background(Color.editorBackground)
        .navigationTitle(appState.selectedBuffer.map { $0.displayTitle + " — TinyEdit" } ?? "TinyEdit")
        .background(WindowAccessor())
        .sheet(item: Bindable(appState).translationInput) { input in
            TranslationView(input: input).environment(appState)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Collected first, so several pictures dropped together are read as one.
            let group = DispatchGroup()
            let urls = DroppedURLs()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { appState.dropFiles(urls.all, at: nil) }
            }
            return true
        }
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
                .frame(minWidth: 200)
            if appState.previewVisible {
                MarkdownPreview().frame(minWidth: 200)
            }
        }
    }
}

/// Reaches the NSWindow to disable AppKit restoration, to route the red button to "hide, keep state",
/// and to remember the size the user drags it to.
struct WindowAccessor: NSViewRepresentable {
    final class Coordinator: NSObject {
        @MainActor @objc func closeWindow(_ sender: Any?) {
            AppState.shared.hideWindow((sender as? NSButton)?.window)
        }

        @MainActor @objc func didEndLiveResize(_ note: Notification) {
            guard let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
            WindowSize.save(window.contentRect(forFrameRect: window.frame).size)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.isRestorable = false
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            let button = window.standardWindowButton(.closeButton)
            button?.target = context.coordinator
            button?.action = #selector(Coordinator.closeWindow(_:))
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didEndLiveResize(_:)),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
            AppState.shared.window = window
            #if DEBUG
            ScreenshotProfile.configure(window, state: AppState.shared)
            #endif
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// URLs from the window drop's item providers, which call back on arbitrary queues.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}
