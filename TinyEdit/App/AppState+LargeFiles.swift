import AppKit

/// How a file is opened: by size (`LargeFilePolicy.threshold`), or as the user chose.
enum OpenMode: Sendable {
    case automatic
    case editor
    case large
}

/// The status bar of a large-file tab. Written only when it changes; indexing pushes it a few times a second.
struct LargeFileStatus: Equatable {
    struct Filter: Equatable {
        var rows: Int?
        var capped: Bool
    }

    var bytes: Int
    var lines: Int
    /// Share of the file indexed, while it is being read.
    var indexed: Double?
    var opening: Bool
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var editedRows: Int
    var follow: Bool
    var saving: Double?
    var line: Int?
    var hasSelection: Bool
    var canEdit: Bool
    var canOpenInEditor: Bool
    var checkingEdits: Bool
    var filter: Filter?
}

/// The text Edit Lines shows in its sheet, and the file rows it replaces.
struct LargeFileLineEditRequest: Identifiable, Equatable {
    let id = UUID()
    var documentID: UUID
    var rows: ClosedRange<Int>
    var firstLine: Int
    var lastLine: Int
    var text: String
}

extension AppState: LargeFileViewDelegate {
    var activeLargeFile: LargeFileDocument? { session.selectedBufferID.flatMap { largeFiles[$0] } }

    /// Line commands, text tools and the rest of the editor's commands do nothing in a large-file tab.
    var editorCommandsDisabled: Bool { selectedBuffer?.largeFile != nil }

    /// What the text host shows while a large-file tab is up: an empty buffer, so a command that reaches the
    /// hidden text view cannot change another tab.
    var editorHostStore: BufferTextStore? {
        if let store = activeStore { return store }
        guard selectedBuffer?.largeFile != nil else { return nil }
        if blankStore == nil { blankStore = BufferTextStore(id: UUID(), text: "", settings: settings) }
        return blankStore
    }

    // MARK: Opening

    /// Opens `url` (its scope already started) in a new large-file tab and returns the tab.
    func openLargeFile(_ url: URL) async throws -> UUID {
        let (source, encoding) = try await LargeFileDocument.openSource(url, encoding: nil)
        let bookmark = try access.bookmark(for: url)
        var b = EditorBuffer(title: url.lastPathComponent)
        b.fileBookmark = bookmark
        b.rememberFileURL(url)
        b.encoding = encoding
        b.largeFile = LargeFileMeta()
        b.diskFileSize = source.size
        let doc = makeLargeFile(for: b)
        doc.attach(source, encoding: encoding)
        session.buffers[b.id] = b
        session.tabOrder.append(b.id)
        registerFile(id: b.id, url: url)
        noteRecentDocument(url)
        LargeFileMemory.start()
        return b.id
    }

    @discardableResult
    func makeLargeFile(for buffer: EditorBuffer, edits: LargeFileEdits = LargeFileEdits()) -> LargeFileDocument {
        let id = buffer.id
        let doc = LargeFileDocument(id: id, encoding: buffer.encoding)
        doc.restore(edits: edits, meta: buffer.largeFile ?? LargeFileMeta())
        doc.onStatusChanged = { [weak self] in self?.largeFileStatusChanged(id) }
        doc.onDisplayChanged = { [weak self] in
            if self?.session.selectedBufferID == id { self?.largeView.refresh() }
        }
        doc.onEditsChanged = { [weak self] in self?.largeFileEditsChanged(id) }
        doc.onDiskEvent = { [weak self] in self?.scheduleLargeFileDiskCheck(id) }
        doc.onFindCount = { [weak self] count in
            if self?.session.selectedBufferID == id { self?.setFindCounts(count, nil, false) }
        }
        doc.onEditsMismatch = { [weak self] in
            guard let self, self.session.buffers[id] != nil else { return }
            self.session.buffers[id]?.conflict = .external
            self.flushImmediately()
        }
        largeFiles[id] = doc
        return doc
    }

