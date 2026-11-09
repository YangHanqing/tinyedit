import Foundation

/// One row of a large file: a line, or a `maxRowBytes` piece of a longer one. Offsets are into the file.
struct LargeFileRow: Equatable, Sendable {
    var start: Int
    /// Before the line ending (LF or CRLF); equal to `end` for the piece of a long line and for the last row.
    var contentEnd: Int
    var end: Int
    /// 1-based number of the line this row is, or is a piece of.
    var line: Int
    /// False for the second and later pieces of a long line.
    var startsLine: Bool

    var hasLineEnding: Bool { end > contentEnd }
}

/// How bytes split into rows: after each LF (a CR before it belongs to the line ending), and inside a line
/// longer than `maxRowBytes` at a character boundary, so one 2 GB line of minified JSON is still drawn and
/// searched in pieces. A file ending in a line break has an empty last row, as in the editor.
struct LargeFileRowSplitter: Sendable {
    static let maxRowBytes = 16 * 1024
    let encoding: TextEncoding

    var unit: Int { encoding == .utf16LE || encoding == .utf16BE ? 2 : 1 }
    var bomLength: Int {
        switch encoding {
        case .utf8BOM: 3
        case .utf16LE, .utf16BE: 2
        case .utf8, .gb18030: 0
        }
    }

    /// Calls `row(start, contentEnd, end)` for every row that ends inside `p`, which begins at a row start.
    /// Returns where the first unfinished row starts. At the end of the file the rest is the last row.
    @discardableResult
    func split(_ p: UnsafeBufferPointer<UInt8>, atEOF: Bool, _ row: (Int, Int, Int) -> Void) -> Int {
        let n = p.count
        guard let base = p.baseAddress, n > 0 else {
            if atEOF { row(0, 0, 0) }
            return 0
        }
        var start = 0
        while true {
            let limit = min(start + Self.maxRowBytes, n)
            if let lf = findLF(base, start, limit) {
                let contentEnd = endsWithCR(base, start, lf) ? lf - unit : lf
                row(start, contentEnd, lf + unit)
                start = lf + unit
            } else if limit < n {
                let cut = softCut(base, start, limit)
                row(start, cut, cut)
                start = cut
            } else if atEOF {
                row(start, n, n)
                return n
            } else {
                return start
            }
        }
    }

