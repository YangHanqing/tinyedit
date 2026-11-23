import AppKit

/// The matches of the find query in the active buffer, drawn as TextKit 2 rendering attributes: like
/// syntax colors they never reach the text storage, undo, dirty state or the pasteboard. The match the
/// selection sits on gets the stronger color. Not observed; `onCountsChanged` reports to the card.
@MainActor
final class FindMatchController {
    private weak var host: EditorTextHost?
    private var task: Task<Void, Never>?
    private(set) var matches: [NSRange] = []
    private(set) var current: Int?
    private(set) var capped = false
    private weak var paintedStore: BufferTextStore?
    /// The generation `matches` were found for: their offsets hold only while it is current.
    private var paintedGeneration: UInt64?
    /// Exact ranges currently painted with `.backgroundColor` on `paintedStore`, adjusted across edits so
    /// clearing them never has to walk every syntax-highlighted run in `documentRange`.
    private var paintedRanges: [NSRange] = []
    /// Called with (count, 1-based current, capped) after each search and selection move; nil count means no search.
    var onCountsChanged: ((Int?, Int?, Bool) -> Void)?

    init(host: EditorTextHost) { self.host = host }

    /// Shifts `paintedRanges` when `store` is edited so clearing them later still hits only those ranges.
    func noteEdit(in store: BufferTextStore, editedRange: NSRange, delta: Int) {
        guard paintedStore === store, !paintedRanges.isEmpty else { return }
        let oldEnd = editedRange.location + max(0, editedRange.length - delta)
        let length = store.length
        var adjusted: [NSRange] = []
        adjusted.reserveCapacity(paintedRanges.count)
        for r in paintedRanges {
            let rEnd = NSMaxRange(r)
            if rEnd <= editedRange.location {
                if r.location < length {
                    adjusted.append(NSRange(location: r.location, length: min(r.length, length - r.location)))
                }
            } else if r.location >= oldEnd {
                let loc = max(0, r.location + delta)
                if loc < length {
                    adjusted.append(NSRange(location: loc, length: min(r.length, length - loc)))
                }
            } else {
                // Overlapped the edited region: expand to cover the surviving span.
                let start = min(r.location, editedRange.location)
                let end = min(length, max(NSMaxRange(editedRange), max(0, rEnd + delta)))
                if end > start { adjusted.append(NSRange(location: start, length: end - start)) }
            }
        }
        paintedRanges = adjusted
    }

    /// Searches `store` off the main thread after `delay`. With `selectFrom`, the first match at or after
    /// that offset is selected and scrolled to (typing in the find field).
    func schedule(store: BufferTextStore, query: String, caseSensitive: Bool, regex: Bool = false, delay: Duration,
                  selectFrom: Int? = nil) {
        task?.cancel()
        guard !query.isEmpty else {
            clear()
            onCountsChanged?(nil, nil, false)
            return
        }
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let generation = store.generation
            let text = store.logicalString()
            let work = Task.detached(priority: .userInitiated) {
                FindMatches.ranges(of: query, in: text as NSString, caseSensitive: caseSensitive, regex: regex,
                                   isCancelled: { Task.isCancelled })
            }
            let (ranges, capped) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, store.generation == generation,
                  let host = self.host, host.activeStore === store else { return }
            self.matches = ranges
            self.current = nil   // it indexed the old matches
            self.capped = capped
            if let selectFrom, let i = FindMatches.firstIndex(atOrAfter: selectFrom, in: ranges) {
                host.textView.setSelectedRange(ranges[i])   // the selection-change callback runs before current is set
                host.textView.scrollRangeToVisible(ranges[i])
            }
            self.current = FindMatches.index(of: host.textView.selectedRange(), in: ranges)
            self.paint(store: store, host: host)
            self.report()
        }
    }

    /// The selection moved: repaint the old and new current match only.
    func selectionChanged(_ store: BufferTextStore) {
        guard let host, paintedStore === store, !matches.isEmpty else { return }
        let new = FindMatches.index(of: host.textView.selectedRange(), in: matches)
        guard new != current else { return }
        let old = current
        current = new
        let cs = store.contentStorage
        for (i, color) in [(old, Theme.findMatch), (new, Theme.findMatchCurrent)] {
            guard let i, i < matches.count, NSMaxRange(matches[i]) <= store.length, let tr = cs.textRange(for: matches[i]) else { continue }
            host.layoutManager.addRenderingAttribute(.backgroundColor, value: color, for: tr)
        }
        host.redrawVisibleText()
        report()
    }

    /// Highlighting reset every rendering attribute in `region`: paint the matches there again.
    func restore(in region: NSRange, store: BufferTextStore) {
        guard let host, paintedStore === store, paintedGeneration == store.generation, !matches.isEmpty else { return }
        let cs = store.contentStorage
        var i = 0, hi = matches.count
        while i < hi {
            let mid = (i + hi) / 2
            if NSMaxRange(matches[mid]) <= region.location { i = mid + 1 } else { hi = mid }
        }
        while i < matches.count, matches[i].location < NSMaxRange(region) {
            if NSMaxRange(matches[i]) <= store.length, let tr = cs.textRange(for: matches[i]) {
                host.layoutManager.addRenderingAttribute(.backgroundColor, value: i == current ? Theme.findMatchCurrent : Theme.findMatch,
                                                         for: tr)
            }
            i += 1
        }
    }

    func clear() {
        task?.cancel()
        matches = []
        current = nil
        capped = false
        guard let host, let store = paintedStore else { paintedRanges = []; return }
        paintedStore = nil
        if host.activeStore === store {
            clearPainted(in: store, host: host)
            host.redrawVisibleText()
        } else {
            paintedRanges = []
        }
    }

    private func clearPainted(in store: BufferTextStore, host: EditorTextHost) {
        guard !paintedRanges.isEmpty else { return }
        let lm = host.layoutManager
        let cs = store.contentStorage
        let length = store.length
        for r in paintedRanges {
            let loc = min(r.location, length)
            let len = min(r.length, length - loc)
            guard len > 0, let tr = cs.textRange(for: NSRange(location: loc, length: len)) else { continue }
            lm.removeRenderingAttribute(.backgroundColor, for: tr)
        }
        paintedRanges = []
    }

    private func paint(store: BufferTextStore, host: EditorTextHost) {
        if paintedStore === store {
            clearPainted(in: store, host: host)
        } else {
            paintedRanges = []
        }
        let lm = host.layoutManager
        let cs = store.contentStorage
        let length = store.length
        var painted: [NSRange] = []
        painted.reserveCapacity(matches.count)
        for (i, r) in matches.enumerated() {
            guard NSMaxRange(r) <= length, let tr = cs.textRange(for: r) else { continue }
            lm.addRenderingAttribute(.backgroundColor, value: i == current ? Theme.findMatchCurrent : Theme.findMatch, for: tr)
            painted.append(r)
        }
        paintedRanges = painted
        paintedStore = store
        paintedGeneration = store.generation
        host.redrawVisibleText()
    }

    private func report() {
        onCountsChanged?(matches.count, current.map { $0 + 1 }, capped)
    }
}
