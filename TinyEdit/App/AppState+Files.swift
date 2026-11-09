import AppKit

enum SaveOutcome { case saved, conflict, failed }

extension AppState {
    // MARK: File registration

    func registerFile(id: UUID, url: URL) {
        unregisterMonitor(id)
        fileURLs[id] = url
        let m = ExternalFileMonitor(url: url)
        m.onChange = { [weak self] in Task { @MainActor in await self?.handleExternalChange(id) } }
        m.onMove = { [weak self] new in Task { @MainActor in self?.handleMoved(id, to: new) } }
        m.onDelete = { [weak self] in Task { @MainActor in await self?.handleDeleted(id) } }
        m.register()
        monitors[id] = m
    }

    private func unregisterMonitor(_ id: UUID) {
        monitors[id]?.unregister()
        monitors[id] = nil
    }

    /// Stops the presenter and the security scope. Safe for a buffer with no file.
    func unregisterFile(_ id: UUID) {
        unregisterMonitor(id)
        if let url = fileURLs[id] { access.stop(url) }
        fileURLs[id] = nil
        // A change seen in the old file says nothing about the next one.
        if session.buffers[id]?.externalChange != nil { session.buffers[id]?.externalChange = nil }
    }

    // MARK: Open

    func beginOpenPanel() {
        guard launchGateOpen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // a folder opens in a window of its own
        panel.allowsMultipleSelection = true
        // No allowedContentTypes: TinyEdit tries to open any text file.
        guard panel.runModal() == .OK else { return }
        openURLs(panel.urls)
    }

    /// Finder, panel, and drag all land here. Before the launch gate opens, URLs are queued.
    func openURLs(_ urls: [URL]) {
        guard launchGateOpen else { pendingURLs.append(contentsOf: urls); return }
        Task { await openURLsAsync(urls) }
    }

    /// Files over `LargeFilePolicy.threshold` (or any file, with `.large`) open in the large-file view.
    func openURLsAsync(_ urls: [URL], mode: OpenMode = .automatic) async {
        guard !closing, !transferring else { return }
        let isRequest = { (url: URL) in CommandLineTool.isRequest(url) || FinderMenu.directory(from: url) != nil }
        let requests = urls.filter(isRequest)
        let urls = urls.filter { !isRequest($0) && $0.isFileURL }
        showWindow() // the red button may have hidden it; the tab and any error toast must be seen
        flushImmediately() // a large read or a failed open must not sit inside another buffer's debounce window
        var firstNew: UUID?
        var existing: UUID?
        // A folder window starts with an empty Untitled tab; the first file opened there takes its place.
        let placeholders = isMain ? [] : session.tabOrder.filter { id in
            session.buffers[id]?.isUntitled == true && session.buffers[id]?.titleIsCustom == false
                && session.buffers[id]?.saveDirectory == nil && (stores[id]?.length ?? 1) == 0
        }
        var opened = 0
        var overLimit = 0
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                Workspaces.shared.openFolder(url, from: self)
                continue
            }
            if let id = bufferID(for: url) { existing = existing ?? id; continue }
            // A file is open in one window at a time: asked for here, its tab moves here.
            if let other = Workspaces.shared.holder(of: url, excluding: self), let id = other.bufferID(for: url) {
                if await Workspaces.shared.moveTab(id, to: self, select: false) { existing = existing ?? id }
                continue
            }
            guard hasRoomForTab else { overLimit += 1; continue }

