import Foundation

/// A find query. Literal text is searched as the file's bytes, so a scan needs no decoding; ignoring case
/// folds ASCII letters only, other scripts match as typed, and UTF-16 matches count only on a code-unit
/// boundary. A regular expression is matched in decoded rows (`LargeFileRegexScanner`): a match never
/// crosses a line, nor the cut between the pieces of a line longer than 16 KB. So is literal text in GB18030,
/// whose trail bytes can be ASCII letters and digits (說 is D5 66, "f"; 😀 holds "9" and "6"): its bytes
/// would match inside characters, and a streamed Replace All would rewrite them.
struct LargeFileQuery: @unchecked Sendable, Equatable {
    let text: String
    let caseSensitive: Bool
    let encoding: TextEncoding
    /// The user asked for a regular expression (`regex` is also set for literal GB18030 text).
    let isRegex: Bool
    /// Searched as bytes only: empty when `regex` is set.
    let needle: [UInt8]
    /// Set when the query is matched in decoded rows. Immutable, so safe to share between threads.
    let regex: NSRegularExpression?

    init?(_ text: String, caseSensitive: Bool, regex: Bool = false, encoding: TextEncoding) {
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        self.text = text
        self.caseSensitive = caseSensitive
        self.encoding = encoding
        isRegex = regex
        if regex || encoding == .gb18030 {
            let pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
            guard let r = FindPattern.regex(pattern, caseSensitive: caseSensitive) else { return nil }
            self.regex = r
            needle = []
            return
        }
        guard let data = LargeFileText.encode(text, encoding), !data.isEmpty else { return nil }
        var bytes = [UInt8](data)
        if !caseSensitive { bytes.withUnsafeMutableBufferPointer { LargeFileSearch.fold($0, encoding, phase: 0) } }
        self.regex = nil
        needle = bytes
    }

