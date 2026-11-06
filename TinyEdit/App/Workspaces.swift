import AppKit
import Observation
import SwiftUI

/// Every editor window and the state behind it. The main window is `AppState.shared`: the app's original
/// session, hidden (never closed) by the red button. Each other window is a workspace with a session of its
/// own under `Workspaces/<id>/`, opened by New Window, by opening a folder, or by dragging a tab out; it is
/// restored at launch and closed for good by the red button. A file is open in one window at a time.
@MainActor
@Observable
final class Workspaces {
    static let shared = Workspaces()

    /// The other windows, oldest first.
    private(set) var windows: [AppState] = []
    /// The window the menus act on: the last editor window that was key.
    private(set) var active: AppState

    @ObservationIgnored private var controllers: [UUID: WorkspaceWindowController] = [:]
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored private var pendingURLs: [URL] = []

    private init() { active = AppState.shared }

    var main: AppState { AppState.shared }
    var all: [AppState] { [main] + windows }

    var directory: URL { main.root.appendingPathComponent("Workspaces", isDirectory: true) }

    func state(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        return all.first { $0.window === window }
    }

    /// The state for a menu command: the key window's, else the last active one.
    var target: AppState { state(for: NSApp.keyWindow) ?? active }

    // MARK: Launch

    /// `applicationDidFinishLaunching`: follow the key window, restore the windows of the last session,
    /// then open what Finder or the command line sent before.
    func start() {
        guard !started else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let state = Workspaces.shared.state(for: window) else { return }
                Workspaces.shared.activate(state)
            }
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { restoreWindows() }
        started = true
        let queued = pendingURLs
        pendingURLs = []
        if !queued.isEmpty { openURLs(queued) }
    }

    private func activate(_ state: AppState) {
        if active !== state { active = state }
        let recents = NSDocumentController.shared.recentDocumentURLs
        if state.recentURLs != recents { state.recentURLs = recents }
    }

    private func restoreWindows() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let saved = entries.compactMap { url -> (UUID, URL, WorkspaceFile?)? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return (id, url, WorkspaceFile.read(in: url))
        }
        .sorted { ($0.2?.createdAt ?? .distantPast) < ($1.2?.createdAt ?? .distantPast) }
        for (id, root, file) in saved {
            let state = AppState(root: root, workspaceID: id)
            windows.append(state)
            let controller = WorkspaceWindowController(state: state)
            controllers[id] = controller
            controller.show(frame: file?.frame, topLeft: nil, makeKey: false)
        }
    }

    // MARK: New windows

    /// An empty window: one Untitled tab and the sidebar asking for a folder. `topLeft` is in screen coordinates.
    @discardableResult
    func newWindow(topLeft: NSPoint? = nil) -> AppState {
        let id = UUID()
        let root = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(root: root, workspaceID: id)
        windows.append(state)
        let controller = WorkspaceWindowController(state: state)
        controllers[id] = controller
        controller.show(frame: nil, topLeft: topLeft, cascadeFrom: (NSApp.keyWindow ?? active.window), makeKey: true)
        Task { await state.restoreTask?.value; state.saveWorkspace() }
        return state
    }

    /// A folder opens in its own window: the one that already shows it, else an empty window it was asked
    /// from (not the main one), else a new window.
    func openFolder(_ url: URL, from requester: AppState? = nil, newWindow forceNew: Bool = false) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let shown = all.first(where: { $0.folders.contains { $0.path == path } }) {
            shown.sidebarVisible = true
            shown.showWindow()
            return
        }
        let candidate = requester ?? target
        if !forceNew, !candidate.isMain, candidate.launchGateOpen, candidate.isPristine {
            candidate.addFolder(url)
            candidate.showWindow()
            return
        }
        let state = newWindow()
        Task {
            await state.restoreTask?.value
            state.addFolder(url)
        }
    }

    /// Open Folder…: into `window` when the sidebar asked, else as `openFolder` decides.
    func beginOpenFolderPanel(into window: AppState? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let window { window.addFolder(url) } else { openFolder(url) }
        }
    }

    // MARK: Opening files

    /// Finder, the Dock and the command line. A file already open goes to its window; else to the window
    /// whose folder holds it; else to the window the user was last in. Folders open as `openFolder` decides.
    func openURLs(_ urls: [URL]) {
        guard started else { pendingURLs.append(contentsOf: urls); return }
        Task {
            // Folder ownership and open tabs are unknown until every restored session is loaded.
            for state in all { await state.restoreTask?.value }
            routeURLs(urls)
        }
    }

    private func routeURLs(_ urls: [URL]) {
        var groups: [(AppState, [URL])] = []
        func add(_ url: URL, to state: AppState) {
            if let i = groups.firstIndex(where: { $0.0 === state }) { groups[i].1.append(url) } else { groups.append((state, [url])) }
        }
        var requests: [URL] = []
        for url in urls {
            if CommandLineTool.isRequest(url) { requests.append(url); continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                openFolder(url)
                continue
            }
            add(url, to: holder(of: url) ?? folderOwner(of: url) ?? target)
        }
        // A line to go to or piped text follows the files it came with.
        for request in requests { add(request, to: groups.first?.0 ?? target) }
        for (state, urls) in groups { state.openURLs(urls) }
    }

    /// The window with a tab for this file.
    func holder(of url: URL, excluding: AppState? = nil) -> AppState? {
        all.first { $0 !== excluding && $0.bufferID(for: url) != nil }
    }

    /// The window whose sidebar folder holds the file, the deepest folder winning.
    func folderOwner(of url: URL) -> AppState? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var best: (AppState, Int)?
        for state in all {
            for folder in state.folders where !folder.unavailable && folder.contains(path) && folder.path.count > (best?.1 ?? -1) {
                best = (state, folder.path.count)
            }
        }
        return best?.0
    }

    func owner(ofTab id: UUID) -> AppState? {
        all.first { $0.session.buffers[id] != nil }
    }

    // MARK: Moving tabs

    /// Moves a tab into `destination`, before `target` or last. The tab is written to the destination's session
    /// before it leaves the source, so a crash in between keeps it twice rather than losing it. The window it
    /// leaves gets an Untitled tab if that was its last, or closes if it is a workspace with no folder.
    @discardableResult
    func moveTab(_ id: UUID, to destination: AppState, before target: UUID? = nil, select: Bool = true) async -> Bool {
        guard let source = owner(ofTab: id), source !== destination,
              source.launchGateOpen, destination.launchGateOpen,
              !source.transferring, !destination.transferring,
              source.savingIDs.isEmpty, destination.savingIDs.isEmpty,
              destination.ensureRoomForTab(),
              let transfer = source.tabTransfer(id) else { return false }
        // Until the destination is durable, the source remains authoritative. Keep both windows
        // stable across actor hops; a second move/close must not tear down either session.
        source.transferring = true
        destination.transferring = true
        let sourceEditable = source.host.textView.isEditable
        let destinationEditable = destination.host.textView.isEditable
        source.host.textView.isEditable = false
        destination.host.textView.isEditable = false
        defer {
            source.transferring = false
            destination.transferring = false
            source.host.textView.isEditable = sourceEditable
            destination.host.textView.isEditable = destinationEditable
        }
        let store = source.stores[id]
        let generation = store?.generation
        let metadata = source.session.buffers[id]
        let durable = await destination.adoptTab(transfer, before: target, select: select)
        // External reloads and already-running asynchronous edits can still finish during the flush.
        // Keep the source if its snapshot changed; never delete newer text or a failed write's only copy.
        guard durable, source.stores[id] === store, store?.generation == generation,
              source.session.buffers[id] == metadata else {
            destination.removeBuffer(id, rememberClosed: false)
            source.showWindow()
            return false
        }
        source.removeBuffer(id, rememberClosed: false, refill: false)
        if source.session.tabOrder.isEmpty {
            if !source.isMain && source.folders.isEmpty {
                await teardown(source)
            } else {
                source.newTab()
            }
        }
        if select {
            destination.showWindow()
            destination.host.focus()
        }
        return true
    }

    /// A tab drag that no tab bar took ends here. Over another editor window the tab moves there; over the
    /// window it came from nothing happens; anywhere else it becomes a new window under the pointer.
    func tabDragEnded(_ id: UUID, at point: NSPoint) {
        guard let source = owner(ofTab: id) else { return }
        let hit = NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(point) && state(for: $0) != nil }
        if let window = hit, let destination = self.state(for: window) {
            if destination !== source { Task { await moveTab(id, to: destination) } }
            return
        }
        // Over another app's window or the desktop.
        let topLeft = NSPoint(x: point.x - 120, y: point.y + 16)
        if !source.isMain, source.folders.isEmpty, source.session.tabOrder == [id], let window = source.window {
            window.setFrameTopLeftPoint(topLeft)   // the window's only tab: move the window instead
            return
        }
        Task { await detachTab(id, topLeft: topLeft) }
    }

    /// The tab, alone in a new window.
    @discardableResult
    func detachTab(_ id: UUID, topLeft: NSPoint? = nil) async -> AppState? {
        guard let source = owner(ofTab: id) else { return nil }
        let window = newWindow(topLeft: topLeft ?? source.window.map { NSPoint(x: $0.frame.minX + 30, y: $0.frame.maxY - 30) })
        await window.restoreTask?.value
        let blank = window.session.tabOrder
        guard await moveTab(id, to: window) else {
            await teardown(window)
            return nil
        }
        for other in blank where window.session.buffers[other]?.isUntitled == true && (window.stores[other]?.length ?? 0) == 0 {
            window.removeBuffer(other, rememberClosed: false, refill: false)
        }
        return window
    }

    // MARK: Closing

    /// Close Window and the red button. The main window hides. Another window closes for good: tabs with
    /// unsaved changes are moved to the main window or discarded, as the user chooses.
    func closeWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard let state = self.state(for: window) else { return window.performClose(nil) }
        if state.isMain {
            state.hideWindow(window)
        } else {
            Task { await close(state) }
        }
    }

    /// False when the user cancelled, or the unsaved tabs could not all be moved.
    @discardableResult
    func close(_ state: AppState, asking: Bool = true) async -> Bool {
        guard !state.isMain, !state.closing, !state.transferring, windows.contains(where: { $0 === state }) else { return false }
        await state.restoreTask?.value
        state.host.captureViewState()
        let unsaved = state.session.tabOrder.filter { state.isDirtyNow($0) }
        if !unsaved.isEmpty {
            let keep: Bool
            if asking {
                let alert = NSAlert()
                alert.messageText = String(localized: "Close this window?")
                alert.informativeText = String(localized: "\(unsaved.count) tabs in this window have unsaved changes. Move them to the main window to keep them.")
                alert.addButton(withTitle: String(localized: "Move to Main Window"))   // default: Return keeps the text
                alert.addButton(withTitle: String(localized: "Discard Changes"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                alert.buttons[1].hasDestructiveAction = true
                alert.buttons[2].keyEquivalent = "\u{1b}"
                switch alert.runModal() {
                case .alertFirstButtonReturn: keep = true
                case .alertSecondButtonReturn: keep = false
                default: return false
                }
            } else {
                keep = true
            }
            if keep {
                for (i, id) in unsaved.enumerated() {
                    guard await moveTab(id, to: main, select: i == unsaved.count - 1) else { return false }
                }
            }
        }
        await teardown(state)
        return true
    }

    private func teardown(_ state: AppState) async {
        guard let id = state.workspaceID, !state.closing else { return }
        await state.shutDown()
        controllers[id]?.dismiss()
        controllers[id] = nil
        windows.removeAll { $0 === state }
        if active === state { active = self.state(for: NSApp.keyWindow) ?? main }
        try? FileManager.default.removeItem(at: state.root)
    }

    // MARK: Quit

    /// Every window flushes; Quit goes through only when all of them did, within 8 s.
    func handleTerminate(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        let states = all.filter(\.launchGateOpen)
        guard !states.isEmpty else { return .terminateNow }
        if states.contains(where: \.terminationRefused) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit without saving recovery data?")
            alert.informativeText = String(localized: "TinyEdit could not write your unsaved text to disk. Quitting now can lose recent edits.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            alert.buttons[1].hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        for state in all { state.saveWorkspaceNow() }
        let jobs = states.map { ($0, $0.prepareTerminationFlush()) }
        let shot = QuitShot()
        Task {
            var ok = true
            for (state, job) in jobs {
                let out = await job()
                if !out.ok {
                    ok = false
                    state.terminationRefused = true
                    state.handleOutcome(out)
                }
            }
            guard !shot.done else { return }
            shot.done = true
            reply(ok)
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard !shot.done else { return }
            shot.done = true
            for state in states { state.terminationRefused = true }
            states.first?.showToast(String(localized: "Recovery save failed"), error: true)
            reply(false)
        }
        return .terminateLater
    }

    func flushAll() {
        for state in all { state.flushImmediately() }
    }
}

private final class QuitShot: @unchecked Sendable {
    var done = false
}

/// A workspace window: AppKit-made, so it can open anywhere (under a dragged tab), at launch, and from the
/// Dock, and so its delegate owns closing.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let state: AppState

    init(state: AppState) {
        self.state = state
        let size = WindowSize.load(visible: NSScreen.main?.visibleFrame.size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = "TinyEdit"
        let hosting = NSHostingController(rootView: RootView().environment(state))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
        state.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A saved frame wins; else under `topLeft`; else cascaded from `cascadeFrom`; else centered.
    func show(frame: String?, topLeft: NSPoint?, cascadeFrom other: NSWindow? = nil, makeKey: Bool) {
        guard let window else { return }
        if let frame {
            window.setFrame(from: frame)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        } else if let topLeft {
            window.setFrameTopLeftPoint(topLeft)
            // Under a pointer near the screen's edge: keep the title bar reachable.
            let screen = NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                var frame = window.frame
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - min(frame.width, visible.width))
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                window.setFrame(frame, display: false)
            }
        } else if let other, other.isVisible {
            window.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 26, y: other.frame.maxY - 26))
        } else {
            window.center()
        }
        if makeKey {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderFront(nil)
        }
    }

    func dismiss() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await Workspaces.shared.close(state) }
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) { state.saveWorkspace() }
    func windowDidMove(_ notification: Notification) { state.saveWorkspace() }
}
