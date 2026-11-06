import AppKit

extension AppState {
    /// Replace the buffer with the disk version and acknowledge it. Used by
    /// Reload From Disk / Use Disk Version and Reopen with Encoding.
    /// The replacement is synchronous; afterwards the lines that differ from the replaced text are diffed
    /// off the main thread and marked in the gutter. Returns those changes, or nil when the text was too
    /// large to compare or was edited before the diff finished. Reopen with Encoding passes `markChanges: false`:
    /// the same bytes read another way are not changed lines.
    @discardableResult
    func applyDiskVersion(_ loaded: LoadedFile, to id: UUID, markChanges: Bool = true) async -> LineChanges? {
        guard let store = stores[id], var b = session.buffers[id] else { return nil }
        let old = store.logicalString()
        store.replaceLogicalText(loaded.logicalLF, recordUndo: false, settings: settings)
        b.encoding = loaded.encoding
        b.lineEnding = loaded.lineEnding
        b.lastSavedContentHash = loaded.logicalHash
        b.diskContentHash = loaded.rawHash
        b.diskFileSize = loaded.byteSize
        b.diskModificationDate = loaded.modificationDate
        b.conflict = .none
        b.dirty = false
        b.pasteSuggestion = nil
        pasteTasks[id]?.cancel()
        pasteTasks[id] = nil
        pasteTokens[id, default: 0] &+= 1
        b.cursorLocation = 0
        b.selectionLength = 0
        b.scrollPosition = 0
        session.buffers[id] = b
        store.viewState = .init()
        if id == session.selectedBufferID {
            host.textView.setSelectedRange(NSRange(location: 0, length: 0))
            host.textView.scrollToBeginningOfDocument(nil)
            highlight.schedule(store: store, language: b.language, delay: .zero)
            schedulePreview(delay: .zero)
            refreshFindMatches(delay: .zero)
            refreshTaskCounts(id)
            refreshStatus()
        }
        flushImmediately()
        guard markChanges else {
            if host.activeStore === store { host.ruler?.needsDisplay = true }
            return nil
        }

        let gen = store.generation
        let new = loaded.logicalLF
        let changes = await Task.detached(priority: .utility) { LineDiff.changes(from: old, to: new) }.value
        guard let changes, stores[id] === store, store.generation == gen else { return nil }
        store.changeMarkers = changes.markers
        if host.activeStore === store { host.ruler?.needsDisplay = true }
        return changes
    }

    func reloadedToast(_ title: String, _ changes: LineChanges?) -> String {
        String(localized: "Reloaded: \(title)") + (changes?.summary.map { " (\($0))" } ?? "")
    }