    private func findLF(_ base: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> Int? {
        guard from < to else { return nil }
        switch encoding {
        case .utf16LE, .utf16BE:
            let little = encoding == .utf16LE
            var i = from
            while i + 1 < to {
                if little ? (base[i] == 0x0A && base[i + 1] == 0) : (base[i] == 0 && base[i + 1] == 0x0A) { return i }
                i += 2
            }
            return nil
        default:
            guard let hit = memchr(base + from, 0x0A, to - from) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private func endsWithCR(_ base: UnsafePointer<UInt8>, _ start: Int, _ lf: Int) -> Bool {
        guard lf - unit >= start else { return false }
        switch encoding {
        case .utf16LE: return base[lf - 2] == 0x0D && base[lf - 1] == 0
        case .utf16BE: return base[lf - 2] == 0 && base[lf - 1] == 0x0D
        default: return base[lf - 1] == 0x0D
        }
    }

    /// Where a long line is cut: before `limit`, never inside a character (UTF-8 continuation bytes, a UTF-16
    /// surrogate pair) and, in GB18030, only after a byte that cannot be part of a multi-byte character.
    private func softCut(_ base: UnsafePointer<UInt8>, _ start: Int, _ limit: Int) -> Int {
        var c = limit
        switch encoding {
        case .utf8, .utf8BOM:
            while c > start + 1, base[c] & 0xC0 == 0x80 { c -= 1 }
        case .utf16LE, .utf16BE:
            let unit = encoding == .utf16LE ? UInt16(base[c - 2]) | UInt16(base[c - 1]) << 8
                                            : UInt16(base[c - 2]) << 8 | UInt16(base[c - 1])
            if (0xD800...0xDBFF).contains(unit) { c -= 2 }
        case .gb18030:
            // A trail byte can look like a lead or ASCII, so boundaries are only known walking from the row's start:
            // 0x81–0xFE leads a 4-byte character when a digit follows, else a 2-byte one; anything else is one byte.
            // A CR is not cut after, so a CRLF stays together. Only `limit` bytes plus one are looked at, as the
            // scan and a block read both have them.
            var i = start
            c = start
            while i < limit {
                let b = base[i]
                let width = b >= 0x81 && b <= 0xFE ? (base[i + 1] >= 0x30 && base[i + 1] <= 0x39 ? 4 : 2) : 1
                if i + width > limit { break }
                i += width
                if b != 0x0D { c = i }
            }
            if c <= start { c = limit }
        }
        return c > start ? c : limit
    }
}

/// Where rows start, kept sparsely: one checkpoint every `stride` rows (a 2 GB log of 20 million lines needs
/// about 2 MB). The rows of a block are found again from its checkpoint when they are drawn, and the last
/// few blocks are kept. Built off the main thread, readable while it grows.
final class LargeFileIndex: @unchecked Sendable {
    static let stride = 256
    static let scanChunk = 4 * 1_048_576

    struct Checkpoint: Sendable {
        var offset: Int
        var line: Int
        var startsLine: Bool
    }

    struct Progress: Equatable, Sendable {
        var rows: Int
        var lines: Int
        var scannedBytes: Int
        var complete: Bool
    }

    let splitter: LargeFileRowSplitter
    private let lock = NSLock()
    private var checkpoints: [Checkpoint] = []
    private var rowCount = 0
    /// Where the next scan starts (the first row not yet known), and that row's line.
    private var resumeOffset: Int
    private var nextLine = 1
    private var nextStartsLine = true
    private var crlfLines = 0
    private var lfLines = 0
    private var complete = false
    /// End of the last row once complete.
    private var indexedEnd = 0
    private var blockCache: [Int: [LargeFileRow]] = [:]
    private var blockOrder: [Int] = []
    /// Bumped by every drop of cached blocks: rows split before it are not stored after it.
    private var cacheGeneration = 0

    init(encoding: TextEncoding) {
        splitter = LargeFileRowSplitter(encoding: encoding)
        resumeOffset = splitter.bomLength
    }

    var progress: Progress {
        lock.lock()
        defer { lock.unlock() }
        return progressUnlocked
    }

    private var progressUnlocked: Progress {
        let lines = rowCount == 0 ? 0 : complete ? nextLine : nextStartsLine ? max(nextLine - 1, 1) : nextLine
        return Progress(rows: rowCount, lines: lines, scannedBytes: complete ? indexedEnd : resumeOffset, complete: complete)
    }

    /// Lines read so far that end in CRLF, and in a bare LF.
    var lineEndings: (crlf: Int, lf: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (crlfLines, lfLines)
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    var rows: Int {
        lock.lock()
        defer { lock.unlock() }
        return rowCount
    }

    var memoryBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints.capacity * MemoryLayout<Checkpoint>.stride
            + blockCache.values.reduce(0) { $0 + $1.count * MemoryLayout<LargeFileRow>.stride }
    }

    /// Scans from where the index stopped to the end of the file. Blocking: call off the main thread.
    func scan(source: LargeFileSource, isCancelled: () -> Bool, progress: (Progress) -> Void) {
        lock.lock()
        guard !complete else { lock.unlock(); return }
        var position = resumeOffset
        var row = rowCount
        var line = nextLine
        var startsLine = nextStartsLine
        lock.unlock()
        let crlfLength = 2 * splitter.unit

        while !isCancelled() {
            var crlf = 0, lf = 0
            let data = source.readDirect(offset: position, count: Self.scanChunk)
            let atEOF = data.count < Self.scanChunk
            var added: [Checkpoint] = []
            var last: Checkpoint?
            let base = position
            let consumed = data.withUnsafeBytes { raw in
                splitter.split(raw.bindMemory(to: UInt8.self), atEOF: atEOF) { s, contentEnd, end in
                    if row % Self.stride == 0 { added.append(Checkpoint(offset: base + s, line: line, startsLine: startsLine)) }
                    if atEOF, end == data.count, contentEnd == end { last = Checkpoint(offset: base + s, line: line, startsLine: startsLine) }
                    row += 1
                    if end > contentEnd {
                        if end - contentEnd == crlfLength { crlf += 1 } else { lf += 1 }
                        line += 1
                        startsLine = true
                    } else {
                        startsLine = false
                    }
                }
            }
            position = base + consumed
            lock.lock()
            let firstChanged = max(rowCount - 1, 0) / Self.stride
            checkpoints.append(contentsOf: added)
            rowCount = row
            crlfLines += crlf
            lfLines += lf
            if atEOF, let last {
                complete = true
                indexedEnd = position
                // The last row is where an append resumes.
                resumeOffset = last.offset
                nextLine = last.line
                nextStartsLine = last.startsLine
            } else {
                resumeOffset = position
                nextLine = line
                nextStartsLine = startsLine
            }
            // Blocks read while they were the growing last one, cached or still being read.
            for b in blockCache.keys where b >= firstChanged { dropCachedBlock(b) }
            cacheGeneration += 1
            let p = progressUnlocked
            lock.unlock()
            progress(p)
            if atEOF { return }
        }
    }

    /// The file grew: forget its last row (it may continue) so the next scan reads on from there.
    func reopenTail() {
        lock.lock()
        defer { lock.unlock() }
        guard complete, rowCount > 0 else { return }
        rowCount -= 1
        if rowCount % Self.stride == 0, !checkpoints.isEmpty { checkpoints.removeLast() }
        complete = false
        dropCachedBlock(rowCount / Self.stride)
    }

    // MARK: Lookups

    func row(_ index: Int, source: LargeFileSource) -> LargeFileRow? {
        guard index >= 0 else { return nil }
        let rows = block(index / Self.stride, source: source)
        let i = index % Self.stride
        return i < rows.count ? rows[i] : nil
    }

    /// The rows in `range` that are known, in order.
    func rows(_ range: Range<Int>, source: LargeFileSource) -> [LargeFileRow] {
        guard !range.isEmpty, range.lowerBound >= 0 else { return [] }
        var out: [LargeFileRow] = []
        var b = range.lowerBound / Self.stride
        while b * Self.stride < range.upperBound {
            let rows = block(b, source: source)
            if rows.isEmpty { break }
            for (i, row) in rows.enumerated() where range.contains(b * Self.stride + i) { out.append(row) }
            b += 1
        }
        return out
    }

    /// The row holding byte `offset` (the last one at or before it).
    func row(containing offset: Int, source: LargeFileSource) -> Int {
        lock.lock()
        var lo = 0, hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpoints[mid].offset <= offset { lo = mid } else { hi = mid - 1 }
        }
        let count = checkpoints.count
        lock.unlock()
        guard count > 0 else { return 0 }
        let rows = block(lo, source: source)
        let i = rows.lastIndex { $0.start <= offset } ?? 0
        return lo * Self.stride + i
    }

    /// The first row of 1-based `line`, clamped to the rows known.
    func row(forLine line: Int, source: LargeFileSource) -> Int {
        lock.lock()
        var lo = 0, hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let cp = checkpoints[mid]
            if cp.line < line || (cp.line == line && cp.startsLine) { lo = mid } else { hi = mid - 1 }
        }
        let count = checkpoints.count, total = rowCount
        lock.unlock()
        guard count > 0 else { return 0 }
        let rows = block(lo, source: source)
        if let i = rows.firstIndex(where: { $0.line >= line }) { return lo * Self.stride + i }
        return max(min(lo * Self.stride + rows.count - 1, total - 1), 0)
    }

    private func block(_ b: Int, source: LargeFileSource) -> [LargeFileRow] {
        lock.lock()
        if let rows = blockCache[b] {
            lock.unlock()
            return rows
        }
        guard b < checkpoints.count else { lock.unlock(); return [] }
        let cp = checkpoints[b]
        let isLast = b + 1 >= checkpoints.count
        let end = isLast ? (complete ? indexedEnd : resumeOffset) : checkpoints[b + 1].offset
        let count = min(Self.stride, rowCount - b * Self.stride)
        let atEOF = isLast && complete
        let readGeneration = cacheGeneration
        lock.unlock()
        guard count > 0 else { return [] }

        // A few bytes past the block: a long line's piece is cut by looking at the byte after the cut, as the scan did.
        let data = source.read(offset: cp.offset, count: end - cp.offset + 8)
        var rows: [LargeFileRow] = []
        rows.reserveCapacity(count)
        var line = cp.line
        var startsLine = cp.startsLine
        _ = data.withUnsafeBytes { raw in
            splitter.split(raw.bindMemory(to: UInt8.self), atEOF: atEOF) { s, contentEnd, end in
                guard rows.count < count else { return }
                rows.append(LargeFileRow(start: cp.offset + s, contentEnd: cp.offset + contentEnd, end: cp.offset + end,
                                         line: line, startsLine: startsLine))
                if end > contentEnd { line += 1; startsLine = true } else { startsLine = false }
            }
        }
        lock.lock()
        guard cacheGeneration == readGeneration else { lock.unlock(); return rows }
        blockCache[b] = rows
        blockOrder.removeAll { $0 == b }
        blockOrder.append(b)
        while blockOrder.count > 16 { blockCache[blockOrder.removeFirst()] = nil }
        lock.unlock()
        return rows
    }

    private func dropCachedBlock(_ b: Int) {
        cacheGeneration += 1
        blockCache[b] = nil
        blockOrder.removeAll { $0 == b }
    }

    func dropCache() {
        lock.lock()
        blockCache.removeAll()
        blockOrder.removeAll()
        cacheGeneration += 1
        lock.unlock()
    }
}

/// Encoding detection and per-row decoding for large files.
enum LargeFileText {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// The BOM, else UTF-8 when samples from the start, middle and end all decode as UTF-8, else GB18030, the
    /// editor's one fallback. Unlike the editor, a NUL byte does not refuse the file: it is only viewed.
    static func detectEncoding(source: LargeFileSource) -> TextEncoding {
        let head = source.readDirect(offset: 0, count: 4)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LE }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        let size = source.size
        let sample = 1_048_576
        for offset in Set([0, max(size / 2 - sample / 2, 0), max(size - sample, 0)]) {
            if !isUTF8(source.readDirect(offset: offset, count: sample), cutStart: offset > 0) { return .gb18030 }
        }
        return .utf8
    }

