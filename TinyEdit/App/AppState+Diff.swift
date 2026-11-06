import AppKit

/// One side of a comparison, as the diff header names it.
struct DiffSide: Equatable {
    var title: String
    /// Directory shown when both sides have the same name.
    var directory: String?
    var encoding: TextEncoding?
    var lineEnding: LineEnding?
    /// Not an open tab's text but the file read from disk.
    var fromDisk = false
}

/// The comparison shown over the editor: read-only, session-only, never a tab. The source tab's editor stays as
/// it was underneath; closing the view only removes it.
struct DiffSession: Identifiable {
    let id = UUID()
    /// The tab Compare With was chosen on. Selecting another tab closes the comparison.
    let sourceID: UUID
    /// The other tab, when the target is one.
    let targetID: UUID?
    /// The file read from disk, when the target is one.
    let fileURL: URL?
    var old: DiffSide
    var new: DiffSide
    /// Nil while it is being computed.
    var result: UnifiedDiff?
    /// The compared texts were edited after the comparison was made.
    var stale = false
    var current = 0
    /// Bumped by Previous / Next and on first show, so the view scrolls even to the same change.
    var scrollToken = 0

    /// What differs besides the text: encoding, line ending, the final newline.
    var notes: [String] {
        var out: [String] = []
        if let a = old.encoding, let b = new.encoding, a != b {
            out.append(String(localized: "Encoding: \(a.statusLabel) → \(b.statusLabel)"))
        }
        if let a = old.lineEnding, let b = new.lineEnding, a != b {
            out.append(String(localized: "Line endings: \(a.statusLabel) → \(b.statusLabel)"))
        }
        if result?.finalNewlineDiffers == true { out.append(String(localized: "Only the final newline differs")) }
        if result?.aligned == false { out.append(String(localized: "Too many differences to align line by line")) }
        return out
    }
}

enum CompareTarget {
    case tab(UUID)
    case file(URL)
}

extension AppState {
    /// The tabs a tab can be compared with: every other tab in this window, in order.
    func compareCandidates(for id: UUID) -> [EditorBuffer] {
        session.orderedBuffers.filter { $0.id != id }
    }

    func compare(_ sourceID: UUID, with target: CompareTarget) {
        guard let source = session.buffers[sourceID], let sourceStore = stores[sourceID] else { return }
        if case .tab(let other) = target, other == sourceID { return }
        Task { await compareAsync(source: source, store: sourceStore, target: target) }
    }

    /// Choose File… for a comparison. The file is read, never opened as a tab.
    func chooseFileToCompare(_ sourceID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let name = session.buffers[sourceID]?.displayTitle {
            panel.message = String(localized: "Choose a file to compare with “\(name)”")
        }
        panel.prompt = String(localized: "Compare")
        if let dir = fileURLs[sourceID]?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compare(sourceID, with: .file(url))
    }

