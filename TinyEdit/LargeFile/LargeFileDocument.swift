import AppKit

/// Files over this open in the large-file view; smaller ones in the editor. Measured: the editor opens a
/// 16 MB log in 0.4 s and a 64 MB one (its limit) in about 2 s, before layout.
enum LargeFilePolicy {
    static let threshold = 16 * 1_048_576
    /// Copy, Open in New Tab and the text of Edit Lines stop here.
    static let copyLimit = 16 * 1_048_576
    /// Show Only Matching Lines lists at most this many rows.
    static let filterLimit = 1_000_000
}

/// A large-file tab's state in the session manifest. Its edits are in its snapshot (`LargeFileEdits`).
struct LargeFileMeta: Codable, Equatable, Sendable {
    var topRow: Double = 0
    var follow = false
}

/// A place in the rows on screen (`row` counts the rows shown, which a filter narrows) and a UTF-16 column.
struct LargeFilePosition: Comparable, Sendable {
    var row: Int
    var column: Int

    static func < (a: Self, b: Self) -> Bool { a.row != b.row ? a.row < b.row : a.column < b.column }
}

/// One row as drawn.
struct LargeFileVisibleRow {
    var text: String
    /// The file's line number, on the first row of a line; nil on the rest of a long line and on added lines.
    var line: Int?
    var edited: Bool
    /// Followed by a line break (false inside a long line).
    var endsLine: Bool
}

/// What the file did on disk, as far as the tab is concerned.
enum LargeFileDiskChange: Equatable {
    case none
    case appended
    /// Replaced, truncated or rewritten, with no edits to lose.
    case reload
    /// The same, with edits. Save As can still write them when the old file is intact (replaced, not rewritten).
    case conflict(canSaveAs: Bool)
    case missing
}

/// The engine of a large-file tab: the file through `LargeFileSource`, rows through `LargeFileIndex`, edits,
/// find, filter, and what the view shows. Opened lazily: a restored tab reads nothing until it is selected.
@MainActor
final class LargeFileDocument {
    let id: UUID
    private(set) var source: LargeFileSource?
    private(set) var index: LargeFileIndex?
    private(set) var encoding: TextEncoding
    private(set) var lineEnding: LineEnding = .lf
    private(set) var edits = LargeFileEdits()
    /// Restored (or moved-in) edits, applied once the index is complete and their rows still hold what they replaced.
    private(set) var pendingEdits: LargeFileEdits?
    /// The pending edits did not match the file: kept for Copy Edits, never applied.
    private(set) var editsMismatch = false
    let undoManager = UndoManager()
    /// Bumped on every edit change, for the recovery writer.
    private(set) var generation: UInt64 = 1
    /// The file as last read or saved; a change from it is an external change.
    private(set) var acknowledged: LargeFileFingerprint?
    private(set) var progress = LargeFileIndex.Progress(rows: 0, lines: 0, scannedBytes: 0, complete: false)
    private(set) var isOpening = false
    private(set) var saveProgress: Double?
    var conflictCanSaveAs = true

    // MARK: View state (not observed)
    var topRow: Double = 0
    var xOffset: CGFloat = 0
    var anchor: LargeFilePosition?
    var head: LargeFilePosition?
    var follow = false
    /// Rows that fit the view, set by the view on layout; follow keeps the last one in view with it.
    var viewportRows = 40
    /// Bumped whenever the rows drawn may differ (edits, filter, reload, query): the view's line cache key.
    private(set) var displayVersion = 0

    // MARK: Find and filter
    private(set) var query: LargeFileQuery?
    var highlightsMatches = false
    private(set) var filterRows: [Int]?
    private(set) var filterCapped = false
    private(set) var filterRunning = false
    /// The match Find Next last went to, in display rows. A click clears it.
    var currentMatch: (row: Int, range: NSRange)?
    /// The row an append reopened (the old last row) and where it starts, until the find refresh after the scan.
    private var appendedTail: Tail?
    /// The last count, split at the last row (where an append resumes), so an append only searches what it added.
    private var countCache: (key: FindKey, tail: Tail, before: Int)?
    /// What the shown filter rows were made from, and the last row then: an append that reopens exactly that
    /// row only adds rows.
    private var filterCache: (key: FindKey, tail: Tail)?

    struct Tail: Equatable {
        var row: Int
        var offset: Int
    }

    private struct FindKey: Equatable {
        var query: LargeFileQuery
        var edits: LargeFileEdits
    }

    private var scanTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    /// Samples of the bytes indexed so far: a file that grew but no longer holds them was rewritten, not appended to.
    private var witnesses: [(offset: Int, bytes: Data)] = []
    private var lastStatusPush = Date.distantPast

    var onStatusChanged: (() -> Void)?
    var onDisplayChanged: (() -> Void)?
    var onEditsChanged: (() -> Void)?
    var onDiskEvent: (() -> Void)?
    var onFindCount: ((Int?) -> Void)?
    var onEditsMismatch: (() -> Void)?

    init(id: UUID, encoding: TextEncoding) {
        self.id = id
        self.encoding = encoding
    }

    var isOpen: Bool { source != nil }
    var hasEdits: Bool { !edits.isEmpty }
    /// What the snapshot holds: applied edits, or ones still waiting for their check.
    var snapshotEdits: LargeFileEdits { pendingEdits ?? edits }
    var isSaving: Bool { saveProgress != nil }
    var canEdit: Bool { isOpen && progress.complete && pendingEdits == nil && !editsMismatch && filterRows == nil && !isSaving }
    var fileSize: Int { source?.size ?? acknowledged?.size ?? 0 }
    var baseRows: Int { progress.rows }
    var displayRows: Int { edits.displayCount(baseRows: baseRows) }
    var visualRows: Int { filterRows?.count ?? displayRows }
    var isFiltering: Bool { filterRows != nil || filterRunning }

