import AppKit

extension AppState {
    /// The `tinyedit` command's request files among opened URLs, run after its files have opened. Those that
    /// arrive before the launch gate opens wait for it, when the restored tabs are in place.
    func runCommandLineRequests(_ urls: [URL]) async {
        guard launchGateOpen else { return pendingRequestURLs.append(contentsOf: urls) }
        for url in urls {
            if let folder = FinderMenu.directory(from: url) { newTextFile(in: folder); continue }
            switch CommandLineTool.request(at: url) {
            case .pipedText(let file): await openPipedText(file)
            case .goTo(let file, let line, let column): goTo(line: line, column: column, inFileAt: file)
            case nil: Log.files.error("unreadable command line request")
            }
            removeSpooled(url)
        }
    }

    /// Finder's New Text File: an Untitled tab whose first Save starts in `folder`. An empty Untitled tab in
    /// front (the one a launch makes, say) is used instead of adding another.
    private func newTextFile(in folder: URL) {
        if let id = session.selectedBufferID, let b = session.buffers[id], b.isUntitled, !b.titleIsCustom,
           b.saveDirectory == nil, (stores[id]?.length ?? 1) == 0 {
            session.buffers[id]?.saveDirectory = folder.path
        } else {
            guard newTab(), let id = session.selectedBufferID else { return }
            session.buffers[id]?.saveDirectory = folder.path
        }
        flushImmediately()
    }

    /// Requests held back while the launch gate was closed.
    func runPendingCommandLineRequests() async {
        let queued = pendingRequestURLs
        pendingRequestURLs = []
        if !queued.isEmpty { await runCommandLineRequests(queued) }
    }

    /// Text piped into `tinyedit`, read like a file (encoding detection, CR folded), in a new Untitled tab.
    /// It is then offered what a paste that fills a tab is: a language, Format JSON, escape-code cleanup.
    private func openPipedText(_ url: URL) async {
        let started = access.start(url)
        defer { if started { access.stop(url) } }
        defer { removeSpooled(url) }   // first, while the scope is still open
        let loaded: LoadedFile
        do {
            loaded = try await Task.detached(priority: .userInitiated) { try FileLoader.load(from: url) }.value
        } catch FileOpenError.fileTooLarge(let bytes) {
            return await offerLargeFileHead(url, name: String(localized: "Piped text"), bytes: bytes)
        } catch {
            return showToast(String(localized: "Could not open file"), error: true)
        }
        let text = loaded.logicalLF
        guard !text.isEmpty, openTranslationTab(text), let id = session.selectedBufferID, let store = stores[id] else { return }
        let scripted = EditorLanguage.detect(fileName: "", text: String(text.prefix(200)))
        if scripted != .plain { setLanguage(scripted) }
        schedulePasteRecognition(store, pasted: NSRange(location: 0, length: store.length), fillsTab: true)
    }

    /// Selects the file's tab and puts the caret on the line, as Go to Line does.
    private func goTo(line: Int, column: Int?, inFileAt url: URL) {
        if let id = bufferID(for: url), let doc = largeFiles[id] {
            selectTab(id)
            // The line may not be indexed yet: wait for it, up to 10 s.
            Task {
                for _ in 0..<100 where doc.progress.lines < line && !doc.progress.complete {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = doc.goTo(line: line)
                refreshLargeStatus()
            }
            return
        }
        guard let id = bufferID(for: url), let store = stores[id] else { return }
        selectTab(id)
        host.activate(store, settings: settings)
        let caret = caretOffset(line: line, column: column, in: store)
        host.textView.setSelectedRange(NSRange(location: caret, length: 0))
        // After the scroll position `activate` restores on the next turn.
        DispatchQueue.main.async { [weak self, weak store] in
            guard let self, let store, self.host.activeStore === store, caret <= store.length else { return }
            self.host.reveal(offset: caret)
        }
    }

    /// Request files are the script's to make and ours to remove once read; anything else is left alone.
    private func removeSpooled(_ url: URL) {
        guard CommandLineTool.isSpooled(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
