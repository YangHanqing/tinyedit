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
    func performFlush() async {
        guard launchGateOpen else { return }
        flushTask?.cancel()
        host.captureViewState()
        let items = pendingItems()
        let manifest = makeManifest()
        let seq = nextSeq()
        let out = await recoveryActor.flush(items: items, manifest: manifest, seq: seq)
        handleOutcome(out)
    }

    func handleOutcome(_ out: FlushOutcome) {
        for (id, gen) in out.written where stores[id] != nil { writtenGeneration[id] = gen }
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

        flushTask?.cancel()
        host.captureViewState()
        let items = pendingItems()
        let manifest = makeManifest()
        let seq = nextSeq()
        let shot = OneShot()

        Task { [weak self, recoveryActor] in
            let out = await recoveryActor.flush(items: items, manifest: manifest, seq: seq)
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

    // MARK: Close Window

    /// Red button and Close Window: flush, hide, keep the process and every store alive.
    func hideWindow(_ window: NSWindow?) {
        flushImmediately()
        window?.orderOut(nil)
    }

    /// New Tab while the red button has hidden the window brings it back.
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// `⌘T` and `⌘N` (there is one window, so New is a tab).
    func newTabInWindow() {
        showWindow()
        newTab()
    }

    // MARK: Launch restore

    func restore() async {
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
            makeStore(for: buffer, text: entry.text)
            session.buffers[buffer.id] = buffer
            session.tabOrder.append(buffer.id)
        }
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

        if session.tabOrder.isEmpty {
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
        DispatchQueue.main.async { [host] in host.focus() }
    }

    /// Resolve the bookmark, start access, refresh a stale bookmark, register the presenter.
    /// A failed resolve keeps the snapshot text and shows the Relocate banner.
    private func attachRestoredFile(_ buffer: inout EditorBuffer) {
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
