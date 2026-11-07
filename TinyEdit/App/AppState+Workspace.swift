import AppKit

/// A folder in a window's sidebar. The bookmark is what is stored; `url` is where it resolved to (symlinks
/// resolved, so it matches the paths FSEvents reports), and `scopeURL` the URL whose security scope is open.
struct WorkspaceFolder: Identifiable, Equatable {
    let id: UUID
    var bookmark: Data
    var url: URL
    var unavailable = false
    var scopeURL: URL
    var name: String { url.lastPathComponent }
    var path: String { url.path }

    /// True when `path` is this folder or inside it.
    func contains(_ path: String) -> Bool {
        path == self.path || path.hasPrefix(self.path.hasSuffix("/") ? self.path : self.path + "/")
    }
}

/// `workspace.json`, next to each window's `session.json`: the sidebar and, for a window other than the main
/// one, where it was on screen. Small and rewritten whole.
struct WorkspaceFile: Codable, Equatable {
    static let fileName = "workspace.json"
    static let defaultSidebarWidth = 240.0
    static let sidebarWidthRange = 160.0...480.0

    struct Folder: Codable, Equatable {
        var bookmark: Data
        /// The last resolved path, for a folder whose bookmark no longer resolves.
        var path: String
    }

    var schema = 1
    var createdAt: Date
    var folders: [Folder] = []
    var sidebarVisible: Bool
    var sidebarWidth = defaultSidebarWidth
    /// Expanded folders, by path.
    var expanded: [String] = []
    /// `NSWindow.frameDescriptor`; nil for the main window, which opens centered.
    var frame: String?

    static func read(in root: URL) -> WorkspaceFile? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WorkspaceFile.self, from: data)
    }
}

/// A tab on its way to another window: its metadata and text, copied from the window it leaves.
struct TabTransfer {
    var buffer: EditorBuffer
    var text: String
    var viewState: BufferTextStore.ViewState
    var indentOverride: IndentStyle?
}

extension AppState {
    // MARK: workspace.json

    var workspaceFileURL: URL { root.appendingPathComponent(WorkspaceFile.fileName) }

    func makeWorkspaceFile() -> WorkspaceFile {
        WorkspaceFile(createdAt: workspaceCreatedAt,
                      folders: folders.map { .init(bookmark: $0.bookmark, path: $0.path) },
                      sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth,
                      expanded: fileTree.expanded.sorted(),
                      frame: isMain ? nil : window?.frameDescriptor)
    }

    /// Reads `workspace.json` and opens each folder's scope. A folder that no longer resolves is dropped
    /// from the sidebar (its tabs keep their own bookmarks).
    func loadWorkspace() {
        defer { workspaceLoaded = true }
        guard let file = WorkspaceFile.read(in: root) else { return }
        workspaceCreatedAt = file.createdAt
        sidebarVisible = file.sidebarVisible
        sidebarWidth = file.sidebarWidth.clamped(to: WorkspaceFile.sidebarWidthRange)
        var loaded: [WorkspaceFolder] = []
        for stored in file.folders {
            // A scope that needs no opening (inside the container) starts as false; the bookmark resolving is what counts.
            guard let (url, stale) = try? access.resolve(stored.bookmark) else {
                Log.files.error("workspace folder bookmark failed")
                loaded.append(WorkspaceFolder(id: UUID(), bookmark: stored.bookmark,
                                              url: URL(fileURLWithPath: stored.path), unavailable: true,
                                              scopeURL: URL(fileURLWithPath: stored.path)))
                continue
            }
            access.start(url)
            var bookmark = stored.bookmark
            if stale, let fresh = try? access.bookmark(for: url) { bookmark = fresh }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !loaded.contains(where: { $0.path == resolved.path }) else { access.stop(url); continue }
            let missing = !FileManager.default.fileExists(atPath: resolved.path)
                || resolved.pathComponents.contains(".Trash") || resolved.pathComponents.contains(".Trashes")
            loaded.append(WorkspaceFolder(id: UUID(), bookmark: bookmark,
                                          url: missing ? URL(fileURLWithPath: stored.path) : resolved,
                                          unavailable: missing, scopeURL: url))
        }
        folders = loaded
        fileTree.restore(expanded: Set(file.expanded), roots: loaded.map(\.path))
        for folder in loaded {
            if folder.unavailable { fileTree.markUnavailable(folder.path) }
            else { monitorFolder(folder) }
        }
    }