    // MARK: Opening

    /// Opens the descriptor and detects the encoding (it reads up to 3 MB) off the main thread.
    nonisolated static func openSource(_ url: URL, encoding: TextEncoding?) async throws -> (LargeFileSource, TextEncoding) {
        try await Task.detached(priority: .userInitiated) {
            let source = try LargeFileSource(url: url)
            return (source, encoding ?? LargeFileText.detectEncoding(source: source))
        }.value
    }

    func attach(_ source: LargeFileSource, encoding: TextEncoding) {
        close()
        self.source = source
        self.encoding = encoding
        index = LargeFileIndex(encoding: encoding)
        progress = LargeFileIndex.Progress(rows: 0, lines: 0, scannedBytes: 0, complete: false)
        acknowledged = source.fingerprint
        displayVersion += 1
        appendedTail = nil
        countCache = nil
        filterCache = nil
        // Reopened with another encoding: the query's bytes (or decoded search) follow it.
        if let q = query, q.encoding != encoding {
            query = LargeFileQuery(q.text, caseSensitive: q.caseSensitive, regex: q.isRegex, encoding: encoding)
        }
        takeWitnesses(upTo: source.size)
        startWatching()
        startScan()
    }

    /// For a restored or moved-in tab: the edits to check once the file is indexed.
    func restore(edits: LargeFileEdits, meta: LargeFileMeta) {
        if !edits.isEmpty { pendingEdits = edits }
        topRow = meta.topRow
        follow = meta.follow
    }

    /// Opens a restored tab's file the first time it is shown. Safe to call often.
    func ensureOpen(_ url: URL?) {
        guard source == nil, !isOpening, let url else {
            if source != nil, index == nil { rebuildIndex() }
            return
        }
        isOpening = true
        Task {
            let opened = try? await Self.openSource(url, encoding: encoding)
            isOpening = false
            guard let (source, encoding) = opened else { return pushStatus(force: true) }
            attach(source, encoding: encoding)
        }
    }

    func close() {
        scanTask?.cancel(); scanTask = nil
        countTask?.cancel(); countTask = nil
        filterTask?.cancel(); filterTask = nil
        watcher?.cancel(); watcher = nil
        source = nil
        index = nil
    }

    // MARK: Indexing