            let started = access.start(url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if mode == .large || (mode == .automatic && size > LargeFilePolicy.threshold) {
                if let id = await openLargeURL(url, started: started) {
                    firstNew = firstNew ?? id
                    opened += 1
                }
                continue
            }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try FileLoader.load(from: url) }.value
                if let id = bufferID(for: url) { // opened concurrently
                    if started { access.stop(url) }
                    existing = existing ?? id
                    continue
                }
                guard !closing, !transferring else {
                    if started { access.stop(url) }
                    return
                }
                // Another window may have finished the same asynchronous read first.
                if let other = Workspaces.shared.holder(of: url, excluding: self), let id = other.bufferID(for: url) {
                    if started { access.stop(url) }
                    if await Workspaces.shared.moveTab(id, to: self, select: false) { existing = existing ?? id }
                    continue
                }
                let bookmark = try access.bookmark(for: url)
                var b = EditorBuffer(title: url.lastPathComponent)
                b.fileBookmark = bookmark
                b.rememberFileURL(url)
                b.language = EditorLanguage.detect(fileName: url.lastPathComponent, text: String(loaded.logicalLF.prefix(200)))
                b.encoding = loaded.encoding
                b.lineEnding = loaded.lineEnding
                b.lastSavedContentHash = loaded.logicalHash
                b.diskContentHash = loaded.rawHash
                b.diskModificationDate = loaded.modificationDate
                b.diskFileSize = loaded.byteSize
                makeStore(for: b, text: loaded.logicalLF)
                session.buffers[b.id] = b
                session.tabOrder.append(b.id)
                registerFile(id: b.id, url: url)
                noteRecentDocument(url)
                firstNew = firstNew ?? b.id
                opened += 1
            } catch FileOpenError.fileTooLarge {
                // It grew past the editor's limit since it was measured.
                if let id = await openLargeURL(url, started: started) {
                    firstNew = firstNew ?? id
                    opened += 1
                }
            } catch is FileOpenError {
                if started { access.stop(url) }
                showToast(String(localized: "Could not open file"), error: true)
            } catch {
                if started { access.stop(url) }
                Log.files.error("open failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                showToast(String(localized: "Bookmark failed"), error: true)
            }
        }
        if let target = firstNew ?? existing { selectTab(target) }
        if firstNew != nil {
            for id in placeholders where (stores[id]?.length ?? 1) == 0 { removeBuffer(id, rememberClosed: false, refill: false) }
        }
        await runCommandLineRequests(requests)
        if overLimit > 0 {
            showToast(opened == 0 ? Self.tabLimitMessage
                      : String(localized: "Opened \(opened) of \(opened + overLimit) files. Tabs are limited to \(EditorSession.maxTabs)."))
        }
        flushImmediately()
    }

    /// One large-file open inside `openURLsAsync`: the scope `started` is kept by the tab, or stopped on failure.
    private func openLargeURL(_ url: URL, started: Bool) async -> UUID? {
        guard !closing, !transferring else {
            if started { access.stop(url) }
            return nil
        }
        do {
            return try await openLargeFile(url)   // the tab keeps the scope, as an editor tab does
        } catch {
            if started { access.stop(url) }
            Log.files.error("large open failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            showToast(String(localized: "Could not open file"), error: true)
            return nil
        }
    }

    func bufferID(for url: URL) -> UUID? {
        let key = FileAccessManager.key(url)
        return fileURLs.first { FileAccessManager.key($0.value) == key }?.key
    }

    // MARK: Save

    func save() {
        guard let id = session.selectedBufferID else { return }
        Task { _ = await saveFlow(id) }
    }

    func saveAs() {
        guard let id = session.selectedBufferID else { return }
        Task { _ = await saveAsFlow(id) }
    }

    /// Every file tab with unsaved changes, one after another, each as Save would (a conflict still asks).
    /// Tabs without a file (Untitled, a broken bookmark) are left alone: a save panel per tab is not wanted.
    func saveAll() {
        guard launchGateOpen else { return }
        Task { await saveAllAsync() }
    }

    func saveAllAsync() async {
        let dirty = session.tabOrder.filter { isDirtyNow($0) }
        let files = dirty.filter { fileURLs[$0] != nil && session.buffers[$0]?.isUntitled == false }
        let fileless = dirty.count - files.count
        var saved = 0
        for id in files where session.buffers[id] != nil {
            if await saveFlow(id) { saved += 1 }
        }
        if saved > 0 { showToast(String(localized: "Saved \(saved) files")) }
        if fileless > 0 {
            if saved > 0 { try? await Task.sleep(for: .milliseconds(1700)) }
            showToast(String(localized: "Tabs without a file were not saved. Use Save As."))
        } else if files.isEmpty {
            showToast(String(localized: "No unsaved files"))
        }
    }

    /// Untitled and broken-bookmark buffers go through Save As. External conflicts confirm first.
    @discardableResult
    func saveFlow(_ id: UUID) async -> Bool {
        guard !transferring, !closing else { return false }
        guard let b = session.buffers[id] else { return false }
        guard !b.isUntitled, let url = fileURLs[id] else { return await saveAsFlow(id) }
        // A large-file tab without edits has nothing to write.
        if let doc = largeFiles[id], !doc.hasEdits, doc.pendingEdits == nil, b.conflict == .none { return true }
        if b.conflict == .external { return await confirmedOverwriteSave(id, url: url) }
        switch await performSave(id: id, url: url, overwrite: false, presenter: monitors[id]) {
        case .saved: return true
        case .failed: return false
        case .conflict: return await confirmedOverwriteSave(id, url: url)
        }
    }

    private func confirmedOverwriteSave(_ id: UUID, url: URL) async -> Bool {
        guard let b = session.buffers[id] else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(b.displayTitle)” changed on disk.")
        alert.informativeText = String(localized: "Saving will replace the version on disk with your version.")
        alert.addButton(withTitle: String(localized: "Overwrite"))
        alert.addButton(withTitle: String(localized: "Save As…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return await performSave(id: id, url: url, overwrite: true, presenter: monitors[id]) == .saved
        case .alertSecondButtonReturn:
            return await saveAsFlow(id)
        default:
            return false // Cancel writes nothing
        }
    }

    /// `replacement` is a Replace All too large for a large-file tab's edits, written into the saved file.
    @discardableResult
    func saveAsFlow(_ id: UUID, replacement: LargeFileReplacement? = nil) async -> Bool {
        guard !transferring, !closing else { return false }
        guard let b = session.buffers[id] else { return false }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true   // no required file type, no forced .txt
        var name = b.isUntitled
            ? b.displayTitle.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            : b.title
        if let current = fileURLs[id] {
            panel.directoryURL = current.deletingLastPathComponent()
        } else if let folder = b.saveDirectory {
            // Finder's New Text File: that folder, and a name Finder shows as a text file.
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
            if (name as NSString).pathExtension.isEmpty { name += "." + b.language.preferredExtension }
        }
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let sameFile = fileURLs[id].map { FileAccessManager.key($0) == FileAccessManager.key(url) } ?? false
        let started = access.start(url)
        // The save panel already confirmed replacing an existing file.
        let outcome = await performSave(id: id, url: url, overwrite: true, presenter: sameFile ? monitors[id] : nil,
                                        replacement: replacement)
        guard outcome == .saved else {
            if started { access.stop(url) }
            return false
        }
        if sameFile {
            if started { access.stop(url) }
        } else {
            rebind(id, to: url)
        }
        return true
    }

    /// Save As to a new location: stop the old scope, take the new bookmark, move the presenter, retitle.
    private func rebind(_ id: UUID, to url: URL) {
        let oldExt = fileURLs[id]?.pathExtension ?? ""
        // The new URL's scope was started by the caller; unregisterFile only releases the old one.
        unregisterFile(id)
        do {
            let bm = try access.bookmark(for: url)
            session.buffers[id]?.fileBookmark = bm
        } catch {
            Log.files.error("bookmark failed after save as: \((error as NSError).code)")
            showToast(String(localized: "Bookmark failed"), error: true)
        }
        languageDetectionTasks[id]?.cancel()
        session.buffers[id]?.languageSuggestion = nil
        session.buffers[id]?.rememberFileURL(url)
        session.buffers[id]?.title = url.lastPathComponent
        session.buffers[id]?.titleIsCustom = false
        session.buffers[id]?.saveDirectory = nil
        do {
            let lang = EditorLanguage.detect(fileName: url.lastPathComponent,
                                             text: stores[id].map { String($0.logicalString().prefix(200)) } ?? "")
            // A manual choice on an Untitled tab survives saving under a name that does not say otherwise.
            if lang != .plain || !oldExt.isEmpty {
                session.buffers[id]?.language = lang
                if let store = stores[id] { highlight.schedule(store: store, language: lang, delay: .zero) }
                schedulePreview(delay: .zero)
                if session.selectedBufferID == id { host.textView.refreshInlineCalculation() }
            }
        }
        session.buffers[id]?.conflict = .none
        bookmarkBroken.remove(id)
        registerFile(id: id, url: url)
        refreshStatus()
        flushImmediately()
    }

    func performSave(id: UUID, url: URL, overwrite: Bool, presenter: ExternalFileMonitor?,
                     replacement: LargeFileReplacement? = nil) async -> SaveOutcome {
        if largeFiles[id] != nil {
            return await performLargeSave(id: id, url: url, overwrite: overwrite, presenter: presenter, replacement: replacement)
        }
        guard let b = session.buffers[id], let store = stores[id] else { return .failed }
        applySaveCleanup(store, language: b.language)
        let text = store.logicalString()
        let gen = store.generation
        let ack = b.diskContentHash
        let enc = b.encoding, ending = b.lineEnding
        savingIDs.insert(id)
        defer { savingIDs.remove(id) }

        let result: Result<SavedFileStats, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try FileSaver.save(logicalLF: text, to: url, encoding: enc, lineEnding: ending,
                                   acknowledgedDiskHash: ack, overwriteConfirmed: overwrite, presenter: presenter)
            }
        }.value

        switch result {
        case .success(let stats):
            guard var live = session.buffers[id] else { return .saved }
            live.lastSavedContentHash = stats.logicalHash
            live.diskContentHash = stats.rawHash
            live.diskFileSize = stats.byteSize
            live.diskModificationDate = stats.modificationDate
            live.conflict = .none
            // Dirty clears only if the text is still what was written; typing during the save keeps it dirty.
            if store.generation == gen { live.dirty = false }
            session.buffers[id] = live
            showToast(String(localized: "Saved \(url.lastPathComponent)"))
            if !stats.executableBitPreserved {
                // The bytes are saved; the mode is a warning, not a failed save.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1700))
                    self?.showToast(String(localized: "The executable permission could not be preserved."), error: true)
                }
            }
            scheduleDirtyCheck(id)
            noteRecentDocument(url)
            flushImmediately()
            return .saved
        case .failure(let error):
            if let e = error as? FileSaveError, e == .externalChange {
                session.buffers[id]?.conflict = .external
                return .conflict
            }
            Log.files.error("save failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            showToast(String(localized: "Could not save file"), error: true)
            return .failed
        }
    }

    // MARK: Encoding and line ending

    /// Reads the file's bytes again as `encoding`, replacing the text. Unsaved edits are lost, so they confirm first.
    func reopen(with encoding: TextEncoding) {
        guard let id = session.selectedBufferID else { return }
        Task { await reopenAsync(id, with: encoding) }
    }

    func reopenAsync(_ id: UUID, with encoding: TextEncoding) async {
        guard let url = fileURLs[id], let b = session.buffers[id] else { return }
        if isDirtyNow(id) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Reopen “\(b.displayTitle)” as \(encoding.statusLabel)?")
            alert.informativeText = String(localized: "Your unsaved changes will be lost.")
            alert.addButton(withTitle: String(localized: "Reopen"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let doc = largeFiles[id] {
            doc.discardMismatchedEdits()
            guard await doc.reload(url, encoding: encoding) else {
                return showToast(String(localized: "Could not read the file as \(encoding.statusLabel)"), error: true)
            }
            session.buffers[id]?.encoding = encoding
            session.buffers[id]?.conflict = .none
            session.buffers[id]?.dirty = false
            flushImmediately()
            return refreshLargeStatus()
        }
        guard let store = stores[id] else { return }
        let gen = store.generation
        let result = await Task.detached(priority: .userInitiated) {
            Result { try FileLoader.load(from: url, decoding: .force(encoding)) }
        }.value
        guard session.buffers[id] != nil else { return }
        let loaded: LoadedFile
        switch result {
        case .success(let file): loaded = file
        case .failure(FileOpenError.fileTooLarge(let bytes)):
            return showToast(Self.tooLargeMessage(url.lastPathComponent, bytes: bytes), error: true)
        case .failure:
            return showToast(String(localized: "Could not read the file as \(encoding.statusLabel)"), error: true)
        }
        guard textUnchanged(id, store: store, since: gen) else { return }
        await applyDiskVersion(loaded, to: id, markChanges: false)
    }

    /// Encoding and line ending are not part of the logical text, so changing one would not make the tab dirty.
    /// Instead the change is saved at once, as Save would (Untitled goes through Save As); a save that does
    /// not go through puts the old value back.
    func saveWith(encoding: TextEncoding? = nil, lineEnding: LineEnding? = nil) {
        guard let id = session.selectedBufferID else { return }
        Task { await saveWithAsync(id, encoding: encoding, lineEnding: lineEnding) }
    }

    @discardableResult
    func saveWithAsync(_ id: UUID, encoding: TextEncoding? = nil, lineEnding: LineEnding? = nil) async -> Bool {
        guard let b = session.buffers[id], b.largeFile == nil else { return false }
        let old = (b.encoding, b.lineEnding)
        let new = (encoding ?? old.0, lineEnding ?? old.1)
        guard new != old else { return true }
        session.buffers[id]?.encoding = new.0
        session.buffers[id]?.lineEnding = new.1
        refreshStatus()
        if await saveFlow(id) { return true }
        if let live = session.buffers[id], live.encoding == new.0, live.lineEnding == new.1 {
            session.buffers[id]?.encoding = old.0
            session.buffers[id]?.lineEnding = old.1
            refreshStatus()
            flushImmediately()
        }
        return false
    }

    // MARK: Close tab

    func closeSelectedTab() {
        if let id = session.selectedBufferID { closeTab(id) }
    }

    /// File ▸ Close Tab (⌘W). The menu replaces the standard Close, so another window in front (Settings) is
    /// closed here, and a hidden editor loses no tab it does not show.
    func closeTabOrFrontWindow() {
        if let key = NSApp.keyWindow, key !== window { return key.performClose(nil) }
        guard window?.isVisible == true else { return }
        closeSelectedTab()
    }

    func closeTab(_ id: UUID) {
        guard launchGateOpen else { return }
        Task { await closeTabAsync(id) }
    }

    /// False when the user cancelled or the save did not go through, so the tab stays open.
    @discardableResult
    func closeTabAsync(_ id: UUID) async -> Bool {
        guard !transferring, !closing else { return false }
        guard let b = session.buffers[id] else { return true }
        if !isDirtyNow(id) { removeBuffer(id); return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes to “\(b.displayTitle)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))          // default button: Return must not discard
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[2].keyEquivalent = "\u{1b}"  // Escape cancels
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard await saveFlow(id) else { return false }
            guard session.buffers[id] != nil else { return true }
            if isDirtyNow(id) { return false } // typed during the save: stay open
            removeBuffer(id)
            return true
        case .alertSecondButtonReturn:
            removeBuffer(id)
            return true
        default:
            return false
        }
    }

    /// The tabs a tab's context menu would close, in tab order. Pinned tabs are never among them.
    func tabsToClose(_ scope: TabCloseScope, around id: UUID) -> [UUID] {
        tabsInScope(scope, around: id).filter { session.buffers[$0]?.isPinned != true }
    }

    private func tabsInScope(_ scope: TabCloseScope, around id: UUID) -> [UUID] {
        guard let index = session.tabOrder.firstIndex(of: id) else { return [] }
        switch scope {
        case .others: return session.tabOrder.filter { $0 != id }
        case .left: return Array(session.tabOrder[..<index])
        case .right: return Array(session.tabOrder[(index + 1)...])
        case .all: return session.tabOrder
        case .unmodified: return session.tabOrder.filter { isUnmodified($0, rehash: false) }
        }
    }

    /// Closing it loses nothing and asks nothing: a file tab that matches its last save, with no conflict or
    /// broken bookmark, or an empty Untitled tab the user did not name. `rehash` false trusts the dirty flag
    /// (menus); the close itself hashes the text again.
    func isUnmodified(_ id: UUID, rehash: Bool) -> Bool {
        guard let b = session.buffers[id] else { return false }
        if b.isUntitled { return !b.titleIsCustom && (stores[id]?.length ?? 1) == 0 }
        guard fileURLs[id] != nil, b.conflict == .none else { return false }
        return rehash ? !isDirtyNow(id) : !b.dirty
    }

    /// Closes left to right, asking about each tab with unsaved changes. Cancel stops the rest.
    /// The kept tab is selected first, so closing the selected tab does not pass the selection along the row.
    func closeTabs(_ scope: TabCloseScope, around id: UUID) {
        guard launchGateOpen else { return }
        let ids = tabsToClose(scope, around: id)
        guard !ids.isEmpty else { return }
        if scope == .unmodified { return closeUnmodifiedTabs(ids, keeping: id) }
        if !ids.contains(id), let selected = session.selectedBufferID, ids.contains(selected) { selectTab(id) }
        Task {
            for target in ids {
                guard await closeTabAsync(target) else { return }
            }
        }
    }

    /// No questions, so no task: each tab is checked again with a fresh hash and removed at once.
    private func closeUnmodifiedTabs(_ ids: [UUID], keeping id: UUID) {
        guard !transferring, !closing else { return }
        let targets = ids.filter { isUnmodified($0, rehash: true) }
        guard !targets.isEmpty else { return }
        if let selected = session.selectedBufferID, targets.contains(selected), !targets.contains(id) { selectTab(id) }
        for target in targets { removeBuffer(target) }
        showToast(String(localized: "Closed \(targets.count) tabs"))
    }

    func copyPath(of id: UUID) {
        guard let url = fileURLs[id] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        showToast(String(localized: "Copied"))
    }

    /// The file's path inside the deepest of this window's folders that holds it, without the folder's name.
    /// Nil when no folder holds it.
    func relativePath(of id: UUID) -> String? {
        fileURLs[id].flatMap { relativePath(ofPath: $0.standardizedFileURL.resolvingSymlinksInPath().path) }
    }

    func relativePath(ofPath path: String) -> String? {
        guard let folder = folders.filter({ !$0.unavailable && $0.path != path && $0.contains(path) })
            .max(by: { $0.path.count < $1.path.count }) else { return nil }
        return String(path.dropFirst(folder.path.count).drop { $0 == "/" })
    }

    func copyRelativePath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        showToast(String(localized: "Copied"))
    }

    func revealInFinder(_ id: UUID) {
        guard let url = fileURLs[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Clean close and Discard. No content write: bump generation, remove, then manifest-with-tombstone, then delete.
    /// A tab moving to another window is removed the same way, but leaves no Reopen Closed Tab record, and the
    /// caller decides what an emptied window gets (`refill` false).
    func removeBuffer(_ id: UUID, rememberClosed: Bool = true, refill: Bool = true) {
        guard let buffer = session.buffers[id], let index = session.tabOrder.firstIndex(of: id) else { return }
        host.captureViewState()
        if rememberClosed, let bm = buffer.fileBookmark, stores[id] != nil || largeFiles[id] != nil {
            let vs = stores[id]?.viewState ?? BufferTextStore.ViewState()
            let record = ClosedTabRecord(fileBookmark: bm, fileDisplayName: buffer.fileDisplayName ?? buffer.title,
                                         language: buffer.language, encoding: buffer.encoding, lineEnding: buffer.lineEnding,
                                         cursorLocation: vs.selection.location, selectionLength: vs.selection.length,
                                         scrollPosition: vs.scrollFraction, closedAt: Date())
            let key = fileURLs[id].map(FileAccessManager.key)
            session.closedTabs.removeAll { rec in
                guard let key, let resolved = try? access.resolve(rec.fileBookmark).url else { return false }
                return FileAccessManager.key(resolved) == key
            }
            session.closedTabs.insert(record, at: 0)
            session.closedTabs = Array(session.closedTabs.prefix(EditorSession.maxClosedTabs))
        }

        if diff?.sourceID == id { closeDiff(refocus: false) }
        languageDetectionTasks[id]?.cancel(); languageDetectionTasks[id] = nil
        pasteTasks[id]?.cancel(); pasteTasks[id] = nil; pasteTokens[id] = nil
        curlJobs[id]?.task.cancel(); curlJobs[id] = nil; curlBodies[id] = nil; curlCommands[id] = nil
        curlSources[id] = nil
        stores[id]?.invalidate()
        largeFiles[id]?.close(); largeFiles[id] = nil
        largeDiskTasks[id]?.cancel(); largeDiskTasks[id] = nil
        dirtyTasks[id]?.cancel(); dirtyTasks[id] = nil
        unregisterFile(id)
        bookmarkBroken.remove(id)
        writtenGeneration[id] = nil
        let wasSelected = session.selectedBufferID == id
        session.tabOrder.remove(at: index)
        session.buffers[id] = nil
        stores[id] = nil
        session.tombstones.append(id)
        session.tombstones = Array(session.tombstones.suffix(EditorSession.maxTombstones))
        if wasSelected {
            session.selectedBufferID = session.tabOrder.indices.contains(index) ? session.tabOrder[index] : session.tabOrder.last
        }

        let manifest = makeManifest()
        manifestSeq += 1
        let seq = manifestSeq
        let previous = pendingRemovals[id]
        pendingRemovals[id] = Task { [weak self, recoveryActor] in
            await previous?.value
            let out = await recoveryActor.remove(id: id, manifest: manifest, seq: seq)
            self?.handleOutcome(out)
            if self?.pendingRemovals[id] != nil { self?.pendingRemovals[id] = nil }
        }

        if session.tabOrder.isEmpty {
            if refill { newTab() }
        } else {
            activeBufferChanged()
        }
    }

    // MARK: Reopen closed tab

    func reopenClosedTab() {
        guard launchGateOpen else { return }
        Task { await reopenClosedTabAsync() }
    }

    func reopenClosedTabAsync() async {
        guard !session.closedTabs.isEmpty, ensureRoomForTab() else { return }
        let record = session.closedTabs.removeFirst()
        var target: URL?
        if let resolved = try? access.resolve(record.fileBookmark) {
            target = resolved.url
        } else {
            // Not Relocate: there is no live buffer. Ask the user where the file is now.
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = String(localized: "Locate “\(record.fileDisplayName)”")
            guard panel.runModal() == .OK, let url = panel.url else {
                session.closedTabs.insert(record, at: 0) // cancel keeps the record
                return
            }
            target = url
        }
        guard let url = target else { return }
        let before = Set(session.tabOrder)
        await openURLsAsync([url])
        // Restore cursor and scroll from the record onto a newly opened buffer only.
        if let id = session.tabOrder.first(where: { !before.contains($0) }), let store = stores[id] {
            let len = store.length
            let loc = min(record.cursorLocation, len)
            store.viewState = .init(selection: NSRange(location: loc, length: min(record.selectionLength, len - loc)),
                                    scrollFraction: record.scrollPosition)
            session.buffers[id]?.language = record.language
            if host.activeStore === store { host.textView.setSelectedRange(store.viewState.selection) }
        }
    }

    // MARK: Open Recent

    /// The menu is built from the observed `recentURLs`; SwiftUI does not see NSDocumentController's list change.
    func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentURLs = NSDocumentController.shared.recentDocumentURLs
    }

    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
    }
}