    /// File ▸ Open as Large File…: any file, any size, in the large-file view.
    func beginOpenAsLargeFilePanel() {
        guard launchGateOpen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await openURLsAsync(panel.urls, mode: .large) }
    }

    /// The status bar's Open in Editor, for a file the editor can hold: the tab is replaced in place.
    func openLargeFileInEditor() {
        guard let id = session.selectedBufferID, let doc = largeFiles[id], !doc.hasEdits, doc.pendingEdits == nil,
              doc.fileSize <= FileLoader.maxOpenBytes, let url = fileURLs[id] else { return }
        let order = session.tabOrder
        let next = order.firstIndex(of: id).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
        let started = access.start(url)
        removeBuffer(id, rememberClosed: false, refill: false)
        Task {
            await openURLsAsync([url], mode: .editor)
            if started { access.stop(url) }
            if let new = bufferID(for: url), let next, session.buffers[next] != nil { moveTab(new, before: next) }
        }
    }

    // MARK: Selection and status

    /// The large-file tab became the visible one.
    func activateLargeFile(_ doc: LargeFileDocument) {
        doc.ensureOpen(fileURLs[doc.id])
        doc.highlightsMatches = find.visible
        if find.visible { doc.setQuery(find.query, caseSensitive: find.caseSensitive, regex: find.regex) }
        doc.refreshFind()
        if find.filterLines != doc.isFiltering { find.filterLines = doc.isFiltering }
        setSelectionStats(nil)
        setJSONCaret(nil)
        refreshLargeStatus()
        largeView.refresh()
        let id = doc.id
        if doc.isOpen { Task { await largeFileDiskChanged(id) } }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.selectedBufferID == id else { return }
            self.window?.makeFirstResponder(self.largeView)
        }
    }

    func largeFileStatusChanged(_ id: UUID) {
        guard let doc = largeFiles[id] else { return }
        if doc.isOpen, session.buffers[id]?.lineEnding != doc.lineEnding { session.buffers[id]?.lineEnding = doc.lineEnding }
        if doc.isOpen, session.buffers[id]?.encoding != doc.encoding { session.buffers[id]?.encoding = doc.encoding }
        if id == session.selectedBufferID { refreshLargeStatus() }
    }

    func refreshLargeStatus() {
        guard let doc = activeLargeFile else {
            if largeStatus != nil { largeStatus = nil }
            return
        }
        let p = doc.progress
        let size = doc.fileSize
        let line = doc.head.flatMap { doc.line(atVisual: $0.row) }
        let status = LargeFileStatus(
            bytes: size, lines: p.lines,
            indexed: p.complete || !doc.isOpen ? nil : size > 0 ? min(Double(p.scannedBytes) / Double(size), 1) : 0,
            opening: !doc.isOpen, encoding: doc.encoding, lineEnding: doc.lineEnding, editedRows: doc.edits.count,
            follow: doc.follow, saving: doc.saveProgress, line: line, hasSelection: doc.hasSelection, canEdit: doc.canEdit,
            canOpenInEditor: doc.isOpen && size <= FileLoader.maxOpenBytes && !doc.hasEdits && doc.pendingEdits == nil,
            checkingEdits: doc.pendingEdits != nil && !doc.editsMismatch,
            filter: doc.isFiltering ? LargeFileStatus.Filter(rows: doc.filterRunning ? nil : doc.filterRows?.count,
                                                              capped: doc.filterCapped) : nil)
        if status != largeStatus { largeStatus = status }
    }

    func setLargeFileFollow(_ on: Bool) {
        activeLargeFile?.setFollow(on)
    }

    // MARK: Edits

    func largeFileEditsChanged(_ id: UUID) {
        guard let doc = largeFiles[id] else { return }
        let dirty = doc.hasEdits || doc.pendingEdits != nil
        if session.buffers[id]?.dirty != dirty { session.buffers[id]?.dirty = dirty }
        scheduleFlush()
        if id == session.selectedBufferID { refreshLargeStatus() }
    }

    /// Why an edit cannot happen now, said once.
    private func largeFileEditBlocked(_ doc: LargeFileDocument) -> Bool {
        guard !doc.canEdit else { return false }
        if doc.isFiltering {
            showToast(String(localized: "Show all lines to edit."))
        } else if doc.editsMismatch {
            return true
        } else if doc.isSaving {
            return true
        } else {
            showToast(String(localized: "Available once the whole file has been read."))
        }
        return true
    }

    func largeFileEditLines() {
        guard let doc = activeLargeFile, doc.head != nil, !largeFileEditBlocked(doc) else { return }
        guard let target = doc.editTarget() else {
            return showToast(String(localized: "Too much to edit here. Use Open in New Tab."))
        }
        let first = doc.baseRow(target.rows.lowerBound)?.line ?? 1
        let last = doc.baseRow(target.rows.upperBound)?.line ?? first
        largeLineEdit = LargeFileLineEditRequest(documentID: doc.id, rows: target.rows, firstLine: first, lastLine: last,
                                                 text: target.text)
    }

    func applyLargeLineEdit(_ request: LargeFileLineEditRequest, text: String) {
        largeLineEdit = nil
        let text = LineEnding.normalizeToLF(text)
        // Apply without a change is no edit: the rows would count as edited and the tab as unsaved.
        guard let doc = largeFiles[request.documentID], doc.canEdit, text != request.text else {
            focusLargeView()
            return
        }
        if !doc.replaceRows(request.rows, with: text, actionName: String(localized: "Edit Lines")) {
            showToast(String(localized: "Too many edited lines. Save first, then go on."))
        }
        focusLargeView()
    }

    func cancelLargeLineEdit() {
        largeLineEdit = nil
        focusLargeView()
    }

    func largeFileDeleteLines() {
        guard let doc = activeLargeFile, doc.hasSelection, !largeFileEditBlocked(doc),
              let rows = doc.editTarget()?.rows else { return }
        if !doc.replaceRows(rows, with: nil, actionName: String(localized: "Delete Lines")) {
            showToast(String(localized: "Too many edited lines. Save first, then go on."))
        }
    }

    func largeFileDeleteNeedsWholeLines() {
        showToast(String(localized: "Delete removes whole lines. Select from the start of a line to its end, or use Delete Lines."))
    }

    func largeFileOpenSelection() {
        guard let doc = activeLargeFile, doc.hasSelection, let (a, b) = doc.selectionRange else { return }
        guard let text = doc.selectedText() else {
            return showToast(String(localized: "The selection is too large. Up to \(Self.byteSize(LargeFilePolicy.copyLimit)) can be copied or opened."))
        }
        let name = selectedBuffer?.displayTitle ?? ""
        let first = doc.line(atVisual: a.row) ?? 1
        let last = doc.line(atVisual: b.row) ?? first
        let title = first == last ? String(localized: "\(name) (line \(first))") : String(localized: "\(name) (lines \(first)–\(last))")
        Task {
            // One JSON record (a JSON Lines log, a line of an export) opens formatted, as a JSON tab.
            let json = await Task.detached(priority: .userInitiated) { Self.formattedJSONLine(text) }.value
            guard openTranslationTab(json ?? text), let id = session.selectedBufferID, let store = stores[id] else { return }
            renameTab(id, to: title)
            if json != nil {
                setLanguage(.json)
            } else {
                schedulePasteRecognition(store, pasted: NSRange(location: 0, length: store.length), fillsTab: true)
            }
        }
    }

    /// `text` pretty-printed when it is one line holding a JSON object or array.
    nonisolated static func formattedJSONLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = trimmed.first, c == "{" || c == "[", !trimmed.contains("\n"),
              case .formatted(let pretty, _) = JSONFormatter.format(text: trimmed, selection: nil) else { return nil }
        return pretty
    }

    func largeFileCopy() {
        guard let doc = activeLargeFile, doc.hasSelection else { return }
        guard let text = doc.selectedText() else {
            return showToast(String(localized: "The selection is too large. Up to \(Self.byteSize(LargeFilePolicy.copyLimit)) can be copied or opened."))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func largeFileTypedWhileReadOnly() {
        guard Date().timeIntervalSince(lastReadOnlyHint) > 4 else { return }
        lastReadOnlyHint = Date()
        showToast(String(localized: "This view is read-only. Press Return to edit the selected lines."))
    }

    func largeFileJumpFromFilter() {
        guard let doc = activeLargeFile, doc.isFiltering else { return }
        doc.setFilter(false)
        if find.filterLines { find.filterLines = false }
        refreshLargeStatus()
    }

    func largeFileSelectionChanged() {
        refreshLargeStatus()
    }

    @discardableResult
    func focusLargeView() -> Bool {
        guard activeLargeFile != nil, let window else { return false }
        window.makeFirstResponder(largeView)
        return true
    }

    // MARK: Find

    func largeFindNext(forward: Bool) {
        guard let doc = activeLargeFile else { return }
        if !find.visible { showFind(replace: false) }
        guard doc.progress.complete else {
            return showToast(String(localized: "Available once the whole file has been read."))
        }
        doc.highlightsMatches = true
        doc.setQuery(find.query, caseSensitive: find.caseSensitive, regex: find.regex)
        Task {
            _ = await doc.find(forward: forward)
            refreshLargeStatus()
        }
    }

    func largeReplaceCurrent() {
        guard let doc = activeLargeFile, !find.query.isEmpty else { return }
        if doc.selectionIsMatch, !largeFileEditBlocked(doc) {
            if !doc.replaceSelection(with: LineEnding.normalizeToLF(find.replacement)) {
                showToast(String(localized: "Too many edited lines. Save first, then go on."))
            }
        }
        largeFindNext(forward: true)
    }

    func largeReplaceAll() {
        guard let doc = activeLargeFile, !find.query.isEmpty, !largeFileEditBlocked(doc) else { return }
        let replacement = LineEnding.normalizeToLF(find.replacement)
        let id = doc.id
        let generation = doc.generation
        Task {
            if let result = await doc.replaceAllEdits(with: replacement) {
                // Made from the edits (and file) as they were: an edit or reload since then would be overwritten.
                guard !result.edits.isEmpty, doc.generation == generation, doc.canEdit else { return }
                if doc.apply(result.edits, actionName: String(localized: "Replace All")) {
                    showToast(String(localized: "Replaced \(result.count)"))
                    return
                }
            }
            await replaceAllIntoNewFile(id, replacement: replacement)
        }
    }

    /// More lines match than edits can hold: the replaced file is written out by Save As.
    private func replaceAllIntoNewFile(_ id: UUID, replacement: String) async {
        guard let doc = largeFiles[id], let q = doc.query else { return }
        if q.isRegex {
            return showToast(String(localized: "Too many lines to replace with a regular expression. Up to 10,000 lines can be replaced at once."))
        }
        if q.regex != nil {
            // GB18030 text is searched decoded, never as bytes, so it cannot be replaced while the file streams.
            return showToast(String(localized: "Too many lines to replace in this encoding. Up to 10,000 lines can be replaced at once."))
        }
        if doc.hasEdits {
            return showToast(String(localized: "Too many lines to replace here. Save your edits first."))
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Too many lines to replace here")
        alert.informativeText = String(localized: "TinyEdit can write the file with every match replaced. Choose where to save it.")
        alert.addButton(withTitle: String(localized: "Save As…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let bytes = LargeFileText.encode(doc.lineEnding == .crlf ? replacement.replacingOccurrences(of: "\n", with: "\r\n") : replacement,
                                               doc.encoding) else { return }
        await saveAsFlow(id, replacement: LargeFileReplacement(query: q, bytes: bytes))
    }

    func setLargeFilter(_ on: Bool) {
        guard let doc = activeLargeFile else { return }
        if on, find.query.isEmpty { return }
        if find.filterLines != on { find.filterLines = on }
        doc.highlightsMatches = find.visible
        doc.setQuery(find.query, caseSensitive: find.caseSensitive, regex: find.regex)
        doc.setFilter(on)
        refreshLargeStatus()
    }

    // MARK: Disk

    /// At most one check every 300 ms, never pushed back by the next event: a log written more often than that
    /// (most busy ones) must still be read on while it is being written.
    func scheduleLargeFileDiskCheck(_ id: UUID) {
        guard largeDiskTasks[id] == nil else { return }
        largeDiskTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.largeDiskTasks[id] = nil
            await self.largeFileDiskChanged(id)
        }
    }

    /// The file was appended to, replaced, rewritten, moved or deleted.
    func largeFileDiskChanged(_ id: UUID) async {
        guard let doc = largeFiles[id], doc.isOpen, !savingIDs.contains(id), let url = fileURLs[id],
              let buffer = session.buffers[id] else { return }
        switch doc.diskChange(at: url.path) {
        case .none:
            break
        case .appended:
            doc.appended()
            session.buffers[id]?.diskFileSize = doc.fileSize
        case .reload:
            guard await doc.reload(url) else { return }
            session.buffers[id]?.conflict = .none
            session.buffers[id]?.diskFileSize = doc.fileSize
            if id == session.selectedBufferID { showToast(reloadedToast(buffer.displayTitle, nil)) }
            flushImmediately()
        case .conflict(let canSaveAs):
            doc.conflictCanSaveAs = canSaveAs
            if buffer.conflict != .external {
                session.buffers[id]?.conflict = .external
                flushImmediately()
            }
        case .missing:
            if let moved = doc.source?.currentPath, moved != url.path, FileManager.default.fileExists(atPath: moved) {
                handleMoved(id, to: URL(fileURLWithPath: moved))
            } else if buffer.conflict != .missing {
                session.buffers[id]?.conflict = .missing
                flushImmediately()
            }
        }
        if id == session.selectedBufferID { refreshLargeStatus() }
    }

    /// Reload From Disk: the file as it is now; edits (also ones that no longer match) are dropped.
    func reloadLargeFile(_ id: UUID) async {
        guard let doc = largeFiles[id], let url = fileURLs[id] else { return }
        doc.discardMismatchedEdits()
        guard await doc.reload(url) else { return showToast(String(localized: "Could not open file"), error: true) }
        session.buffers[id]?.conflict = .none
        session.buffers[id]?.dirty = false
        flushImmediately()
        refreshLargeStatus()
    }

    func copyLargeFileEdits(_ id: UUID) {
        guard let doc = largeFiles[id] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(doc.snapshotEdits.summaryText, forType: .string)
        showToast(String(localized: "Copied"))
    }

    var largeFileBanner: BannerModel? {
        guard let b = selectedBuffer, let doc = largeFiles[b.id] else { return nil }
        switch b.conflict {
        case .none:
            return nil
        case .external:
            let keep = doc.conflictCanSaveAs && !doc.editsMismatch
                ? BannerAction(title: String(localized: "Save As…"), action: .saveAs)
                : BannerAction(title: String(localized: "Copy Edits"), action: .copyEdits)
            return BannerModel(text: String(localized: "\(b.displayTitle) changed on disk."), actions: [
                BannerAction(title: String(localized: "Reload From Disk"), action: .reloadFromDisk), keep,
            ])
        case .missing:
            return BannerModel(text: String(localized: "File is missing: \(b.displayTitle)."),
                               actions: [BannerAction(title: String(localized: "Save As…"), action: .saveAs)])
        }
    }

    // MARK: Save

    /// Streams the file with its edits (or a Replace All) to `url` and reads the result back in.
    func performLargeSave(id: UUID, url: URL, overwrite: Bool, presenter: NSFilePresenter?,
                          replacement: LargeFileReplacement?) async -> SaveOutcome {
        guard let doc = largeFiles[id] else { return .failed }
        if doc.editsMismatch {
            showToast(String(localized: "The file changed where your edits are. Copy Edits, then Reload From Disk."), error: true)
            return .failed
        }
        if doc.pendingEdits != nil || !doc.isOpen {
            // A restored tab that was never shown has not started reading its file: start now.
            doc.ensureOpen(fileURLs[id])
            showToast(String(localized: "Available once the whole file has been read."))
            return .failed
        }
        if session.buffers[id]?.conflict == .external, !doc.conflictCanSaveAs {
            showToast(String(localized: "Could not save file"), error: true)
            return .failed
        }
        savingIDs.insert(id)
        defer { savingIDs.remove(id) }
        if id == session.selectedBufferID { refreshLargeStatus() }
        switch await doc.save(to: url, overwrite: overwrite, presenter: presenter, replacement: replacement) {
        case .success:
            _ = await doc.reload(url)
            session.buffers[id]?.conflict = .none
            session.buffers[id]?.dirty = false
            session.buffers[id]?.diskFileSize = doc.fileSize
            showToast(String(localized: "Saved \(url.lastPathComponent)"))
            noteRecentDocument(url)
            flushImmediately()
            return .saved
        case .failure(.externalChange):
            // Save As to another file that changed during the write: nothing was written, and this tab's own file
            // did not change.
            guard let own = fileURLs[id], FileAccessManager.key(own) == FileAccessManager.key(url) else {
                showToast(String(localized: "Could not save file"), error: true)
                return .failed
            }
            session.buffers[id]?.conflict = .external
            return .conflict
        case .failure(.editsNoLongerMatch):
            // Rewritten in place: the edits' original bytes are gone, so neither Overwrite nor Save As can apply them.
            doc.conflictCanSaveAs = false
            session.buffers[id]?.conflict = .external
            flushImmediately()
            if id == session.selectedBufferID { refreshLargeStatus() }
            showToast(String(localized: "The file changed where your edits are. Copy Edits, then Reload From Disk."), error: true)
            return .failed
        case .failure(.notEnoughSpace(let needed)):
            showToast(String(localized: "Not enough disk space to save. It needs about \(Self.byteSize(needed)) free."), error: true)
            return .failed
        case .failure:
            showToast(String(localized: "Could not save file"), error: true)
            return .failed
        }
    }

    // MARK: Memory

    /// Two minutes after a large-file tab is out of sight (another tab, or the app in the background), the
    /// blocks it read are let go. The index stays, so coming back draws at once.
    func scheduleLargeFileTrim() {
        largeTrimTask?.cancel()
        guard !largeFiles.isEmpty else { return }
        largeTrimTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            self.trimLargeFiles(releaseIndex: false)
        }
    }

    /// Under memory pressure the caches go at once, and on critical pressure the hidden tabs' indexes too.
    func trimLargeFiles(releaseIndex: Bool) {
        let visible = NSApp.isActive && window?.isVisible == true ? session.selectedBufferID : nil
        for (id, doc) in largeFiles where id != visible { doc.trim(releaseIndex: releaseIndex) }
    }
}

/// The memory-pressure source shared by every window's large-file tabs.
@MainActor
enum LargeFileMemory {
    private static var source: DispatchSourceMemoryPressure?

    static func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak s] in
            let critical = s?.data.contains(.critical) ?? false
            MainActor.assumeIsolated {
                for window in Workspaces.shared.all { window.trimLargeFiles(releaseIndex: critical) }
            }
        }
        s.resume()
        source = s
    }
}