    static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.caseSensitive == b.caseSensitive && a.encoding == b.encoding && a.isRegex == b.isRegex
    }

    var isUTF16: Bool { encoding == .utf16LE || encoding == .utf16BE }

    /// Matches in decoded text (an edit's lines, a row on screen), as UTF-16 ranges.
    func ranges(in line: String) -> [NSRange] {
        if let regex { return FindPattern.ranges(regex, in: line as NSString) }
        let ns = line as NSString
        var out: [NSRange] = []
        var from = 0
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        while from < ns.length {
            let r = ns.range(of: text, options: options, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }

    /// `line` with every match replaced: literally, or by the template (`$1`) for a regular expression.
    func replacing(in line: String, with replacement: String) -> String {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let regex {
            let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
            return FindPattern.replacing(regex, in: ns, ranges: ranges(in: line), template: template)
        }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        return ns.replacingOccurrences(of: text, with: replacement, options: options, range: all)
    }

    /// The text that replaces the match at `range` of `line`.
    func replacement(for range: NSRange, in line: String, template: String) -> String {
        guard isRegex, let regex, let m = regex.firstMatch(in: line, options: [], range: range), m.range == range else {
            return template
        }
        return regex.replacementString(for: m, in: line, offset: 0, template: template)
    }
}

enum LargeFileSearch {
    static let chunk = 4 * 1_048_576

    /// ASCII A–Z to a–z in place. For UTF-16, `phase` is the index of the first whole code unit.
    static func fold(_ p: UnsafeMutableBufferPointer<UInt8>, _ encoding: TextEncoding, phase: Int) {
        switch encoding {
        case .utf16LE:
            var i = phase
            while i + 1 < p.count {
                if p[i + 1] == 0, p[i] >= 0x41, p[i] <= 0x5A { p[i] |= 0x20 }
                i += 2
            }
        case .utf16BE:
            var i = phase
            while i + 1 < p.count {
                if p[i] == 0, p[i + 1] >= 0x41, p[i + 1] <= 0x5A { p[i + 1] |= 0x20 }
                i += 2
            }
        default:
            for i in 0..<p.count where p[i] >= 0x41 && p[i] <= 0x5A { p[i] |= 0x20 }
        }
    }

    /// Match starts in `p` before `limit`, non-overlapping, each passed to `body` (false stops).
    static func scan(_ p: UnsafeBufferPointer<UInt8>, _ q: LargeFileQuery, phase: Int, from: Int = 0, limit: Int,
                     _ body: (Int) -> Bool) {
        guard let base = p.baseAddress else { return }
        let n = q.needle.count
        q.needle.withUnsafeBufferPointer { needle in
            var i = from
            while i < limit, i + n <= p.count {
                guard let hit = memmem(base + i, p.count - i, needle.baseAddress!, n) else { return }
                let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if at >= limit { return }
                if q.isUTF16, (at - phase) & 1 != 0 { i = at + 1; continue }
                if !body(at) { return }
                i = at + n
            }
        }
    }

    /// The bytes at `offset`, folded when the query ignores case, and the index of their first code unit.
    private static func readChunk(_ source: LargeFileSource, _ q: LargeFileQuery, offset: Int, count: Int) -> (Data, Int) {
        var data = source.readDirect(offset: offset, count: count)
        let phase = q.isUTF16 ? (offset - 2) & 1 : 0
        if !q.caseSensitive {
            data.withUnsafeMutableBytes { raw in fold(raw.bindMemory(to: UInt8.self), q.encoding, phase: phase) }
        }
        return (data, phase)
    }

    /// Every match starting in `start..<end`, in order; `body` returning false stops. Blocking.
    static func forEachMatch(in source: LargeFileSource, _ q: LargeFileQuery, start: Int, end: Int,
                             isCancelled: () -> Bool, progress: ((Int) -> Void)? = nil, _ body: (Int) -> Bool) {
        var position = start
        var nextAllowed = start
        var stopped = false
        while position < end, !stopped, !isCancelled() {
            let want = min(chunk, end - position)
            let (data, phase) = readChunk(source, q, offset: position, count: want + q.needle.count - 1)
            if data.isEmpty { break }
            data.withUnsafeBytes { raw in
                scan(raw.bindMemory(to: UInt8.self), q, phase: phase, from: max(nextAllowed - position, 0), limit: want) { at in
                    nextAllowed = position + at + q.needle.count
                    if !body(position + at) { stopped = true; return false }
                    return true
                }
            }
            position += want
            progress?(position)
        }
    }

    static func next(in source: LargeFileSource, _ q: LargeFileQuery, from start: Int, end: Int,
                     isCancelled: () -> Bool) -> Int? {
        var found: Int?
        forEachMatch(in: source, q, start: start, end: end, isCancelled: isCancelled) { found = $0; return false }
        return found
    }

    /// The last match that starts in `start..<before`.
    static func previous(in source: LargeFileSource, _ q: LargeFileQuery, start: Int, before: Int,
                         isCancelled: () -> Bool) -> Int? {
        var upper = before
        while upper > start, !isCancelled() {
            let lower = max(start, upper - chunk)
            let (data, phase) = readChunk(source, q, offset: lower, count: upper - lower + q.needle.count - 1)
            var last: Int?
            data.withUnsafeBytes { raw in
                scan(raw.bindMemory(to: UInt8.self), q, phase: phase, limit: upper - lower) { at in
                    last = lower + at
                    return true
                }
            }
            if let last { return last }
            upper = lower
        }
        return nil
    }
}

/// Regular-expression search, row by row in display order (so an edit's lines are searched where they sit,
/// and an edited row's old bytes are not). Rows are decoded a batch at a time into one UTF-16 buffer, one row
/// per line, and the expression runs over the batch. Blocking; runs off the main thread on a copy of the edits.
struct LargeFileRegexScanner: @unchecked Sendable {
    let source: LargeFileSource
    let index: LargeFileIndex
    let edits: LargeFileEdits
    let regex: NSRegularExpression
    let encoding: TextEncoding
    let displayRows: Int

    static let batchRows = 4096
    /// About how many bytes one batch decodes: rows of up to 16 KB would otherwise make a batch 64 MB of
    /// file (128 MB of UTF-16), once per core.
    static let batchBytes = 2 * 1_048_576

    /// The text of display rows `range`, each followed by a line break, and where each row starts in it.
    private func batch(_ range: Range<Int>) -> (NSString, [Int]) {
        var units: [UInt16] = []
        var starts: [Int] = []
        starts.reserveCapacity(range.count + 1)
        var base: [Int: LargeFileRow] = [:]
        var data = Data()
        var dataStart = 0
        if edits.isEmpty {
            let rows = index.rows(range, source: source)
            if let first = rows.first, let last = rows.last {
                data = source.readDirect(offset: first.start, count: last.contentEnd - first.start)
                dataStart = first.start
            }
            for (i, r) in rows.enumerated() { base[range.lowerBound + i] = r }
        }
        for d in range {
            starts.append(units.count)
            let (row, line) = edits.locate(d)
            let text: String
            if let line, let e = edits.edit(forRow: row) {
                text = line < e.lines.count ? e.lines[line] : ""
            } else if let r = base[d] {
                // The file may have shrunk since it was indexed: `pread` then returned fewer bytes.
                let lo = min(r.start - dataStart, data.count), hi = min(r.contentEnd - dataStart, data.count)
                text = LargeFileText.decode(data[lo..<max(lo, hi)], encoding)
            } else if let r = index.row(row, source: source) {
                text = LargeFileText.decode(source.read(offset: r.start, count: r.contentEnd - r.start), encoding)
            } else {
                text = ""
            }
            units.append(contentsOf: text.utf16)
            units.append(0x0A)
        }
        starts.append(units.count)
        return (NSString(characters: units, length: units.count), starts)
    }

    /// Display rows from `lo`: at most `batchRows` of them and, past the first, about `batchBytes` of text.
    private func batchRange(from lo: Int) -> Range<Int> {
        let hi = min(lo + Self.batchRows, displayRows)
        var bytes = 0
        var d = lo
        if edits.isEmpty {
            for r in index.rows(lo..<hi, source: source) {
                bytes += r.contentEnd - r.start + 1
                d += 1
                if bytes >= Self.batchBytes { break }
            }
            return lo..<max(d, lo + 1)
        }
        while d < hi {
            let (row, line) = edits.locate(d)
            if let line, let e = edits.edit(forRow: row) {
                bytes += (line < e.lines.count ? e.lines[line].utf8.count : 0) + 1
            } else if let r = index.row(row, source: source) {
                bytes += r.contentEnd - r.start + 1
            }
            d += 1
            if bytes >= Self.batchBytes { break }
        }
        return lo..<max(d, lo + 1)
    }

    /// Runs the expression over display rows `range`, each match as (display row, range in the row), in order;
    /// `body` returning false stops. A match across rows (over the added line break) does not count.
    private func enumerate(_ range: Range<Int>, isCancelled: () -> Bool, _ body: (Int, NSRange) -> Bool) {
        let (text, starts) = batch(range)
        var i = 0
        var seen = 0
        regex.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { m, _, stop in
            seen += 1
            if seen & 0x3FF == 0, isCancelled() { stop.pointee = true; return }
            guard let r = m?.range, r.length > 0 else { return }
            while i + 1 < starts.count, starts[i + 1] <= r.location { i += 1 }
            let rowEnd = starts[i + 1] - 1   // before the added line break
            guard NSMaxRange(r) <= rowEnd else { return }
            if !body(range.lowerBound + i, NSRange(location: r.location - starts[i], length: r.length)) { stop.pointee = true }
        }
    }

    /// How many matches each display row in `range` holds (rows without one left out): a batch's result is at
    /// most one entry per row, however many matches (`.` finds one per character).
    private func rowCounts(in range: Range<Int>, isCancelled: () -> Bool) -> [(row: Int, count: Int)] {
        var out: [(row: Int, count: Int)] = []
        enumerate(range, isCancelled: isCancelled) { row, _ in
            if out.last?.row == row { out[out.count - 1].count += 1 } else { out.append((row, 1)) }
            return true
        }
        return out
    }

    /// Batches of display rows from `lo`, one per core, decoded and searched in parallel; `work` runs on each.
    private func round<T>(from lo: Int, _ work: @Sendable (Range<Int>) -> T) -> (results: [T], end: Int) {
        let width = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        var ranges: [Range<Int>] = []
        var next = lo
        while ranges.count < width, next < displayRows {
            let r = batchRange(from: next)
            ranges.append(r)
            next = r.upperBound
        }
        let batches = ranges
        let found = Locked([T?](repeating: nil, count: batches.count))
        DispatchQueue.concurrentPerform(iterations: batches.count) { i in
            let m = work(batches[i])
            found.withLock { $0[i] = m }
        }
        return (found.withLock { $0 }.map { $0! }, next)
    }

    /// Every row with matches from display row `from` on, in order, with its number of matches; `body`
    /// returning false stops. Decoding is most of the cost, so a round of batches is decoded and searched on
    /// every core, then delivered in order.
    func forEach(from: Int = 0, isCancelled: @Sendable () -> Bool, progress: ((Int) -> Void)? = nil,
                 _ body: (_ row: Int, _ count: Int) -> Bool) {
        var lo = max(from, 0)
        while lo < displayRows, !isCancelled() {
            let (batches, end) = round(from: lo) { rowCounts(in: $0, isCancelled: isCancelled) }
            if isCancelled() { return }
            for batch in batches {
                for (row, count) in batch where !body(row, count) { return }
            }
            lo = end
            progress?(lo)
        }
    }

    /// The first match at or after (display, column).
    func forward(display: Int, column: Int) -> (Int, NSRange)? {
        var lo = max(display, 0)
        while lo < displayRows {
            let (firsts, end) = round(from: lo) { range -> (Int, NSRange)? in
                var hit: (Int, NSRange)?
                enumerate(range, isCancelled: { false }) { row, r in
                    if row == display, r.location < column { return true }
                    hit = (row, r)
                    return false
                }
                return hit
            }
            if let hit = firsts.lazy.compactMap({ $0 }).first { return hit }
            lo = end
        }
        return nil
    }

    /// The last match before (display, column).
    func backward(display: Int, column: Int) -> (Int, NSRange)? {
        var hi = min(display + 1, displayRows)
        while hi > 0 {
            let lo = max(hi - Self.batchRows, 0)
            var hit: (Int, NSRange)?
            enumerate(lo..<hi, isCancelled: { false }) { row, r in
                if row < display || (row == display && r.location < column) { hit = (row, r) }
                return true
            }
            if let hit { return hit }
            hi = lo
        }
        return nil
    }
}

typealias LargeFileCancelCheck = @Sendable () -> Bool

/// Runs `work` off the main thread, told to stop when the task awaiting it is cancelled. A detached task does
/// not inherit cancellation, and `Task.isCancelled` is false on `concurrentPerform`'s worker threads, so the
/// check is a flag any thread can read.
func largeFileDetached<T: Sendable>(priority: TaskPriority,
                                    _ work: @escaping @Sendable (LargeFileCancelCheck) -> T) async -> T {
    let flag = Locked(false)
    return await withTaskCancellationHandler {
        await Task.detached(priority: priority) { work { flag.withLock { $0 } } }.value
    } onCancel: {
        flag.withLock { $0 = true }
    }
}

/// A value shared by the workers of `concurrentPerform`.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