    /// In-session `presentedItemDidChange`, after self-write filtering (hash compare plus save-in-flight wait).
    func handleExternalChange(_ id: UUID) async {
        var waits = 0
        while savingIDs.contains(id), waits < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waits += 1
        }
        guard !savingIDs.contains(id), let url = fileURLs[id], let buffer = session.buffers[id] else { return }
        let acknowledgedHash = buffer.diskContentHash
        let encoding = buffer.encoding
        let loaded = await Task.detached(priority: .utility) { try? FileLoader.load(from: url, decoding: .prefer(encoding)) }.value
        // A save, reload or relocation during the read makes this result obsolete.
        guard !savingIDs.contains(id), fileURLs[id] == url,
              let current = session.buffers[id], current.diskContentHash == acknowledgedHash else { return }
        guard let loaded else {
            if !FileManager.default.fileExists(atPath: url.path), current.conflict != .missing {
                session.buffers[id]?.conflict = .missing
                flushImmediately()
            }
            return
        }
        if loaded.rawHash == acknowledgedHash { return } // our own write, or no real change
        // Keep the text, selection, undo history and acknowledged disk hash until the user chooses.
        // Bytes other than the ones a Keep My Version was about bring the banner back.
        switch current.externalChange {
        case let change? where change.hash == loaded.rawHash:
            break
        case let change? where change.hash == nil && change.kept:
            session.buffers[id]?.externalChange?.hash = loaded.rawHash
        default:
            session.buffers[id]?.externalChange = ExternalChange(hash: loaded.rawHash)
        }
        if current.conflict != .external {
            session.buffers[id]?.conflict = .external
            Log.files.info("conflict ->external")
            flushImmediately()
        }
    }

    /// Recheck on focus as well as presenter notifications: other programs may replace the file
    /// without coordinated writes. Reading and hashing happen off the main thread.
    func checkSelectedFileForExternalChanges() async {
        guard launchGateOpen, let id = session.selectedBufferID else { return }
        await handleExternalChange(id)
    }

    func handleDeleted(_ id: UUID) async {
        // Atomic-replace saves from other tools look like delete+create. Give the new file a moment.
        try? await Task.sleep(for: .milliseconds(300))
        guard let url = fileURLs[id], session.buffers[id] != nil else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            await handleExternalChange(id)
        } else {
            session.buffers[id]?.conflict = .missing
            Log.files.info("conflict ->missing")
            flushImmediately()
        }
    }

    func handleMoved(_ id: UUID, to newURL: URL) {
        guard session.buffers[id] != nil else { return }
        let old = fileURLs[id]
        _ = access.start(newURL)
        if let bm = try? access.bookmark(for: newURL) { session.buffers[id]?.fileBookmark = bm }
        session.buffers[id]?.rememberFileURL(newURL)
        session.buffers[id]?.title = newURL.lastPathComponent
        fileURLs[id] = newURL
        monitors[id]?.update(url: newURL)
        if let old { access.stop(old) }
        flushImmediately()
    }

    func applyConflictAction(_ action: ConflictAction) {
        guard let id = session.selectedBufferID else { return }
        switch action {
        case .reloadFromDisk:
            Task { await reloadFromDisk(id) }
        case .keepMyVersion:
            // The conflict stays, so the tab keeps its warning glyph; only the banner hides.
            let hash = session.buffers[id]?.externalChange?.hash
            session.buffers[id]?.externalChange = ExternalChange(hash: hash, kept: true)
        case .saveAs:
            Task { _ = await saveAsFlow(id) }
        case .relocate:
            relocate(id)
        }
    }

    func reloadFromDisk(_ id: UUID) async {
        guard let url = fileURLs[id], let encoding = session.buffers[id]?.encoding, let store = stores[id] else { return }
        let gen = store.generation
        let loaded = await Task.detached(priority: .userInitiated) { try? FileLoader.load(from: url, decoding: .prefer(encoding)) }.value
        guard let loaded else {
            showToast(String(localized: "Could not open file"), error: true)
            return
        }
        guard textUnchanged(id, store: store, since: gen) else { return }
        await applyDiskVersion(loaded, to: id)
    }

    /// A reload replaces the text without undo, so it applies only to the text the user agreed to replace:
    /// an edit made while the file was being read cancels it. Checked right before `applyDiskVersion`,
    /// whose replacement happens before its first `await`.
    func textUnchanged(_ id: UUID, store: BufferTextStore, since gen: UInt64) -> Bool {
        guard session.buffers[id] != nil, stores[id] === store else { return false }
        if store.generation == gen { return true }
        showToast(String(localized: "Not reloaded: the tab was edited while the file was being read"), error: true)
        return false
    }

    /// In-session rebind for a live buffer whose bookmark failed. Never replaces the text.
    func relocate(_ id: UUID) {
        guard let b = session.buffers[id] else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Locate “\(b.displayTitle)”")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        unregisterFile(id)
        _ = access.start(url)
        guard let bm = try? access.bookmark(for: url) else {
            showToast(String(localized: "Bookmark failed"), error: true)
            return
        }
        session.buffers[id]?.fileBookmark = bm
        session.buffers[id]?.rememberFileURL(url)
        registerFile(id: id, url: url)
        bookmarkBroken.remove(id)
        Task {
            let loaded = await Task.detached { try? FileLoader.load(from: url) }.value
            // Compare with the acknowledged hash without clearing a stored external conflict.
            if let loaded, loaded.rawHash != self.session.buffers[id]?.diskContentHash {
                self.session.buffers[id]?.conflict = .external
            }
            self.flushImmediately()
        }
    }
}