    /// Written in order, off the main thread. A closing window writes nothing more.
    func saveWorkspace() {
        guard workspaceLoaded, !closing else { return }
        guard let data = try? JSONEncoder().encode(makeWorkspaceFile()) else { return }
        let url = workspaceFileURL, dir = root
        let previous = workspaceWrite
        workspaceWrite = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Quit: the frame and sidebar as they are now, before the process goes.
    func saveWorkspaceNow() {
        guard workspaceLoaded, !closing, let data = try? JSONEncoder().encode(makeWorkspaceFile()) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: workspaceFileURL, options: .atomic)
    }

    // MARK: Folders

    /// Adds a folder to this window's sidebar (and shows the sidebar). A folder already there is only revealed.
    func addFolder(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        sidebarVisible = true
        if !folders.contains(where: { $0.path == resolved.path }) {
            let started = access.start(url)
            do {
                let bookmark = try access.bookmark(for: url)
                folders.append(WorkspaceFolder(id: UUID(), bookmark: bookmark, url: resolved, scopeURL: url))
                monitorFolder(folders.last!)
                fileTree.addRoot(resolved.path)
                noteRecentDocument(url)
            } catch {
                if started { access.stop(url) }
                Log.files.error("folder bookmark failed: \((error as NSError).code)")
                showToast(String(localized: "Could not open the folder"), error: true)
            }
        }
        saveWorkspace()
    }

