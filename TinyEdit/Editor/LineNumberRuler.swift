import AppKit

/// Gutter with line numbers. Reads the active store's generation-tagged line index; never walks the string.
final class LineNumberRuler: NSRulerView {
    weak var host: EditorTextHost?
    private var fontSize: CGFloat = 11
    private var digits = 2

    init(scrollView: NSScrollView, host: EditorTextHost) {
        self.host = host
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = host.textView
        ruleThickness = thickness(for: 2)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    private func thickness(for digits: Int) -> CGFloat {
        let w = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)]).width
        return ceil(Double(max(2, digits)) * w + 12)
    }

    func update(fontSize editorSize: Double, lineCount: Int) {
        fontSize = max(9, CGFloat(editorSize) - 2)
        let d = String(max(lineCount, 1)).count
        digits = d
        let t = thickness(for: d)
        if abs(t - ruleThickness) > 0.5 { ruleThickness = t }
        needsDisplay = true
    }

    /// Confines everything the ruler paints (including AppKit's own edge line) to the rows next to the text.
    /// Without this a stray vertical line shows up above the editor, over the tab row.
    override func draw(_ dirtyRect: NSRect) {
        guard let clip = scrollView?.contentView else { super.draw(dirtyRect); return }
        let allowed = convert(clip.bounds, from: clip).intersection(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: allowed).addClip()
        super.draw(dirtyRect.intersection(allowed))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        guard let host, let store = host.activeStore, let tv = clientView as? NSTextView,
              let lm = tv.textLayoutManager, let cs = lm.textContentManager as? NSTextContentStorage else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: Theme.gutterText,
        ]
        func draw(_ number: Int, atTextViewY y: CGFloat, lineHeight: CGFloat) {
            let s = NSAttributedString(string: String(number), attributes: attrs)
            let size = s.size()
            let p = convert(NSPoint(x: 0, y: y), from: tv)
            s.draw(at: NSPoint(x: bounds.width - size.width - 6, y: p.y + (lineHeight - size.height) / 2))
        }

        let origin = tv.textContainerOrigin
        // The generation-tagged index may lag the text by a few ms while typing; a stale index is drawn
        // rather than flickering the gutter blank.
        guard let index = store.lineIndex, store.length > 0 else {
            if store.length == 0 { draw(1, atTextViewY: origin.y, lineHeight: tv.font.map { $0.boundingRectForFont.height } ?? 14) }
            return
        }
        guard let viewport = lm.textViewportLayoutController.viewportRange else { return }
        let docStart = cs.documentRange.location
        let markers = store.changeMarkers
        lm.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) { fragment in
            let loc = fragment.rangeInElement.location
            if viewport.endLocation.compare(loc) != .orderedDescending { return false }
            let offset = cs.offset(from: docStart, to: loc)
            if !markers.isEmpty {
                let length = cs.offset(from: loc, to: fragment.rangeInElement.endLocation)
                let hit = markers.gutterHit(paragraph: NSRange(location: offset, length: length), documentLength: store.length)
                drawChangeMarker(hit, frame: fragment.layoutFragmentFrame, origin: origin, textView: tv)
            }
            if offset <= index.indexedLength, index.isLineStart(offset) {
                let frame = fragment.layoutFragmentFrame
                let lineH = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
                draw(index.line(containing: offset), atTextViewY: frame.minY + origin.y, lineHeight: lineH)
            }
            return true
        }
        if digits != String(index.lineCount).count { update(fontSize: Double(fontSize + 2), lineCount: index.lineCount) }
    }

    /// A bar along the text edge for added or changed lines; a tick on the line boundary where lines were removed.
    private func drawChangeMarker(_ hit: [ChangeMarker].GutterHit, frame: CGRect, origin: CGPoint, textView tv: NSTextView) {
        let top = convert(NSPoint(x: 0, y: frame.minY + origin.y), from: tv).y
        if let bar = hit.bar {
            (bar == .added ? Theme.changeAdded : Theme.changeModified).setFill()
            NSRect(x: bounds.width - 4, y: top, width: 3, height: frame.height).fill()
        }
        Theme.changeDeleted.setFill()
        if hit.deletedAbove { NSRect(x: bounds.width - 8, y: top - 1, width: 7, height: 2).fill() }
        if hit.deletedBelow { NSRect(x: bounds.width - 8, y: top + frame.height - 1, width: 7, height: 2).fill() }
    }
}
