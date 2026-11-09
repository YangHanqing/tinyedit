import Foundation

/// One changed row of a large file: its original bytes are replaced with `lines` (joined by the file's line
/// ending, followed by the row's own ending), or removed with their ending when `lines` is empty. The file is
/// not touched until Save, which streams the file with every edit applied.
struct LargeFileEdit: Codable, Equatable, Sendable {
    var row: Int
    var start: Int
    var contentEnd: Int
    var end: Int
    /// SHA-256 of the original bytes `start..<end`: a restored or moved tab checks the file still holds them.
    var hash: String
    var lines: [String]
}

/// The edits of a large-file tab, one per row, sorted by row. Rows on screen ("display rows") are the file's
/// rows with each edited row replaced by its lines; `locate` and `displayRow(forBase:)` map between the two.
/// Kept small on purpose (`maxRows`): a change to more rows is a Save As of a new file.
struct LargeFileEdits: Codable, Equatable, Sendable {
    static let maxRows = 10_000
    /// Text one edit can hold; more opens as a new tab instead.
    static let maxEditBytes = 1_048_576

    private(set) var edits: [LargeFileEdit] = []
    /// Display row where edit `i` starts.
    private var starts: [Int] = []
    private(set) var rowDelta = 0

    private enum CodingKeys: String, CodingKey { case edits }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decode([LargeFileEdit].self, forKey: .edits)
        var seen = Set<Int>()
        edits = list.sorted { $0.row < $1.row }.filter { $0.row >= 0 && seen.insert($0.row).inserted }
        reindex()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edits, forKey: .edits)
    }

    var isEmpty: Bool { edits.isEmpty }
    var count: Int { edits.count }

    /// Sets (or replaces) the edits of their rows.
    mutating func apply(_ changes: [LargeFileEdit]) {
        guard !changes.isEmpty else { return }
        var byRow = Dictionary(edits.map { ($0.row, $0) }, uniquingKeysWith: { a, _ in a })
        for change in changes { byRow[change.row] = change }
        edits = byRow.values.sorted { $0.row < $1.row }
        reindex()
    }

    func edit(forRow row: Int) -> LargeFileEdit? {
        let i = lowerBound(row)
        return i < edits.count && edits[i].row == row ? edits[i] : nil
    }

    /// Edits whose rows are in `range`, in order.
    func edits(inRows range: ClosedRange<Int>) -> ArraySlice<LargeFileEdit> {
        let lo = lowerBound(range.lowerBound)
        var hi = lo
        while hi < edits.count, edits[hi].row <= range.upperBound { hi += 1 }
        return edits[lo..<hi]
    }

    /// The edit, if any, whose original bytes hold `offset`.
    func edit(containingOffset offset: Int) -> LargeFileEdit? {
        var lo = 0, hi = edits.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if edits[mid].end <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < edits.count && edits[lo].start <= offset ? edits[lo] : nil
    }

    func displayCount(baseRows: Int) -> Int { max(baseRows + rowDelta, 0) }

    /// The file row a display row comes from, and the line of the edit it shows (nil for an unedited row).
    func locate(_ display: Int) -> (row: Int, line: Int?) {
        guard !edits.isEmpty else { return (display, nil) }
        var lo = -1, hi = edits.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= display { lo = mid } else { hi = mid - 1 }
        }
        guard lo >= 0 else { return (display, nil) }
        let e = edits[lo]
        let first = starts[lo]
        if display < first + e.lines.count { return (e.row, display - first) }
        return (e.row + 1 + display - first - e.lines.count, nil)
    }

    /// The first display row of file row `row`; for a removed row, where it would be.
    func displayRow(forBase row: Int) -> Int {
        let i = lowerBound(row + 1) - 1
        guard i >= 0 else { return row }
        let e = edits[i]
        return e.row == row ? starts[i] : starts[i] + e.lines.count + row - e.row - 1
    }

    private func lowerBound(_ row: Int) -> Int {
        var lo = 0, hi = edits.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if edits[mid].row < row { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private mutating func reindex() {
        starts = []
        starts.reserveCapacity(edits.count)
        var delta = 0
        for e in edits {
            starts.append(e.row + delta)
            delta += e.lines.count - 1
        }
        rowDelta = delta
    }

    // MARK: Recovery

    /// The snapshot of a large-file tab: its edits as JSON, so the snapshot invariant holds without copying the file.
    func snapshotText() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{\"edits\":[]}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func fromSnapshot(_ text: String) -> LargeFileEdits? {
        try? JSONDecoder().decode(LargeFileEdits.self, from: Data(text.utf8))
    }

    /// Every edit's original bytes are still in the file where they were: the edits still apply.
    func matches(source: LargeFileSource, index: LargeFileIndex) -> Bool {
        edits.allSatisfy { e in
            guard let row = index.row(e.row, source: source), row.start == e.start, row.end == e.end else { return false }
            return ContentHash.sha256Hex(source.readDirect(offset: e.start, count: e.end - e.start)) == e.hash
        }
    }

    /// The edited text, for Copy Edits when the file changed under them. Removed rows have none.
    var summaryText: String {
        edits.filter { !$0.lines.isEmpty }.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n")
    }
}