    private func startScan() {
        guard let source, let index, scanTask == nil, !index.isComplete else { return }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            index.scan(source: source, isCancelled: { Task.isCancelled }) { p in
                Task { @MainActor [weak self] in self?.scanProgressed(p, index: index) }
            }
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self, self.index === index, !cancelled else { return }
                self.scanTask = nil
                self.scanFinished(index)
            }
        }
    }

    private func scanProgressed(_ p: LargeFileIndex.Progress, index: LargeFileIndex) {
        guard self.index === index, p.rows >= progress.rows else { return }
        let first = progress.rows == 0
        progress = p
        if first { detectLineEnding() }
        if follow { scrollToEnd() }
        pushStatus(force: false)
        onDisplayChanged?()
    }

    private func scanFinished(_ index: LargeFileIndex) {
        progress = index.progress
        detectLineEnding()
        // Rewritten while it was read: the index is of two files. The disk check reloads it.
        guard witnessesHold() else { onDiskEvent?(); return }
        takeWitnesses(upTo: progress.scannedBytes)
        // Bytes appended while the scan ran were read by it: the file as it is now is the one shown. Else the
        // next event would see the same size with a newer date, a rewrite, and read the whole file again.
        if let now = source?.fingerprint, now.size == progress.scannedBytes { acknowledged = now }
        if let pendingEdits, let source {
            if pendingEdits.matches(source: source, index: index) {
                edits = pendingEdits
                displayVersion += 1
            } else {
                editsMismatch = true
                conflictCanSaveAs = false
                onEditsMismatch?()
            }
            self.pendingEdits = editsMismatch ? pendingEdits : nil
        }
        if follow { scrollToEnd() }
        // Bytes written while the last chunk was read.
        if let source, source.size > progress.scannedBytes { return appended() }
        let tail = appendedTail
        appendedTail = nil
        refreshFind(appendedFrom: tail)
        pushStatus(force: true)
        onDisplayChanged?()
    }

    /// The more common ending of the lines read so far (all of them once the scan is done), as the editor decides.
    private func detectLineEnding() {
        guard let index else { return }
        let (crlf, lf) = index.lineEndings
        lineEnding = crlf > lf ? .crlf : .lf
    }

    /// Up to three 4 KB samples (start, middle, end) of `0..<end`.
    private func takeWitnesses(upTo end: Int) {
        guard let source else { return witnesses = [] }
        let n = 4096
        let offsets = Set([0, max(end / 2 - n / 2, 0), max(end - n, 0)]).sorted()
        witnesses = offsets.map { ($0, source.readDirect(offset: $0, count: min(n, end - $0))) }
    }

    private func witnessesHold() -> Bool {
        guard let source else { return false }
        return witnesses.allSatisfy { source.readDirect(offset: $0.offset, count: $0.bytes.count) == $0.bytes }
    }

    /// The memory tiers: the caches go when the tab is out of sight for a while, the index too under memory pressure.
    func trim(releaseIndex: Bool) {
        source?.dropCache()
        index?.dropCache()
        guard releaseIndex, !isSaving, !filterRunning, pendingEdits == nil, index?.isComplete == true else { return }
        scanTask?.cancel(); scanTask = nil
        index = nil
    }

    private func rebuildIndex() {
        guard source != nil else { return }
        index = LargeFileIndex(encoding: encoding)
        progress = LargeFileIndex.Progress(rows: 0, lines: 0, scannedBytes: 0, complete: false)
        displayVersion += 1
        startScan()
    }

    // MARK: Disk

    private func startWatching() {
        guard let source else { return }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: source.descriptor,
                                                          eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
                                                          queue: .main)
        w.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onDiskEvent?() }
        }
        w.resume()
        watcher = w
    }

    /// How the file at `path` differs from what the tab shows. While the index is still being built nothing is
    /// decided: the scan reads to the end, and an append during it is picked up when it finishes.
    func diskChange(at path: String) -> LargeFileDiskChange {
        guard let source, let index, !isSaving else { return .none }
        guard let now = LargeFileFingerprint.of(path: path) else { return .missing }
        let edited = hasEdits || pendingEdits != nil
        guard let read = source.fingerprint, now.isSameFile(as: read) else {
            return edited ? .conflict(canSaveAs: true) : .reload
        }
        let indexed = progress.scannedBytes
        // Rewritten in place (truncated and written again, copytruncate): what was read is not there any more.
        if now.size < indexed || !witnessesHold() { return edited ? .conflict(canSaveAs: false) : .reload }
        guard progress.complete else { return .none }
        if now.size > indexed { return .appended }
        guard now.modified != acknowledged?.modified else { return .none }
        // Same size, newer date: rewritten in place, or only touched.
        if !edited { return .reload }
        if edits.matches(source: source, index: index) {
            acknowledged = now
            return .none
        }
        return .conflict(canSaveAs: false)
    }

    /// The file grew: read on from its old last row.
    func appended() {
        guard let source, let index, index.isComplete else { return }
        source.dropBlocks(from: progress.scannedBytes)
        index.reopenTail()
        progress = index.progress
        // The reopened row; with several appends before the refresh, the first one's.
        let tail = Tail(row: progress.rows, offset: progress.scannedBytes)
        if appendedTail.map({ $0.row > tail.row }) ?? true { appendedTail = tail }
        acknowledged = source.fingerprint
        // The view caches rows by number: the old last row (often the empty one after the final break) now differs.
        displayVersion += 1
        startScan()
    }

    /// Reads the file again from scratch (after a save, Reload From Disk, or a replaced file). Edits are dropped.
    func reload(_ url: URL, encoding newEncoding: TextEncoding? = nil) async -> Bool {
        guard let (source, encoding) = try? await Self.openSource(url, encoding: newEncoding ?? encoding) else { return false }
        edits = LargeFileEdits()
        pendingEdits = nil
        editsMismatch = false
        conflictCanSaveAs = true
        undoManager.removeAllActions()
        generation += 1
        filterRows = nil
        filterCapped = false
        currentMatch = nil
        anchor = nil
        head = nil
        attach(source, encoding: encoding)
        onEditsChanged?()
        return true
    }

    /// The pending edits that did not match are given up (Reload From Disk keeps the file as it is).
    func discardMismatchedEdits() {
        pendingEdits = nil
        editsMismatch = false
        conflictCanSaveAs = true
        generation += 1
        onEditsChanged?()
        pushStatus(force: true)
    }

    // MARK: Rows

    func displayRow(forVisual row: Int) -> Int? {
        guard row >= 0 else { return nil }
        if let filterRows { return row < filterRows.count ? filterRows[row] : nil }
        return row < displayRows ? row : nil
    }

    func visualRow(forDisplay row: Int) -> Int {
        guard let filterRows else { return row }
        var lo = 0, hi = filterRows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if filterRows[mid] < row { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, max(filterRows.count - 1, 0))
    }

    func baseRow(_ row: Int) -> LargeFileRow? {
        guard let source, let index else { return nil }
        return index.row(row, source: source)
    }

    func content(of row: LargeFileRow) -> String {
        guard let source else { return "" }
        return LargeFileText.decode(source.read(offset: row.start, count: row.contentEnd - row.start), encoding)
    }

    func visibleRow(_ visual: Int) -> LargeFileVisibleRow? {
        guard let display = displayRow(forVisual: visual) else { return nil }
        let (base, editLine) = edits.locate(display)
        if let editLine, let e = edits.edit(forRow: base), editLine < e.lines.count {
            let line = editLine == 0 ? baseRow(base).map(\.line) : nil
            let endsLine = editLine < e.lines.count - 1 || e.end > e.contentEnd
            return LargeFileVisibleRow(text: e.lines[editLine], line: line, edited: true, endsLine: endsLine)
        }
        guard let row = baseRow(base) else { return nil }
        return LargeFileVisibleRow(text: content(of: row), line: row.startsLine ? row.line : nil, edited: false,
                                   endsLine: row.hasLineEnding)
    }

    /// The file's line at a visual row (the line a piece of a long line belongs to).
    func line(atVisual visual: Int) -> Int? {
        guard let display = displayRow(forVisual: visual) else { return nil }
        return baseRow(edits.locate(display).row)?.line
    }

    var selectionRange: (LargeFilePosition, LargeFilePosition)? {
        guard let anchor, let head else { return nil }
        return anchor < head ? (anchor, head) : (head, anchor)
    }

    var hasSelection: Bool {
        guard let (a, b) = selectionRange else { return false }
        return a != b
    }

    /// The selection runs from the start of a row to the end of a row (or the start of the next).
    var selectionIsWholeRows: Bool {
        guard let (a, b) = selectionRange, a != b, a.column == 0 else { return false }
        if b.column == 0, b.row > a.row { return true }
        return b.column >= ((visibleRow(b.row)?.text as NSString?)?.length ?? 0)
    }

    /// Rows the selection covers; one ending at the start of a row does not take that row.
    var selectedVisualRows: ClosedRange<Int>? {
        guard let (a, b) = selectionRange else { return nil }
        let last = b.column == 0 && b.row > a.row ? b.row - 1 : b.row
        return a.row...max(last, a.row)
    }

    /// The selected text, or nil when it is more than `limit` bytes (checked before anything is read).
    func selectedText(limit: Int = LargeFilePolicy.copyLimit) -> String? {
        guard let (a, b) = selectionRange else { return "" }
        if filterRows == nil, let ra = displayRow(forVisual: a.row), let rb = displayRow(forVisual: b.row),
           let first = baseRow(edits.locate(ra).row), let last = baseRow(edits.locate(rb).row),
           last.end - first.start > limit * 2 {
            return nil
        }
        if b.row - a.row > 2_000_000 { return nil }
        var out = ""
        var bytes = 0
        for visual in a.row...b.row {
            guard let row = visibleRow(visual) else { break }
            let ns = row.text as NSString
            let from = visual == a.row ? min(a.column, ns.length) : 0
            let to = visual == b.row ? min(b.column, ns.length) : ns.length
            if to > from { out += ns.substring(with: NSRange(location: from, length: to - from)) }
            if visual < b.row, row.endsLine || filterRows != nil { out += "\n" }
            bytes += (to - from) + 1
            if bytes > limit { return nil }
        }
        return out
    }

    func selectAll() {
        guard visualRows > 0 else { return }
        anchor = LargeFilePosition(row: 0, column: 0)
        let last = visualRows - 1
        head = LargeFilePosition(row: last, column: (visibleRow(last)?.text as NSString?)?.length ?? 0)
        onDisplayChanged?()
        pushStatus(force: true)
    }

    // MARK: Scrolling

    func maxTopRow() -> Double { Double(max(visualRows - viewportRows + 1, 0)) }

    func scrollToEnd() {
        topRow = maxTopRow()
        onDisplayChanged?()
    }

    /// Brings a visual row to the upper third, unless it is already in view.
    func reveal(visual row: Int) {
        let r = Double(row)
        if r < topRow || r > topRow + Double(viewportRows) - 2 {
            topRow = min(max(r - Double(viewportRows) / 3, 0), maxTopRow())
        }
        onDisplayChanged?()
    }

    func setFollow(_ on: Bool) {
        guard follow != on else { return }
        follow = on
        if on { scrollToEnd() }
        pushStatus(force: true)
    }

    // MARK: Go to line

    /// The visual row of 1-based `line` of the file (in a filter, the nearest listed row).
    func visualRow(forLine line: Int) -> Int? {
        guard let source, let index, progress.rows > 0 else { return nil }
        let base = index.row(forLine: max(line, 1), source: source)
        return visualRow(forDisplay: edits.displayRow(forBase: base))
    }

    func goTo(line: Int) -> Bool {
        guard let row = visualRow(forLine: line) else { return false }
        anchor = LargeFilePosition(row: row, column: 0)
        head = anchor
        topRow = min(max(Double(row) - Double(viewportRows) / 3, 0), maxTopRow())
        onDisplayChanged?()
        pushStatus(force: true)
        return true
    }

    // MARK: Status

    /// Throttled while indexing: the status bar is written at most a few times a second.
    func pushStatus(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusPush) > 0.25 else { return }
        lastStatusPush = now
        onStatusChanged?()
    }

    // MARK: Edits

    /// The rows Edit Lines would change, and their current text joined by line breaks.
    func editTarget() -> (rows: ClosedRange<Int>, text: String)? {
        guard canEdit, let visual = selectedVisualRows ?? head.map({ $0.row...$0.row }),
              let da = displayRow(forVisual: visual.lowerBound), let db = displayRow(forVisual: visual.upperBound) else { return nil }
        let rows = edits.locate(da).row...edits.locate(db).row
        guard rows.count <= LargeFileEdits.maxRows else { return nil }
        var text = ""
        for r in rows {
            if let e = edits.edit(forRow: r) {
                if e.lines.isEmpty { continue }
                text += e.lines.joined(separator: "\n")
                if r < rows.upperBound, e.end > e.contentEnd { text += "\n" }
            } else if let row = baseRow(r) {
                text += content(of: row)
                if r < rows.upperBound, row.hasLineEnding { text += "\n" }
            }
            if text.utf8.count > LargeFileEdits.maxEditBytes { return nil }
        }
        return (rows, text)
    }

    /// Replaces file rows `rows` with `text` (nil removes them), as one undo step. False when there would be
    /// more edited rows than `LargeFileEdits.maxRows`.
    @discardableResult
    func replaceRows(_ rows: ClosedRange<Int>, with text: String?, actionName: String) -> Bool {
        guard let source else { return false }
        var changes: [LargeFileEdit] = []
        for r in rows {
            let lines: [String] = r == rows.upperBound ? (text.map { $0.components(separatedBy: "\n") } ?? []) : []
            if let e = edits.edit(forRow: r) {
                var c = e
                c.lines = lines
                changes.append(c)
            } else if let row = baseRow(r) {
                let original = source.readDirect(offset: row.start, count: row.end - row.start)
                changes.append(LargeFileEdit(row: r, start: row.start, contentEnd: row.contentEnd, end: row.end,
                                             hash: ContentHash.sha256Hex(original), lines: lines))
            }
        }
        return apply(changes, actionName: actionName)
    }

    /// Edits whose text is the row's own again stop being edits.
    func apply(_ changes: [LargeFileEdit], actionName: String) -> Bool {
        var next = edits
        let added = changes.filter { next.edit(forRow: $0.row) == nil }.count
        guard next.count + added <= LargeFileEdits.maxRows else { return false }
        next.apply(changes)
        var unchanged: [Int] = []
        for c in changes where c.lines.count == 1 {
            if let row = baseRow(c.row), row.end - row.start < 64 * 1024, content(of: row) == c.lines[0] { unchanged.append(c.row) }
        }
        if !unchanged.isEmpty { next.remove(rows: Set(unchanged)) }
        setEdits(next, actionName: actionName)
        return true
    }

    private func setEdits(_ new: LargeFileEdits, actionName: String) {
        let old = edits
        guard new != old else { return }
        edits = new
        generation += 1
        displayVersion += 1
        currentMatch = nil
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.setEdits(old, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        onEditsChanged?()
        refreshFind()
        pushStatus(force: true)
        onDisplayChanged?()
    }

    // MARK: Find

    func setQuery(_ text: String, caseSensitive: Bool, regex: Bool) {
        let q = LargeFileQuery(text, caseSensitive: caseSensitive, regex: regex, encoding: encoding)
        guard q != query else { return }
        query = q
        currentMatch = nil
        displayVersion += 1
        refreshFind()
        onDisplayChanged?()
    }

    /// Regular-expression queries search decoded rows, in display order.
    private func regexScanner(_ q: LargeFileQuery) -> LargeFileRegexScanner? {
        guard let regex = q.regex, let source, let index else { return nil }
        return LargeFileRegexScanner(source: source, index: index, edits: edits, regex: regex, encoding: encoding,
                                     displayRows: displayRows)
    }

    /// The last row and where it starts: an append reopens it.
    private var currentTail: Tail? {
        guard progress.rows > 0, let row = baseRow(progress.rows - 1) else { return nil }
        return Tail(row: progress.rows - 1, offset: row.start)
    }

    /// Recounts (and refilters) after the query, the edits or the file changed. After an append (`tail`, the
    /// row it reopened) only the rows from there are searched, when what is shown was made from the same query
    /// and edits and no edit is on those rows: a log growing under an open find card is not searched whole
    /// again on every write.
    func refreshFind(appendedFrom tail: Tail? = nil) {
        countTask?.cancel()
        countTask = nil
        if filterRows != nil || filterRunning { runFilter(appendedFrom: tail) }
        guard highlightsMatches, let q = query, let source, let index, progress.complete, let newTail = currentTail else {
            countCache = nil
            onFindCount?(nil)
            return
        }
        let edits = self.edits
        let key = FindKey(query: q, edits: edits)
        let resume: (tail: Tail, before: Int)? = if let tail, let c = countCache, c.key == key, c.tail == tail,
                                                     Self.editsEnd(before: tail, edits) { (tail, c.before) } else { nil }
        countCache = nil
        if resume == nil { onFindCount?(nil) }
        let end = progress.scannedBytes
        let start = index.splitter.bomLength
        let scanner = regexScanner(q)
        countTask = Task { [weak self] in
            // Matches before the last row, and in it: the next append goes on from the split.
            let counted = await Task.detached(priority: .utility) { () -> (before: Int, last: Int)? in
                var before = resume?.before ?? 0, last = 0
                if let scanner {
                    let from = resume.map { edits.displayRow(forBase: $0.tail.row) } ?? 0
                    let split = edits.displayRow(forBase: newTail.row)
                    scanner.forEach(from: from, isCancelled: { Task.isCancelled }) { display, _ in
                        if display < split { before += 1 } else { last += 1 }
                        return true
                    }
                    return Task.isCancelled ? nil : (before, last)
                }
                LargeFileSearch.forEachMatch(in: source, q, start: resume?.tail.offset ?? start, end: end,
                                             isCancelled: { Task.isCancelled }) { offset in
                    if edits.edit(containingOffset: offset) == nil {
                        if offset < newTail.offset { before += 1 } else { last += 1 }
                    }
                    return true
                }
                if resume == nil { for e in edits.edits { for line in e.lines { before += q.ranges(in: line).count } } }
                return Task.isCancelled ? nil : (before, last)
            }.value
            guard let self, !Task.isCancelled, let counted else { return }
            self.countCache = (key, newTail, counted.before)
            self.onFindCount?(counted.before + counted.last)
        }
    }

    /// No edit at or after `tail`'s row: the rows from there are the file's own, shifted by the edits before them.
    private nonisolated static func editsEnd(before tail: Tail, _ edits: LargeFileEdits) -> Bool {
        (edits.edits.last?.row ?? -1) < tail.row
    }

    /// Find Next / Previous from the selection, wrapping around. Selects the match and returns whether there was one.
    func find(forward: Bool) async -> Bool {
        guard let q = query, let source, let index, progress.complete else { return false }
        let from: (Int, Int)
        if let (a, b) = selectionRange, let display = displayRow(forVisual: (forward ? b : a).row) {
            from = (display, (forward ? b : a).column)
        } else {
            from = forward ? (displayRow(forVisual: Int(topRow)) ?? 0, 0) : (displayRows, 0)
        }
        let edits = self.edits
        let end = progress.scannedBytes
        let bom = index.splitter.bomLength
        let encoding = self.encoding
        let rows = progress.rows
        let scanner = regexScanner(q)
        let hit = await Task.detached(priority: .userInitiated) { () -> (Int, NSRange)? in
            if let scanner {
                if forward { return scanner.forward(display: from.0, column: from.1) ?? scanner.forward(display: 0, column: 0) }
                return scanner.backward(display: from.0, column: from.1)
                    ?? scanner.backward(display: scanner.displayRows, column: 0)
            }
            let search = LargeFileFinder(source: source, index: index, edits: edits, query: q, encoding: encoding,
                                         end: end, bom: bom, baseRows: rows)
            if forward {
                return search.forward(display: from.0, column: from.1) ?? search.forward(display: 0, column: 0)
            }
            return search.backward(display: from.0, column: from.1)
                ?? search.backward(display: edits.displayCount(baseRows: rows), column: 0)
        }.value
        guard let (display, range) = hit, self.edits == edits else { return false }
        currentMatch = (display, range)
        let visual = visualRow(forDisplay: display)
        if filterRows != nil, displayRow(forVisual: visual) != display {
            setFilter(false)
            return await find(forward: forward)
        }
        anchor = LargeFilePosition(row: visualRow(forDisplay: display), column: range.location)
        head = LargeFilePosition(row: anchor!.row, column: NSMaxRange(range))
        reveal(visual: anchor!.row)
        pushStatus(force: true)
        return true
    }

    /// The selection is exactly a match, on one row: Replace takes it.
    var selectionIsMatch: Bool {
        guard let q = query, let (a, b) = selectionRange, a.row == b.row, let row = visibleRow(a.row) else { return false }
        return q.ranges(in: row.text).contains { $0.location == a.column && NSMaxRange($0) == b.column }
    }

    /// Replaces the selected match in its row.
    func replaceSelection(with replacement: String) -> Bool {
        guard canEdit, selectionIsMatch, let (a, b) = selectionRange, let display = displayRow(forVisual: a.row),
              let row = visibleRow(a.row) else { return false }
        let (base, editLine) = edits.locate(display)
        let ns = row.text as NSString
        let match = NSRange(location: a.column, length: b.column - a.column)
        let newText = ns.replacingCharacters(in: match, with: query?.replacement(for: match, in: row.text, template: replacement)
                                             ?? replacement)
        if let editLine, var e = edits.edit(forRow: base) {
            var lines = e.lines
            lines.replaceSubrange(editLine...editLine, with: newText.components(separatedBy: "\n"))
            e.lines = lines
            return apply([e], actionName: String(localized: "Replace"))
        }
        return replaceRows(base...base, with: newText, actionName: String(localized: "Replace"))
    }

    /// The rows Replace All would change, as edits: nil when there are more than the edits can hold.
    func replaceAllEdits(with replacement: String) async -> (edits: [LargeFileEdit], count: Int)? {
        guard let q = query, let source, let index, progress.complete else { return nil }
        let edits = self.edits
        let end = progress.scannedBytes
        let start = index.splitter.bomLength
        let encoding = self.encoding
        let scanner = regexScanner(q)
        return await Task.detached(priority: .userInitiated) { () -> ([LargeFileEdit], Int)? in
            var rows: [Int] = []
            var tooMany = false
            if let scanner {
                // Display rows of unedited file rows only; the edits' lines are replaced below.
                scanner.forEach(isCancelled: { Task.isCancelled }) { display, _ in
                    let (base, line) = edits.locate(display)
                    if line != nil || rows.last == base { return true }
                    rows.append(base)
                    if rows.count + edits.count > LargeFileEdits.maxRows { tooMany = true; return false }
                    return true
                }
            } else { LargeFileSearch.forEachMatch(in: source, q, start: start, end: end, isCancelled: { Task.isCancelled }) { offset in
                if edits.edit(containingOffset: offset) != nil { return true }
                let r = index.row(containing: offset, source: source)
                if rows.last != r { rows.append(r) }
                if rows.count + edits.count > LargeFileEdits.maxRows { tooMany = true; return false }
                return true
            } }
            if tooMany || Task.isCancelled { return nil }
            var changes: [LargeFileEdit] = []
            var count = 0
            func replaced(_ text: String) -> String? {
                let n = q.ranges(in: text).count
                guard n > 0 else { return nil }
                count += n
                return q.replacing(in: text, with: replacement)
            }
            for r in rows {
                guard let row = index.row(r, source: source) else { continue }
                let original = source.readDirect(offset: row.start, count: row.end - row.start)
                let text = LargeFileText.decode(source.readDirect(offset: row.start, count: row.contentEnd - row.start), encoding)
                guard let new = replaced(text) else { continue }
                changes.append(LargeFileEdit(row: r, start: row.start, contentEnd: row.contentEnd, end: row.end,
                                             hash: ContentHash.sha256Hex(original), lines: new.components(separatedBy: "\n")))
            }
            for var e in edits.edits where !e.lines.isEmpty {
                // Line by line, as the file's rows are: a match never spans a line break.
                let new = e.lines.map { replaced($0) }
                guard new.contains(where: { $0 != nil }) else { continue }
                e.lines = zip(e.lines, new).flatMap { ($1 ?? $0).components(separatedBy: "\n") }
                changes.append(e)
            }
            return (changes, count)
        }.value.map { (edits: $0.0, count: $0.1) }
    }

    // MARK: Filter

    func setFilter(_ on: Bool) {
        if on {
            runFilter()
        } else {
            filterTask?.cancel()
            filterTask = nil
            filterRunning = false
            if let filterRows {
                // Stay on the row that was selected (keeping a selection inside it, such as the match) or at the top.
                let row = head.flatMap { displayRow(forVisual: $0.row) } ?? displayRow(forVisual: Int(topRow)) ?? 0
                let keep = anchor.flatMap { a in head.map { h in a.row == h.row ? (a.column, h.column) : nil } } ?? nil
                _ = filterRows
                self.filterRows = nil
                anchor = LargeFilePosition(row: row, column: keep?.0 ?? 0)
                head = LargeFilePosition(row: row, column: keep?.1 ?? 0)
                topRow = min(max(Double(row) - Double(viewportRows) / 3, 0), maxTopRow())
            }
            filterCapped = false
            displayVersion += 1
            onDisplayChanged?()
            pushStatus(force: true)
        }
    }

    private func runFilter(appendedFrom tail: Tail? = nil) {
        filterTask?.cancel()
        guard let q = query, let source, let index, progress.complete, let newTail = currentTail else {
            filterRunning = query != nil
            pushStatus(force: true)
            return
        }
        let edits = self.edits
        let key = FindKey(query: q, edits: edits)
        // After an append: the rows listed before the reopened one stay, and only the rest is searched.
        var kept: [Int]?
        if let tail, !filterRunning, let rows = filterRows, let c = filterCache, c.key == key, c.tail == tail,
           Self.editsEnd(before: tail, edits) {
            if filterCapped { return }
            let split = edits.displayRow(forBase: tail.row)
            kept = Array(rows.prefix { $0 < split })
        }
        // A refresh after an append keeps the place in the list; a new filter starts at its top.
        let refresh = tail != nil && filterRows != nil
        if kept == nil {
            filterRunning = true
            pushStatus(force: true)
        }
        let end = progress.scannedBytes
        let start = index.splitter.bomLength
        let scanner = regexScanner(q)
        filterTask = Task { [weak self, kept] in
            let result = await Task.detached(priority: .userInitiated) { () -> (rows: [Int], capped: Bool)? in
                var rows: [Int] = []
                var capped = false
                let limit = LargeFilePolicy.filterLimit - (kept?.count ?? 0)
                if let scanner {
                    let from = kept != nil ? edits.displayRow(forBase: tail!.row) : 0
                    scanner.forEach(from: from, isCancelled: { Task.isCancelled }) { display, _ in
                        if rows.last != display { rows.append(display) }
                        if rows.count >= limit { capped = true; return false }
                        return true
                    }
                    return Task.isCancelled ? nil : ((kept ?? []) + rows, capped)
                }
                LargeFileSearch.forEachMatch(in: source, q, start: kept != nil ? tail!.offset : start, end: end,
                                             isCancelled: { Task.isCancelled }) { offset in
                    if edits.edit(containingOffset: offset) != nil { return true }
                    let r = index.row(containing: offset, source: source)
                    if rows.last != r { rows.append(r) }
                    if rows.count >= limit { capped = true; return false }
                    return true
                }
                if Task.isCancelled { return nil }
                var display = rows.map { edits.displayRow(forBase: $0) }
                if let kept { return (kept + display, capped) }
                for e in edits.edits {
                    let first = edits.displayRow(forBase: e.row)
                    for (i, line) in e.lines.enumerated() where !q.ranges(in: line).isEmpty { display.append(first + i) }
                }
                display.sort()
                return (display, capped)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.filterRows = result.rows
            self.filterCapped = result.capped
            self.filterRunning = false
            self.filterCache = (key, newTail)
            if kept == nil {
                self.anchor = nil
                self.head = nil
            }
            if self.follow {
                self.topRow = self.maxTopRow()
            } else {
                self.topRow = refresh ? min(self.topRow, self.maxTopRow()) : 0
            }
            self.displayVersion += 1
            self.onDisplayChanged?()
            self.pushStatus(force: true)
        }
    }

    // MARK: Save

    /// Bytes the saved file will have, about.
    var estimatedSavedBytes: Int {
        let delta = edits.edits.reduce(0) { sum, e in
            sum + e.lines.reduce(0) { $0 + $1.utf8.count + 1 } - (e.end - e.start)
        }
        return max(fileSize + delta, 0)
    }

    /// Streams the file with its edits (and a large Replace All) to `url`. Off the main thread, with progress.
    func save(to url: URL, overwrite: Bool, presenter: NSFilePresenter?, replacement: LargeFileReplacement? = nil,
              extraBytes: Int = 0) async -> Result<LargeFileFingerprint, LargeFileSaveError> {
        guard let source, pendingEdits == nil, !editsMismatch, !isSaving else { return .failure(.couldNotSave) }
        let tmp = LargeFileWriter.tempURL()
        let estimate = estimatedSavedBytes + extraBytes
        do {
            try LargeFileWriter.checkSpace(estimate, at: tmp)
            try LargeFileWriter.checkSpace(estimate, at: url)
        } catch let e as LargeFileSaveError {
            return .failure(e)
        } catch {
            return .failure(.couldNotSave)
        }
        // A file that is not the one read (replaced, or rewritten in place) needs the user's go-ahead.
        let current = LargeFileFingerprint.of(path: url.path)
        let sameAsRead = current.map { c in source.fingerprint.map { c.isSameFile(as: $0) && c.size == $0.size } ?? false } ?? true
        if !overwrite, current != nil, !sameAsRead { return .failure(.externalChange) }
        // Overwrite or not, edits are spliced in at their offsets: the bytes they replace must still be there.
        guard let index, edits.matches(source: source, index: index) else { return .failure(.editsNoLongerMatch) }

        saveProgress = 0
        pushStatus(force: true)
        defer {
            saveProgress = nil
            try? FileManager.default.removeItem(at: tmp)
            pushStatus(force: true)
        }
        let size = source.size
        let edits = self.edits
        let encoding = self.encoding
        let lineBreak = lineEnding == .crlf ? "\r\n" : "\n"
        let needed = estimate + 64 * 1_048_576
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.saveProgressed(p) }
        }
        return await Task.detached(priority: .userInitiated) { () -> Result<LargeFileFingerprint, LargeFileSaveError> in
            do {
                var last = Date.distantPast
                try LargeFileWriter.write(source: source, size: size, edits: edits, encoding: encoding, lineBreak: lineBreak,
                                          replacement: replacement, to: tmp, isCancelled: { false }) { p in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.2 else { return }
                    last = now
                    report(p)
                }
                return .success(try LargeFileWriter.install(tmp, at: url, expected: overwrite ? nil : current,
                                                            overwrite: overwrite, presenter: presenter))
            } catch LargeFileSaveError.notEnoughSpace {
                // The disk filled during the write (another app, or a Replace All that grew the text).
                return .failure(.notEnoughSpace(needed: needed))
            } catch let e as LargeFileSaveError {
                return .failure(e)
            } catch {
                return .failure(.couldNotSave)
            }
        }.value
    }

    private func saveProgressed(_ p: Double) {
        guard saveProgress != nil else { return }
        saveProgress = p
        pushStatus(force: true)
    }
}