    private func compareAsync(source: EditorBuffer, store: BufferTextStore, target: CompareTarget) async {
        // The source text is taken now, before anything awaits: what the editor holds at the moment of choosing.
        let oldText = store.logicalString()
        var old = DiffSide(title: source.displayTitle, directory: source.directoryPath,
                           encoding: source.encoding, lineEnding: source.lineEnding)
        var new: DiffSide
        let newText: String, targetID: UUID?, fileURL: URL?
        switch target {
        case .tab(let id):
            guard let b = session.buffers[id], let s = stores[id] else { return }
            newText = s.logicalString()
            new = DiffSide(title: b.displayTitle, directory: b.directoryPath, encoding: b.encoding, lineEnding: b.lineEnding)
            targetID = id
            fileURL = nil
        case .file(let url):
            let loaded = await Task.detached(priority: .userInitiated) { () -> Result<LoadedFile, FileOpenError> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { return .success(try FileLoader.load(from: url)) } catch let e as FileOpenError { return .failure(e) } catch {
                    return .failure(.couldNotOpenFile)
                }
            }.value
            switch loaded {
            case .success(let file):
                newText = file.logicalLF
                new = DiffSide(title: url.lastPathComponent, directory: TitlePathFormatting.directory(ofFile: url),
                               encoding: file.encoding, lineEnding: file.lineEnding, fromDisk: true)
            case .failure(.fileTooLarge):
                return showToast(String(localized: "“\(url.lastPathComponent)” is too large to compare."), error: true)
            case .failure:
                return showToast(String(localized: "“\(url.lastPathComponent)” couldn’t be read as text."), error: true)
            }
            targetID = nil
            fileURL = url
        }
        guard session.buffers[source.id] != nil else { return }
        guard oldText.utf16.count <= TextDiff.sizeLimit, newText.utf16.count <= TextDiff.sizeLimit else {
            return showToast(String(localized: "Texts over 8 MB are too large to compare."), error: true)
        }
        // Same names: the directory tells them apart. Untitled tabs have none.
        if old.title != new.title {
            old.directory = nil
            new.directory = nil
        }

        hidePalette()
        if session.selectedBufferID != source.id { selectTab(source.id) }
        closeDiff(refocus: false)
        window?.makeFirstResponder(nil)   // typing must not reach the editor hidden underneath
        diff = DiffSession(sourceID: source.id, targetID: targetID, fileURL: fileURL, old: old, new: new)
        let token = diff?.id
        diffTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { TextDiff.make(old: oldText, new: newText) }.value
            guard let self, !Task.isCancelled, self.diff?.id == token else { return }
            guard let result else {
                self.closeDiff()
                return self.showToast(String(localized: "Texts over 8 MB are too large to compare."), error: true)
            }
            self.diff?.result = result
            self.diff?.scrollToken += 1
        }
    }

    /// Done, Escape, another tab selected or the source tab closed.
    func closeDiff(refocus: Bool = true) {
        guard diff != nil else { return }
        diffTask?.cancel()
        diffTask = nil
        diff = nil
        if refocus { host.focus() }
    }

    /// Previous (−1) / Next (+1), wrapping around.
    func stepDiff(_ step: Int) {
        guard let count = diff?.result?.changes.count, count > 0, let current = diff?.current else { return }
        diff?.current = ((current + step) % count + count) % count
        diff?.scrollToken += 1
    }

    /// The comparison is a snapshot: an edit to either tab only marks it out of date (written once).
    func diffTextEdited(_ id: UUID) {
        guard let d = diff, !d.stale, d.sourceID == id || d.targetID == id else { return }
        diff?.stale = true
    }

    /// Compares the same two sides again with their current text. A file target is read again.
    func refreshDiff() {
        guard let d = diff else { return }
        if let t = d.targetID {
            compare(d.sourceID, with: .tab(t))
        } else if let url = d.fileURL {
            compare(d.sourceID, with: .file(url))
        }
    }

    /// The command palette's second step: a tab or a file to compare the selected tab with.
    func showComparePalette() {
        guard let id = session.selectedBufferID else { return }
        // After the palette that chose this has gone, so the field starts empty and takes focus again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paletteCompareSource = id
            self.paletteOnSelection = false
            self.paletteInsights = nil
            self.paletteVisible = true
        }
    }

    var paletteCompareCommands: [PaletteCommand] {
        guard let source = paletteCompareSource else { return [] }
        let candidates = compareCandidates(for: source)
        let titles = TabMenuTitles.make(session.orderedBuffers)
        let category = String(localized: "Compare With")
        return candidates.map { b in
            let id = b.id
            return PaletteCommand(id: "compare." + id.uuidString, title: titles[id] ?? b.displayTitle, englishTitle: b.title,
                                  keywords: "tab 标签 " + (b.directoryPath ?? ""), category: category) { [weak self] in
                self?.compare(source, with: .tab(id))
            }
        } + [
            PaletteCommand(id: "compare.file", title: String(localized: "Choose File…"), englishTitle: "Choose File",
                           keywords: "file disk open 文件 磁盘", category: category) { [weak self] in
                self?.chooseFileToCompare(source)
            },
        ]
    }
}