    /// Valid UTF-8 once a character cut at either end of the sample is dropped.
    static func isUTF8(_ data: Data, cutStart: Bool) -> Bool {
        var bytes = data[...]
        if cutStart {
            var dropped = 0
            while dropped < 3, let b = bytes.first, b & 0xC0 == 0x80 { bytes = bytes.dropFirst(); dropped += 1 }
        }
        for drop in 0...3 where drop <= bytes.count {
            if String(data: Data(bytes.dropLast(drop)), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// Never fails: bytes that do not decode show as U+FFFD, since they are only looked at.
    static func decode(_ data: Data, _ encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8, .utf8BOM:
            return String(decoding: data, as: UTF8.self)
        case .utf16LE:
            return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16LittleEndian)
                ?? String(decoding: data, as: UTF8.self)
        case .utf16BE:
            return String(data: data.count % 2 == 0 ? data : data.dropLast(), encoding: .utf16BigEndian)
                ?? String(decoding: data, as: UTF8.self)
        case .gb18030:
            return String(data: data, encoding: gb18030) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// Text as file bytes, without a BOM. Nil when the encoding cannot hold it.
    static func encode(_ text: String, _ encoding: TextEncoding) -> Data? {
        switch encoding {
        case .utf8, .utf8BOM: Data(text.utf8)
        case .utf16LE: text.data(using: .utf16LittleEndian)
        case .utf16BE: text.data(using: .utf16BigEndian)
        case .gb18030: text.data(using: gb18030)
        }
    }
}