extension LargeFileEdits {
    mutating func remove(rows: Set<Int>) {
        let kept = edits.filter { !rows.contains($0.row) }
        self = LargeFileEdits()
        apply(kept)
    }
}

/// Find Next / Previous over the file and its edits: a match in an edited row's old bytes does not count, and
/// the edits' own lines are searched where they sit. Runs off the main thread on a copy of the edits.
struct LargeFileFinder: @unchecked Sendable {
    let source: LargeFileSource
    let index: LargeFileIndex
    let edits: LargeFileEdits
    let query: LargeFileQuery
    let encoding: TextEncoding
    let end: Int
    let bom: Int
    let baseRows: Int

    private func byteOffset(in row: LargeFileRow, column: Int) -> Int {
        guard column > 0 else { return row.start }
        let text = LargeFileText.decode(source.read(offset: row.start, count: row.contentEnd - row.start), encoding) as NSString
        let prefix = text.substring(to: min(column, text.length))
        return row.start + (LargeFileText.encode(prefix, encoding)?.count ?? 0)
    }

    private func utf16Column(of offset: Int, in row: LargeFileRow) -> Int {
        let prefix = LargeFileText.decode(source.read(offset: row.start, count: offset - row.start), encoding)
        return (prefix as NSString).length
    }

    private func hitInEdit(_ e: LargeFileEdit, lines: Range<Int>, from column: Int?, reverse: Bool) -> (Int, NSRange)? {
        let first = edits.displayRow(forBase: e.row)
        let order = reverse ? Array(lines.reversed()) : Array(lines)
        for li in order where li < e.lines.count {
            var ranges = query.ranges(in: e.lines[li])
            if let column, li == (reverse ? lines.upperBound - 1 : lines.lowerBound) {
                ranges = ranges.filter { reverse ? $0.location < column : $0.location >= column }
            }
            if let r = reverse ? ranges.last : ranges.first { return (first + li, r) }
        }
        return nil
    }

