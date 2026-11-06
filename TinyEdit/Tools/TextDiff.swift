import Foundation

/// One row of a unified diff: a line from either side, or a run of unchanged lines left out.
struct DiffLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case context, removed, added, gap }
    var kind: Kind
    /// 1-based line numbers; nil on the side the line is not in (and on a gap).
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
    /// UTF-16 range in `text` that differs from the line it was paired with; nil when the whole line differs.
    var changed: NSRange?
    /// Unchanged lines a gap stands for.
    var hidden = 0
}

/// A unified (one-column) diff of two texts, as rows to draw. `changes` are the row ranges of each run of
/// removed and added lines, in order, for Previous / Next.
struct UnifiedDiff: Sendable {
    var lines: [DiffLine] = []
    var changes: [Range<Int>] = []
    var added = 0
    var removed = 0
    /// False when there were too many edits to align: the differing middle is one change.
    var aligned = true
    /// The line text is equal but one side ends with a newline and the other does not.
    var finalNewlineDiffers = false

    var isIdentical: Bool { changes.isEmpty && !finalNewlineDiffers }
}

/// Builds `UnifiedDiff`s with the reload markers' line diff (`LineDiff.myers`). Pure; run it off the main thread.
enum TextDiff {
    /// Neither side may be longer than this many UTF-16 units.
    static let sizeLimit = LineDiff.sizeLimit
    /// Past this many line edits the middle is shown as one change (Myers keeps O(D²) memory).
    static let maxEdits = 2000

    /// Nil when either text is over `sizeLimit`. Texts are compared as given: callers pass the logical (LF) text,
    /// so line endings and encodings never show up as changes.
    static func make(old: String, new: String, context: Int = 3, maxEdits: Int = maxEdits) -> UnifiedDiff? {
        guard old.utf16.count <= sizeLimit, new.utf16.count <= sizeLimit else { return nil }
        let a = lines(old), b = lines(new)
        var result = UnifiedDiff()

        var ids: [Substring: Int] = [:]
        func id(_ s: Substring) -> Int {
            if let v = ids[s] { return v }
            ids[s] = ids.count
            return ids.count - 1
        }
        let ia = a.map(id), ib = b.map(id)

        var prefix = 0
        while prefix < ia.count, prefix < ib.count, ia[prefix] == ib[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < ia.count - prefix, suffix < ib.count - prefix,
              ia[ia.count - 1 - suffix] == ib[ib.count - 1 - suffix] { suffix += 1 }
        let midA = Array(ia[prefix..<(ia.count - suffix)]), midB = Array(ib[prefix..<(ib.count - suffix)])

        // Hunks in both sides' line indices.
        struct Hunk { var oldStart: Int, removed: Int, newStart: Int, inserted: Int }
        var hunks: [Hunk] = []
        if !midA.isEmpty || !midB.isEmpty {
            if let found = LineDiff.myers(midA, midB, maxEdits: maxEdits) {
                var delta = 0   // removed − inserted before this hunk
                for h in found {
                    hunks.append(Hunk(oldStart: prefix + h.newStart + delta, removed: h.removed,
                                      newStart: prefix + h.newStart, inserted: h.inserted))
                    delta += h.removed - h.inserted
                }
            } else {
                result.aligned = false
                hunks = [Hunk(oldStart: prefix, removed: midA.count, newStart: prefix, inserted: midB.count)]
            }
        }
        result.finalNewlineDiffers = hunks.isEmpty && old != new
        result.added = hunks.reduce(0) { $0 + $1.inserted }
        result.removed = hunks.reduce(0) { $0 + $1.removed }

        func contextRows(old o: Range<Int>, newStart: Int) {
            for (k, i) in o.enumerated() {
                result.lines.append(DiffLine(kind: .context, oldNumber: i + 1, newNumber: newStart + k + 1, text: String(a[i])))
            }
        }
        func gap(_ n: Int) {
            if n > 0 { result.lines.append(DiffLine(kind: .gap, text: "", hidden: n)) }
        }

        // Unchanged lines between hunks: shown when few, otherwise `context` on each side of a gap.
        var oldPos = 0, newPos = 0
        for (index, h) in hunks.enumerated() {
            let between = h.oldStart - oldPos
            // A gap stands for two lines or more: one hidden line is simply shown.
            let lead = index == 0 && between > context + 1 ? context : between
            if index == 0 {
                gap(between - lead)
                contextRows(old: (h.oldStart - lead)..<h.oldStart, newStart: h.newStart - lead)
            } else if between > 2 * context + 1 {
                contextRows(old: oldPos..<(oldPos + context), newStart: newPos)
                gap(between - 2 * context)
                contextRows(old: (h.oldStart - context)..<h.oldStart, newStart: h.newStart - context)
            } else {
                contextRows(old: oldPos..<h.oldStart, newStart: newPos)
            }

            let start = result.lines.count
            let pairs = min(h.removed, h.inserted)
            var spans: [(NSRange?, NSRange?)] = []
            for k in 0..<pairs {
                spans.append(changedSpans(a[h.oldStart + k], b[h.newStart + k]))
            }
            for k in 0..<h.removed {
                result.lines.append(DiffLine(kind: .removed, oldNumber: h.oldStart + k + 1, text: String(a[h.oldStart + k]),
                                             changed: k < pairs ? spans[k].0 : nil))
            }
            for k in 0..<h.inserted {
                result.lines.append(DiffLine(kind: .added, newNumber: h.newStart + k + 1, text: String(b[h.newStart + k]),
                                             changed: k < pairs ? spans[k].1 : nil))
            }
            result.changes.append(start..<result.lines.count)
            oldPos = h.oldStart + h.removed
            newPos = h.newStart + h.inserted
        }
        if !hunks.isEmpty {
            let rest = a.count - oldPos
            let tail = rest > context + 1 ? context : rest
            contextRows(old: oldPos..<(oldPos + tail), newStart: newPos)
            gap(a.count - oldPos - tail)
        }
        return result
    }

    /// Lines without their newlines. A final newline ends the last line rather than starting an empty one.
    static func lines(_ text: String) -> [Substring] {
        if text.isEmpty { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    /// The differing middle of two paired lines (common prefix and suffix trimmed, on character boundaries),
    /// or nils when they share nothing worth marking, so the whole line reads as changed.
    static func changedSpans(_ x: Substring, _ y: Substring) -> (NSRange?, NSRange?) {
        let xs = Array(x), ys = Array(y)   // Characters: never splits a grapheme
        var p = 0
        while p < xs.count, p < ys.count, xs[p] == ys[p] { p += 1 }
        var s = 0
        while s < xs.count - p, s < ys.count - p, xs[xs.count - 1 - s] == ys[ys.count - 1 - s] { s += 1 }
        guard p + s > 0 else { return (nil, nil) }
        func range(_ c: [Character]) -> NSRange? {
            let lo = c[..<p].reduce(0) { $0 + $1.utf16.count }
            let len = c[p..<(c.count - s)].reduce(0) { $0 + $1.utf16.count }
            return len > 0 ? NSRange(location: lo, length: len) : nil
        }
        return (range(xs), range(ys))
    }
}
