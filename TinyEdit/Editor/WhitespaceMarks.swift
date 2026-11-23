import AppKit

/// A blank character inside the selection, drawn so a space and a tab never look alike.
struct WhitespaceMark: Equatable {
    enum Kind: Equatable { case space, tab, noBreakSpace, ideographicSpace }

    var kind: Kind
    /// The character's cell, in text-view coordinates.
    var rect: NSRect
    /// Baseline of the line, in text-view coordinates.
    var baseline: CGFloat
    /// Inside the selection; the others (Show Invisible Characters) draw fainter.
    var selected = true

    static func kind(of unit: unichar) -> Kind? {
        switch unit {
        case 0x20: .space
        case 0x09: .tab
        case 0xA0: .noBreakSpace
        case 0x3000: .ideographicSpace
        default: nil
        }
    }
}

extension EditorTextView {
    /// Upper bound on marks per pass, so a tiny font over a whitespace-heavy selection stays cheap.
    static let whitespaceMarkLimit = 20_000

    /// Marks for selected blanks (every blank with `everywhere`) on the lines that intersect `visible`. Lays
    /// out only those lines, and visits only the visible columns of a long unwrapped line.
    func whitespaceMarks(in visible: NSRect, everywhere: Bool = false) -> [WhitespaceMark] {
        let selections = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard everywhere || !selections.isEmpty, visible.width > 0, visible.height > 0,
              let lm = textLayoutManager, let cs = textContentStorage,
              let text = cs.textStorage?.mutableString, text.length > 0 else { return [] }
        let origin = textContainerOrigin
        let doc = cs.documentRange.location
        let top = CGPoint(x: 0, y: max(visible.minY - origin.y, 0))
        guard let first = lm.textLayoutFragment(for: top) else { return [] }

        var marks: [WhitespaceMark] = []
        lm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if origin.y + frame.minY > visible.maxY { return false }
            let fragStart = cs.offset(from: doc, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let lineTop = origin.y + frame.minY + bounds.minY
                guard lineTop < visible.maxY, lineTop + bounds.height > visible.minY else { continue }
                let lineStart = fragStart + line.characterRange.location
                let lineEnd = lineStart + line.characterRange.length
                let lineX = origin.x + frame.minX + bounds.minX
                // `locationForCharacter` takes an index into the paragraph (`line.attributedString`) and returns x
                // from this line's start. A line-relative index collapses to 0 on every wrapped line after the first.
                func x(_ index: Int) -> CGFloat {
                    lineX + line.locationForCharacter(at: line.characterRange.location + index - lineStart).x
                }
                let spans = everywhere ? [NSRange(location: lineStart, length: lineEnd - lineStart)] : selections
                for sel in spans {
                    var lo = max(sel.location, lineStart)
                    var hi = min(NSMaxRange(sel), lineEnd)
                    guard lo < hi else { continue }
                    lo = firstIndex(in: lo..<hi) { x($0 + 1) > visible.minX }
                    hi = firstIndex(in: lo..<hi) { x($0) >= visible.maxX }
                    var i = lo
                    while i < hi {
                        if let kind = WhitespaceMark.kind(of: text.character(at: i)) {
                            let x0 = x(i), x1 = x(i + 1)
                            let selected = !everywhere || selections.contains { NSLocationInRange(i, $0) }
                            marks.append(WhitespaceMark(kind: kind,
                                                        rect: NSRect(x: x0, y: lineTop, width: max(x1 - x0, 0), height: bounds.height),
                                                        baseline: lineTop + line.glyphOrigin.y, selected: selected))
                            if marks.count >= Self.whitespaceMarkLimit { return false }
                        }
                        i += 1
                    }
                }
            }
            return true
        }
        return marks
    }

    /// First index in `range` where the monotonic `predicate` holds, or `range.upperBound`.
    private func firstIndex(in range: Range<Int>, where predicate: (Int) -> Bool) -> Int {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

/// Draws `WhitespaceMark`s above the text. Covers only the visible rect and is never in the text
/// storage, so the marks cannot be copied, undone, or saved.
final class WhitespaceMarkView: NSView {
    var marks: [WhitespaceMark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    var drawingFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { if drawingFont != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty else { return }
        let size = drawingFont.pointSize
        let xHeight = drawingFont.xHeight > 0 ? drawingFont.xHeight : size * 0.5
        let stroke = max(1, (size / 13).rounded())
        for mark in marks {
            let r = mark.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard r.intersects(dirtyRect) else { continue }
            let midY = (mark.baseline - frame.minY) - xHeight / 2
            (mark.selected ? Theme.whitespaceMarker : Theme.whitespaceMarkerFaint).set()
            switch mark.kind {
            case .space, .noBreakSpace:
                let d = max(2, (size * 0.18).rounded())
                let dot = NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: midY - d / 2, width: d, height: d))
                if mark.kind == .space {
                    dot.fill()
                } else {
                    dot.lineWidth = stroke
                    dot.stroke()
                }
            case .tab:
                let head = min(size * 0.3, max(r.width - 2, 2))
                let left = r.minX + min(size * 0.15, r.width * 0.2)
                let right = max(r.maxX - min(size * 0.15, r.width * 0.2), left + head)
                let arrow = NSBezierPath()
                arrow.lineWidth = stroke
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                arrow.move(to: NSPoint(x: left, y: midY))
                arrow.line(to: NSPoint(x: right, y: midY))
                arrow.move(to: NSPoint(x: right - head, y: midY - head * 0.7))
                arrow.line(to: NSPoint(x: right, y: midY))
                arrow.line(to: NSPoint(x: right - head, y: midY + head * 0.7))
                arrow.stroke()
            case .ideographicSpace:
                let side = min(r.width * 0.6, xHeight * 1.3)
                let box = NSBezierPath(rect: NSRect(x: r.midX - side / 2, y: midY - side / 2, width: side, height: side)
                    .insetBy(dx: stroke / 2, dy: stroke / 2))
                box.lineWidth = stroke
                box.stroke()
            }
        }
    }
}