    func forward(display: Int, column: Int) -> (Int, NSRange)? {
        let (base, editLine) = edits.locate(display)
        var position: Int
        var row: Int
        if let editLine, let e = edits.edit(forRow: base) {
            if let hit = hitInEdit(e, lines: editLine..<e.lines.count, from: column, reverse: false) { return hit }
            position = e.end
            row = base + 1
        } else {
            guard let r = index.row(base, source: source) else { return nil }
            position = byteOffset(in: r, column: column)
            row = base
        }
        while true {
            let hit = LargeFileSearch.next(in: source, query, from: position, end: end, isCancelled: { false })
            let hitRow = hit.map { index.row(containing: $0, source: source) } ?? max(baseRows - 1, row)
            if hitRow >= row {
                for e in edits.edits(inRows: row...hitRow) where !e.lines.isEmpty {
                    if let found = hitInEdit(e, lines: 0..<e.lines.count, from: nil, reverse: false) { return found }
                }
            }
            guard let hit else { return nil }
            if let e = edits.edit(containingOffset: hit) {
                position = e.end
                row = e.row + 1
                continue
            }
            guard let r = index.row(hitRow, source: source) else { return nil }
            return (edits.displayRow(forBase: hitRow),
                    NSRange(location: utf16Column(of: hit, in: r), length: (query.text as NSString).length))
        }
    }

