import AppKit

/// Applies token colors as TextKit 2 rendering attributes. Never touches NSTextStorage, so highlight
/// cannot reach undo, dirty, the pasteboard, or typing attributes.
@MainActor
final class HighlightController {
    private weak var host: EditorTextHost?
    private var task: Task<Void, Never>?
    /// True while the active buffer is above the highlight cap.
    private(set) var reduced = false
    var onReducedChanged: ((Bool) -> Void)?
    private var notedLargeFile = false
    /// The spans on the layout manager, the text length they were found for, and the tab swap they were
    /// applied after. Stale after a swap, which leaves no colors behind.
    private var applied: (spans: [HighlightSpan], length: Int, swap: Int)?
    var onNote: ((String) -> Void)?
    /// Every rendering attribute in this range was cleared (find matches too); called after the new colors are on.
    var onRegionRepainted: ((BufferTextStore, NSRange) -> Void)?

    init(host: EditorTextHost) { self.host = host }

    func schedule(store: BufferTextStore, language: EditorLanguage, delay: Duration = .milliseconds(200)) {
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.run(store: store, language: language)
        }
    }

    private func setReduced(_ v: Bool) {
        guard v != reduced else { return }
        reduced = v
        onReducedChanged?(v)
        if v, !notedLargeFile { notedLargeFile = true; onNote?(String(localized: "Highlighting paused for a large file.")) }
        if !v { notedLargeFile = false }
    }

    /// Skips a document that has no colors: clearing it would walk all of it on every settings change of a plain-text tab.
    private func clear(_ store: BufferTextStore) {
        defer { applied = nil }
        guard let host, let applied, applied.swap == host.contentSwaps, !applied.spans.isEmpty else { return }
        repaint([], in: NSRange(location: 0, length: store.length), store: store, host: host)
    }

    private func run(store: BufferTextStore, language: EditorLanguage) async {
        guard let host, host.activeStore === store else { return }
        let token = store.highlightToken
        let text = store.logicalString()
        let size = text.utf8.count
        guard language != .plain, size <= HighlightPolicy.offLimit else {
            setReduced(language != .plain)
            clear(store)
            return
        }
        setReduced(false)

        var limit: NSRange?
        if size > HighlightPolicy.fullLimit {
            limit = visibleWindow(store: store, host: host)
        }
        let spans = await Task.detached(priority: .utility) {
            SyntaxHighlighter.spans(language: language, text: text, limit: limit)
        }.value
        guard !Task.isCancelled, host.activeStore === store, store.highlightToken == token else { return }
        apply(spans, store: store, host: host)
    }

    /// Visible range plus 8000 UTF-16 units each side, expanded to line boundaries.
    private func visibleWindow(store: BufferTextStore, host: EditorTextHost) -> NSRange {
        let cs = store.contentStorage
        let ns = store.textStorage.mutableString
        var lo = 0, hi = ns.length
        if let vp = host.layoutManager.textViewportLayoutController.viewportRange {
            lo = cs.offset(from: cs.documentRange.location, to: vp.location)
            hi = cs.offset(from: cs.documentRange.location, to: vp.endLocation)
        }
        lo = max(0, lo - 8000); hi = min(ns.length, hi + 8000)
        let expanded = ns.lineRange(for: NSRange(location: lo, length: max(hi - lo, 0)))
        return expanded
    }

    /// Repaints only where the colors on screen differ from `spans`: after a keystroke, a few lines.
    private func apply(_ spans: [HighlightSpan], store: BufferTextStore, host: EditorTextHost) {
        let length = store.length
        let region: NSRange?
        if let previous = applied, previous.swap == host.contentSwaps {
            region = HighlightDiff.region(old: previous.spans, oldLength: previous.length, new: spans, newLength: length,
                                          edits: store.unhighlightedEdits)
        } else {
            region = NSRange(location: 0, length: length)
        }
        store.highlightApplied()
        applied = (spans, length, host.contentSwaps)
        if let region { repaint(spans, in: region, store: store, host: host) }
    }

    /// Clears `region` with `setRenderingAttributes`, which unlike removing an attribute does not cost
    /// per colored run, then adds back the spans that touch it and lets the find matches do the same.
    private func repaint(_ spans: [HighlightSpan], in region: NSRange, store: BufferTextStore, host: EditorTextHost) {
        let lm = host.layoutManager
        let cs = store.contentStorage
        let length = store.length
        guard NSMaxRange(region) <= length, let cleared = cs.textRange(for: region) else { return }
        lm.setRenderingAttributes([:], for: cleared)
        // Clipped to the region, in order: nested spans outside it keep the colors they already have.
        for span in spans where span.range.location < NSMaxRange(region) && NSMaxRange(span.range) > region.location {
            let r = NSIntersectionRange(span.range, region)
            guard r.location >= 0, r.length > 0, let tr = cs.textRange(for: r) else { continue }
            lm.addRenderingAttribute(.foregroundColor, value: span.kind.color, for: tr)
        }
        onRegionRepainted?(store, region)
        host.redrawVisibleText()
    }
}

extension NSTextContentStorage {
    /// UTF-16 `NSRange` to `NSTextRange`.
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