    func removeFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = folders.remove(at: index)
        folderMonitors.removeValue(forKey: id)?.unregister()
        fileTree.removeRoot(folder.path)
        access.stop(folder.scopeURL)
        saveWorkspace()
    }

    func refreshFolderLocations() {
        for folder in folders {
            if let resolved = try? access.resolve(folder.bookmark).url {
                let path = resolved.standardizedFileURL.resolvingSymlinksInPath().path
                if path != folder.path || folder.unavailable { folderMoved(folder.id, to: resolved) }
                else if !FileManager.default.fileExists(atPath: path) { folderUnavailable(folder.id) }
            } else if !FileManager.default.fileExists(atPath: folder.path) {
                folderUnavailable(folder.id)
            }
        }
    }

    /// A directory presenter follows root moves, while FSEvents handles changes inside the tree.
    private func monitorFolder(_ folder: WorkspaceFolder) {
        folderMonitors.removeValue(forKey: folder.id)?.unregister()
        let monitor = ExternalFileMonitor(url: folder.url)
        let id = folder.id
        monitor.onMove = { [weak self] url in
            Task { @MainActor in self?.folderMoved(id, to: url) }
        }
        monitor.onDelete = { [weak self] in
            Task { @MainActor in self?.folderUnavailable(id) }
        }
        monitor.register()
        folderMonitors[id] = monitor
    }

    func folderUnavailable(_ id: UUID) {
        guard !closing, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].unavailable = true
        fileTree.markUnavailable(folders[index].path)
        saveWorkspace()
    }

    func folderMoved(_ id: UUID, to url: URL) {
        guard !closing, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        // Moving to Trash is a deletion from the project's perspective. Keep open text buffers intact.
        guard !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
              FileManager.default.fileExists(atPath: url.path) else { folderUnavailable(id); return }
        let old = folders[index].path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        folders[index].url = resolved
        folders[index].unavailable = false
        if let bookmark = try? access.bookmark(for: url) { folders[index].bookmark = bookmark }
        fileTree.moveRoot(old, to: resolved.path)
        monitorFolder(folders[index])
        saveWorkspace()
    }

    func locateFolder(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url,
              let index = folders.firstIndex(where: { $0.id == id }),
              let bookmark = try? access.bookmark(for: url) else { return }
        let old = folders[index]
        access.start(url)
        folders[index].scopeURL = url
        folders[index].bookmark = bookmark
        folderMoved(id, to: url)
        access.stop(old.scopeURL)
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        saveWorkspace()
    }

    func setSidebarWidth(_ width: Double, save: Bool) {
        let w = width.clamped(to: WorkspaceFile.sidebarWidthRange)
        if w != sidebarWidth { sidebarWidth = w }
        if save { saveWorkspace() }
    }

    /// The narrowest the editor side may get: the editor, and the preview beside it when it shows.
    var editorMinWidth: Double { SidebarLayout.paneMinWidth * (previewVisible ? 2 : 1) }

    /// One step of a divider drag. Dragging under `SidebarLayout.collapseBelow` hides the sidebar, and dragging
    /// back out in the same drag shows it again.
    @discardableResult
    func dragSidebar(to proposed: Double, windowWidth: Double) -> SidebarLayout.Drag {
        let result = SidebarLayout.drag(proposed: proposed, windowWidth: windowWidth, editorMinWidth: editorMinWidth)
        switch result {
        case .collapse:
            if sidebarVisible { sidebarVisible = false }
        case .width(let width, _):
            if !sidebarVisible { sidebarVisible = true }
            if width != sidebarWidth { sidebarWidth = width }
        }
        return result
    }

    /// The end of a divider drag. A sidebar dragged shut keeps the width it had, for when it opens again.
    /// Saved once, and only if something changed.
    func endSidebarDrag(startWidth: Double, wasVisible: Bool) {
        if !sidebarVisible && sidebarWidth != startWidth { sidebarWidth = startWidth }
        if sidebarVisible != wasVisible || sidebarWidth != startWidth { saveWorkspace() }
    }

    /// A double-click on the divider.
    func resetSidebarWidth() {
        setSidebarWidth(WorkspaceFile.defaultSidebarWidth, save: true)
    }

    /// Folders and files dropped on the sidebar: folders join it, files open in this window.
    func dropOnSidebar(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                addFolder(url)
            } else {
                files.append(url)
            }
        }
        if !files.isEmpty { openURLs(files) }
    }

    /// A click on a sidebar row: a folder opens or closes, a file opens in this window.
    func activateSidebarItem(_ node: FileNode) {
        if node.isDirectory {
            fileTree.toggle(node.path)
        } else {
            openURLs([node.url])
        }
    }

    /// The sidebar row of the visible tab's file, if a folder holds it.
    var selectedFilePath: String? {
        guard let b = selectedBuffer, !b.isUntitled, let dir = b.directoryPath, let name = b.fileDisplayName else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name).resolvingSymlinksInPath().path
    }

    /// Only Untitled tabs with nothing in them: a folder opened from here can take this window over.
    var isPristine: Bool {
        folders.isEmpty && session.tabOrder.allSatisfy { id in
            session.buffers[id]?.isUntitled == true && (stores[id]?.length ?? 0) == 0
        }
    }

    // MARK: Moving tabs between windows

    /// Copies a tab out without removing it.
    func tabTransfer(_ id: UUID) -> TabTransfer? {
        guard var buffer = session.buffers[id], let store = stores[id] else { return nil }
        if host.activeStore === store { host.captureViewState() }
        buffer.pasteSuggestion = nil
        buffer.imageText = nil
        buffer.curlRun = nil
        return TabTransfer(buffer: buffer, text: store.logicalString(), viewState: store.viewState,
                           indentOverride: store.indentOverride)
    }

    /// Takes in a tab from another window, before `target` (or last), and writes it to this window's session
    /// before returning, so the other window can then let it go. The undo history stays behind.
    func adoptTab(_ transfer: TabTransfer, before target: UUID?, select: Bool) async -> Bool {
        var buffer = transfer.buffer
        if buffer.fileBookmark != nil { attachRestoredFile(&buffer) }
        let store = makeStore(for: buffer, text: transfer.text)
        let length = store.length
        let location = min(transfer.viewState.selection.location, length)
        store.viewState = .init(selection: NSRange(location: location,
                                                   length: min(transfer.viewState.selection.length, length - location)),
                                scrollFraction: transfer.viewState.scrollFraction)
        store.indentOverride = transfer.indentOverride
        // A tab that left this window earlier and comes back keeps its id: it is no longer deleted here.
        session.tombstones.removeAll { $0 == buffer.id }
        session.buffers[buffer.id] = buffer
        let index = target.flatMap { session.tabOrder.firstIndex(of: $0) } ?? session.tabOrder.endIndex
        session.tabOrder.insert(buffer.id, at: index)
        session.keepPinnedFirst()
        if select {
            host.captureViewState()
            session.selectedBufferID = buffer.id
            activeBufferChanged()
        }
        writtenGeneration[buffer.id] = nil
        await pendingRemovals[buffer.id]?.value   // it left this window earlier: that deletion goes first
        await recoveryActor.readmit(buffer.id)
        let durable = await performFlush()
        if buffer.dirty { scheduleDirtyCheck(buffer.id) }
        return durable
    }

    /// The window is closing: stop writing, close every file and folder scope, stop watching.
    func shutDown() async {
        closing = true
        launchGateOpen = false
        flushTask?.cancel()
        await recoveryActor.setLaunchGateOpen(false)
        for id in Array(stores.keys) {
            languageDetectionTasks[id]?.cancel()
            pasteTasks[id]?.cancel()
            curlJobs[id]?.task.cancel()
            imageTextJobs[id]?.task.cancel()
            dirtyTasks[id]?.cancel()
            unregisterFile(id)
            stores[id]?.invalidate()
        }
        for folder in folders { access.stop(folder.scopeURL) }
        for monitor in folderMonitors.values { monitor.unregister() }
        folderMonitors.removeAll()
        fileTree.stopWatching()
        await workspaceWrite?.value
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