extension AppState {
    static func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// For toasts where a file is too large for the editor (reload, reopen with an encoding).
    static func tooLargeMessage(_ name: String, bytes: Int) -> String {
        String(localized: "“\(name)” is \(byteSize(bytes)). TinyEdit opens files up to \(byteSize(FileLoader.maxOpenBytes)).")
    }
}

/// Piped text over the editor's limit: its spool file is deleted once read, so it cannot stay open in the
/// large-file view. Its beginning can open as an Untitled tab instead.
extension AppState {
    static let largeFileHeadBytes = 2 * 1_048_576

    /// Asks, then opens the first `largeFileHeadBytes` of `url` in a new Untitled tab named after `name`.
    func offerLargeFileHead(_ url: URL, name: String, bytes: Int) async {
        let head = Self.byteSize(Self.largeFileHeadBytes)
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” is too large to open")
        alert.informativeText = String(localized: "It is \(Self.byteSize(bytes)). TinyEdit opens files up to \(Self.byteSize(FileLoader.maxOpenBytes)). Its first \(head) can open in a new Untitled tab, which is not linked to the file.")
        alert.addButton(withTitle: String(localized: "Open First \(head)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, ensureRoomForTab() else { return }

        let started = access.start(url)
        defer { if started { access.stop(url) } }
        let limit = Self.largeFileHeadBytes
        guard let loaded = try? await Task.detached(priority: .userInitiated, operation: {
            try FileLoader.loadHead(of: url, maxBytes: limit)
        }).value else {
            return showToast(String(localized: "Could not open file"), error: true)
        }
        guard !closing, !transferring, openTranslationTab(loaded.logicalLF), let id = session.selectedBufferID else { return }
        renameTab(id, to: String(localized: "\(name) (first \(head))"))
        let language = EditorLanguage.detect(fileName: name, text: String(loaded.logicalLF.prefix(200)))
        if language != .plain { setLanguage(language) }
    }
}