    func backward(display: Int, column: Int) -> (Int, NSRange)? {
        let (base, editLine) = edits.locate(display)
        var position: Int
        var row: Int
        if let editLine, let e = edits.edit(forRow: base) {
            if let hit = hitInEdit(e, lines: 0..<(editLine + 1), from: column, reverse: true) { return hit }
            position = e.start
            row = base - 1
        } else if let r = index.row(base, source: source) {
            position = byteOffset(in: r, column: column)
            row = base
        } else {
            position = end
            row = baseRows - 1
        }
        while row >= 0 {
            let hit = LargeFileSearch.previous(in: source, query, start: bom, before: position, isCancelled: { false })
            let hitRow = hit.map { index.row(containing: $0, source: source) } ?? 0
            if row >= hitRow {
                for e in edits.edits(inRows: hitRow...row).reversed() where !e.lines.isEmpty {
                    if let found = hitInEdit(e, lines: 0..<e.lines.count, from: nil, reverse: true) { return found }
                }
            }
            guard let hit else { return nil }
            if let e = edits.edit(containingOffset: hit) {
                position = e.start
                row = e.row - 1
                continue
            }
            guard let r = index.row(hitRow, source: source) else { return nil }
            return (edits.displayRow(forBase: hitRow),
                    NSRange(location: utf16Column(of: hit, in: r), length: (query.text as NSString).length))
        }
        return nil
    }
}
