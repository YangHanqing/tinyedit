import AppKit

private final class OneShot: @unchecked Sendable {
    var done = false
}

extension AppState {
    // MARK: Manifest

    /// Merges live cursor and scroll from the stores. Copies metadata only, never text.
    func makeManifest() -> SessionFile {
        var snapshot = session
        for (id, store) in stores {
            snapshot.buffers[id]?.cursorLocation = store.viewState.selection.location
            snapshot.buffers[id]?.selectionLength = store.viewState.selection.length
            snapshot.buffers[id]?.scrollPosition = store.viewState.scrollFraction
        }
        for (id, doc) in largeFiles where snapshot.buffers[id] != nil {
            snapshot.buffers[id]?.largeFile = LargeFileMeta(topRow: doc.topRow.rounded(.down), follow: doc.follow)
        }
        return SessionFile(session: snapshot)
    }

    private func nextSeq() -> UInt64 {
        manifestSeq += 1
        return manifestSeq
    }

    /// Items whose generation has not been written yet. Copies strings only when the generation changed.
    private func pendingItems() -> [FlushItem] {
        stores.values.compactMap { store in
            guard session.buffers[store.id] != nil, writtenGeneration[store.id] != store.generation else { return nil }
            return FlushItem(id: store.id, generation: store.generation, logicalLF: store.logicalString())
        } + largeFiles.values.compactMap { doc in
            // A large-file tab's snapshot is its edits, never the file.
            guard session.buffers[doc.id] != nil, writtenGeneration[doc.id] != doc.generation else { return nil }
            return FlushItem(id: doc.id, generation: doc.generation, logicalLF: doc.snapshotEdits.snapshotText())
        }
    }

    // MARK: Flush

    /// Debounced: 500 ms after the last edit, selection change, or other session change.
    func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushImmediately()
        }
    }

    /// No-ops until the launch gate is open, so an early scene-phase change cannot replace a good
    /// session.json with an empty session.
    func flushImmediately() {
        guard launchGateOpen else { return }
        Task { await performFlush() }
    }

    /// Captures on the main actor, then waits for the recovery actor. Tests await this.
    @discardableResult
    func performFlush() async -> Bool {
        guard launchGateOpen else { return false }
        flushTask?.cancel()
        host.captureViewState()
        let items = pendingItems()
        let manifest = makeManifest()
        let seq = nextSeq()
        let out = await recoveryActor.flush(items: items, manifest: manifest, seq: seq)
        handleOutcome(out)
        return out.ok
    }

    func handleOutcome(_ out: FlushOutcome) {
        for (id, gen) in out.written where stores[id] != nil || largeFiles[id] != nil { writtenGeneration[id] = gen }
        if out.ok {
            recoveryFailing = false
            // Recovery works again: the next Quit must flush, not offer the lossy exit from an old refusal.
            terminationRefused = false
        } else if !recoveryFailing {
            recoveryFailing = true // one toast per continuous failure episode
            showToast(out.diskFull ? String(localized: "Recovery save failed (disk full)") : String(localized: "Recovery save failed"), error: true)
        }
    }

    // MARK: Quit

    /// `applicationShouldTerminate`. Copies from the stores on the main actor first, returns
    /// `.terminateLater`, and replies true only once every current generation is renamed into place.
    func handleTerminate(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard launchGateOpen else { return .terminateNow }
        if terminationRefused {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit without saving recovery data?")
            alert.informativeText = String(localized: "TinyEdit could not write your unsaved text to disk. Quitting now can lose recent edits.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            alert.buttons[1].hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }

        let flush = prepareTerminationFlush()
        let shot = OneShot()

        Task { [weak self] in
            let out = await flush()
            guard !shot.done else { return }
            shot.done = true
            if out.ok {
                reply(true)
            } else {
                self?.terminationRefused = true
                self?.handleOutcome(out)
                reply(false)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !shot.done else { return }
            shot.done = true
            self?.terminationRefused = true
            self?.showToast(String(localized: "Recovery save failed"), error: true)
            reply(false)
        }
        return .terminateLater
    }

    /// Copies every pending generation and the manifest now, on the main actor; the returned job writes them.
    /// Quit runs one per window.
    func prepareTerminationFlush() -> @Sendable () async -> FlushOutcome {
        flushTask?.cancel()
        host.captureViewState()
        let items = pendingItems()
        let manifest = makeManifest()
        let seq = nextSeq()
        let actor = recoveryActor
        return { await actor.flush(items: items, manifest: manifest, seq: seq) }
    }

    // MARK: Close Window

    /// Red button and Close Window: flush, hide, keep the process and every store alive.
    func hideWindow(_ window: NSWindow?) {
        flushImmediately()
        window?.orderOut(nil)
    }

    /// New Tab while the red button has hidden the window brings it back.
    func showWindow() {
        guard let window else { return }
        // Selecting a tab in the front window needs no window presentation or animation.
        guard !window.isVisible || window.isMiniaturized || !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// `⌘N` and `⌘T`: a tab in this window, shown again if the red button hid it.
    func newTabInWindow() {
        showWindow()
        newTab()
    }

    // MARK: Launch restore

    func restore() async {
        loadWorkspace()
        let sessions = SessionStore(root: root)
        let recovery = RecoveryStore(root: root)
        let plan = await Task.detached(priority: .userInitiated) {
            RestorePlanner.plan(sessions: sessions, recovery: recovery)
        }.value

        session.closedTabs = plan.closedTabs
        session.tombstones = plan.tombstones

        for entry in plan.entries {
            var buffer: EditorBuffer
            if let meta = entry.metadata, let b = meta.makeBuffer() {
                buffer = b
                if buffer.fileBookmark != nil { attachRestoredFile(&buffer) }
            } else {
                recoveredCounter += 1
                // English in the session. `displayTitle` localizes "Recovered N".
                buffer = EditorBuffer(id: entry.id, title: "Recovered \(recoveredCounter)")
                buffer.dirty = true
            }
            if !settings.suggestLanguageWhileTyping { buffer.languageSuggestion = nil }
            if buffer.largeFile != nil {
                if let edits = LargeFileEdits.fromSnapshot(entry.text) {
                    makeLargeFile(for: buffer, edits: edits)
                    LargeFileMemory.start()
                    session.buffers[buffer.id] = buffer
                    session.tabOrder.append(buffer.id)
                    continue
                }
                // An unreadable edits snapshot is kept as text, never applied to the file.
                unregisterFile(buffer.id)
                recoveredCounter += 1
                buffer = EditorBuffer(id: entry.id, title: "Recovered \(recoveredCounter)")
                buffer.dirty = true
            }
            makeStore(for: buffer, text: entry.text)
            session.buffers[buffer.id] = buffer
            session.tabOrder.append(buffer.id)
        }
        session.keepPinnedFirst()   // an entry the manifest's order missed is appended last
        if let sel = plan.selectedID, session.buffers[sel] != nil {
            session.selectedBufferID = sel
        } else {
            session.selectedBufferID = session.tabOrder.first
        }

        // Files that changed on disk while the app was closed are checked before the gate opens.
        for id in session.tabOrder where fileURLs[id] != nil || session.buffers[id]?.fileBookmark != nil {
            await verifyRestoredFile(id)
        }

        let queued = pendingURLs
        pendingURLs = []
        if !queued.isEmpty { await openURLsAsync(queued) }

        // Piped text opened at launch is the first tab, after the gate opens.
        let pipedPending = pendingRequestURLs.contains { $0.pathExtension == CommandLineTool.pipeExtension }
        if session.tabOrder.isEmpty && !pipedPending {
            let buffer = EditorBuffer(title: "Untitled")
            makeStore(for: buffer, text: "")
            session.buffers[buffer.id] = buffer
            session.tabOrder = [buffer.id]
            session.selectedBufferID = buffer.id
        }

        await recoveryActor.setLaunchGateOpen(true)
        launchGateOpen = true
        if !plan.tombstonedFilesToDelete.isEmpty { await recoveryActor.deleteTombstoned(plan.tombstonedFilesToDelete) }
        flushImmediately()
        activeBufferChanged()
        await runPendingCommandLineRequests()
        if session.tabOrder.isEmpty { newTab() }
        DispatchQueue.main.async { [host] in host.focus() }
    }

    /// Resolve the bookmark, start access, refresh a stale bookmark, register the presenter.
    /// A failed resolve keeps the snapshot text and shows the Relocate banner.
    func attachRestoredFile(_ buffer: inout EditorBuffer) {
        guard let data = buffer.fileBookmark else { return }
        do {
            let (url, stale) = try access.resolve(data)
            guard access.start(url) else {
                bookmarkBroken.insert(buffer.id)
                Log.files.error("startAccessing failed on restore")
                return
            }
            if stale, let fresh = try? access.bookmark(for: url) { buffer.fileBookmark = fresh }
            registerFile(id: buffer.id, url: url)
            buffer.rememberFileURL(url)
        } catch {
            let code = (error as NSError).code
            Log.files.error("bookmark resolve failed: \(code)")
            // A bookmark to a deleted file fails with NSFileReadCorruptFileError (259) or no-such-file.
            if code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError || code == NSFileReadCorruptFileError {
                // The file is gone, not the permission: keep the text and offer Save As.
                buffer.conflict = .missing
            } else {
                bookmarkBroken.insert(buffer.id)
            }
        }
    }

    /// The manifest's `diskContentHash` is the last acknowledged disk generation. Launch never treats a
    /// fresh stat as an acknowledgement.
    private func verifyRestoredFile(_ id: UUID) async {
        guard fileURLs[id] != nil, let buffer = session.buffers[id], stores[id] != nil else { return }
        if buffer.conflict != .none { return } // stored external/missing is kept even if bytes now match
        await handleExternalChange(id)
    }
}
