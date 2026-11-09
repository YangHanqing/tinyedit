import AppKit
import SwiftUI

@MainActor
protocol LargeFileViewDelegate: AnyObject {
    func largeFileEditLines()
    func largeFileDeleteLines()
    func largeFileDeleteNeedsWholeLines()
    func largeFileOpenSelection()
    func largeFileCopy()
    func largeFileTypedWhileReadOnly()
    func largeFileJumpFromFilter()
    func largeFileSelectionChanged()
}

/// Draws a large file's visible rows and nothing else: one CoreText line per row on screen, a gutter with the
/// file's line numbers, and scrollers of its own. A scroll view would need a document view as tall as every
/// row (tens of millions of points), so the position is a row number instead.
final class LargeFileTextView: NSView, NSMenuItemValidation {
    weak var delegate: LargeFileViewDelegate?
    var document: LargeFileDocument? {
        didSet {
            guard oldValue !== document else { return }
            lineCache.removeAll()
            widest = 0
            updateViewport()
            needsDisplay = true
        }
    }

    private struct CachedLine {
        var line: CTLine
        var row: LargeFileVisibleRow
        var matches: [NSRange]
        var width: CGFloat
    }

    private enum Drag {
        case none
        case text
        case vertical(grab: CGFloat)
        case horizontal(grab: CGFloat)

        var isScrolling: Bool {
            switch self {
            case .vertical, .horizontal: true
            default: false
            }
        }
    }

    private static let scrollerSize: CGFloat = 10
    private static let textInset: CGFloat = 8
    /// Only this much of a row is laid out at a time (a row holds at most 16 KB, so this covers it).
    private var fontSize = 0.0
    private var tabWidth = 0
    private var font = EditorConfiguration.font(size: EditorSettings.defaultFontSize)
    private var lineHeight: CGFloat = 16
    private var baseline: CGFloat = 12
    private var charWidth: CGFloat = 8
    private var paragraph: CTParagraphStyle?
    private var lineCache: [Int: CachedLine] = [:]
    private var cacheVersion = -1
    private var widest: CGFloat = 0
    private var drag = Drag.none

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { document?.undoManager }

    func apply(settings: EditorSettings) {
        guard settings.fontSize != fontSize || settings.tabWidth != tabWidth else { return }
        fontSize = settings.fontSize
        tabWidth = settings.tabWidth
        font = EditorConfiguration.font(size: fontSize)
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        baseline = ceil(font.ascender + (lineHeight - (font.ascender - font.descender)) / 2)
        charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        var interval = charWidth * CGFloat(max(tabWidth, 1))
        var stops: CFArray = [] as CFArray
        paragraph = withUnsafeBytes(of: &interval) { intervalPtr in
            withUnsafeBytes(of: &stops) { stopsPtr in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPtr.baseAddress!),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPtr.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        lineCache.removeAll()
        widest = 0
        updateViewport()
        needsDisplay = true
    }

    /// The document changed what is shown or where.
    func refresh() {
        guard let doc = document else { return }
        doc.topRow = min(max(doc.topRow, 0), doc.maxTopRow())
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineCache.removeAll()
        needsDisplay = true
    }

    private func updateViewport() {
        document?.viewportRows = max(Int(textHeight / lineHeight), 1)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry

    private var gutterWidth: CGFloat {
        let digits = max(String(document?.progress.lines ?? 0).count, 3)
        return CGFloat(digits) * charWidth + 20
    }

    private var textX: CGFloat { gutterWidth + Self.textInset }
    private var contentWidth: CGFloat { widest + textX + 40 }
    private var showsHorizontal: Bool { contentWidth > bounds.width }
    private var textHeight: CGFloat { bounds.height - (showsHorizontal ? Self.scrollerSize : 0) }
    private var maxXOffset: CGFloat { max(contentWidth - bounds.width + Self.scrollerSize, 0) }

    private var verticalTrack: NSRect {
        NSRect(x: bounds.maxX - Self.scrollerSize, y: 0, width: Self.scrollerSize, height: textHeight)
    }

    private var horizontalTrack: NSRect {
        NSRect(x: gutterWidth, y: bounds.maxY - Self.scrollerSize, width: bounds.width - gutterWidth - Self.scrollerSize,
               height: Self.scrollerSize)
    }

    private func verticalKnob(_ doc: LargeFileDocument) -> NSRect? {
        let rows = Double(doc.visualRows)
        guard rows > Double(doc.viewportRows) else { return nil }
        let track = verticalTrack
        let h = max(28, track.height * CGFloat(Double(doc.viewportRows) / rows))
        let maxTop = doc.maxTopRow()
        let y = maxTop > 0 ? (track.height - h) * CGFloat(doc.topRow / maxTop) : 0
        return NSRect(x: track.minX + 2, y: y, width: Self.scrollerSize - 4, height: h)
    }

    private func horizontalKnob(_ doc: LargeFileDocument) -> NSRect? {
        guard showsHorizontal else { return nil }
        let track = horizontalTrack
        let w = max(28, track.width * bounds.width / contentWidth)
        let x = maxXOffset > 0 ? (track.width - w) * doc.xOffset / maxXOffset : 0
        return NSRect(x: track.minX + x, y: track.minY + 2, width: w, height: Self.scrollerSize - 4)
    }

    // MARK: Lines

    private func cachedLine(_ visual: Int, _ doc: LargeFileDocument) -> CachedLine? {
        if let c = lineCache[visual] { return c }
        guard let row = doc.visibleRow(visual) else { return nil }
        // Theme colors resolve against the view's appearance, also when a click lays out a line outside drawing.
        var made: CachedLine?
        effectiveAppearance.performAsCurrentDrawingAppearance { made = makeLine(row, doc) }
        guard let c = made else { return nil }
        if lineCache.count > 400 { lineCache.removeAll() }
        lineCache[visual] = c
        return c
    }

    private func makeLine(_ row: LargeFileVisibleRow, _ doc: LargeFileDocument) -> CachedLine {
        let text = row.text as NSString
        let attributed = NSMutableAttributedString(string: row.text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Theme.textPrimary.cgColor,
        ])
        if let paragraph {
            attributed.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraph,
                                    range: NSRange(location: 0, length: text.length))
        }
        if let (range, color) = LogLevel.find(in: text) {
            attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range)
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        widest = max(widest, width)
        let matches = doc.highlightsMatches ? (doc.query?.ranges(in: row.text) ?? []) : []
        return CachedLine(line: line, row: row, matches: matches, width: width)
    }

    private func x(_ column: Int, _ c: CachedLine) -> CGFloat {
        column <= 0 ? 0 : CTLineGetOffsetForStringIndex(c.line, column, nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        guard let doc = document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if cacheVersion != doc.displayVersion {
            lineCache.removeAll()
            cacheVersion = doc.displayVersion
        }
        doc.topRow = min(max(doc.topRow, 0), doc.maxTopRow())
        doc.xOffset = min(max(doc.xOffset, 0), maxXOffset)
        let first = Int(doc.topRow)
        let shift = CGFloat(doc.topRow - Double(first)) * lineHeight
        let count = Int(ceil(textHeight / lineHeight)) + 1
        let selection = doc.selectionRange
        let current = doc.currentMatch
        let gutter = gutterWidth
        let left = textX - doc.xOffset
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]

        for i in 0..<count {
            let visual = first + i
            guard visual < doc.visualRows, let c = cachedLine(visual, doc) else { break }
            let y = CGFloat(i) * lineHeight - shift
            let display = doc.displayRow(forVisual: visual)

            if let (a, b) = selection {
                if a == b, visual == a.row {
                    Theme.currentLine.setFill()
                    NSRect(x: gutter, y: y, width: bounds.width - gutter, height: lineHeight).fill()
                } else if a != b, visual >= a.row, visual <= b.row {
                    let from = visual == a.row ? x(a.column, c) : 0
                    let to = visual == b.row ? x(b.column, c) : c.width + charWidth
                    Theme.textSelection.setFill()
                    NSRect(x: left + from, y: y, width: max(to - from, 0), height: lineHeight).fill()
                }
            }
            for r in c.matches {
                let isCurrent = current.map { $0.row == display && $0.range == r } ?? false
                (isCurrent ? Theme.findMatchCurrent : Theme.findMatch).setFill()
                let from = x(r.location, c)
                NSRect(x: left + from, y: y, width: x(NSMaxRange(r), c) - from, height: lineHeight).fill()
            }

            ctx.saveGState()
            ctx.clip(to: CGRect(x: gutter, y: y, width: bounds.width - gutter, height: lineHeight))
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: left, y: y + baseline)
            CTLineDraw(c.line, ctx)
            ctx.restoreGState()

            if let line = c.row.line {
                let s = NSAttributedString(string: String(line), attributes: numberAttrs)
                s.draw(at: NSPoint(x: gutter - 12 - s.size().width, y: y))
            }
            if c.row.edited {
                Theme.changeModified.setFill()
                NSRect(x: gutter - 5, y: y, width: 3, height: lineHeight).fill()
            }
        }

        let knobColor = Theme.textTertiary.withAlphaComponent(drag.isScrolling ? 0.75 : 0.45)
        knobColor.setFill()
        if let knob = verticalKnob(doc) { NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill() }
        if let knob = horizontalKnob(doc) { NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill() }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(NSRect(x: gutterWidth, y: 0, width: max(bounds.width - gutterWidth - Self.scrollerSize, 0),
                             height: textHeight), cursor: .iBeam)
    }

    private func position(at p: NSPoint, _ doc: LargeFileDocument) -> LargeFilePosition {
        let first = Int(doc.topRow)
        let shift = CGFloat(doc.topRow - Double(first)) * lineHeight
        let row = min(max(first + Int(floor((p.y + shift) / lineHeight)), 0), max(doc.visualRows - 1, 0))
        guard let c = cachedLine(row, doc) else { return LargeFilePosition(row: row, column: 0) }
        let x = p.x - textX + doc.xOffset
        guard x > 0 else { return LargeFilePosition(row: row, column: 0) }
        let length = (c.row.text as NSString).length
        let index = CTLineGetStringIndexForPosition(c.line, CGPoint(x: x, y: 0))
        return LargeFilePosition(row: row, column: min(max(index == kCFNotFound ? length : index, 0), length))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let knob = verticalKnob(doc), verticalTrack.contains(p) {
            if knob.contains(p) {
                drag = .vertical(grab: p.y - knob.minY)
            } else {
                drag = .vertical(grab: knob.height / 2)
                scrollVertical(to: p.y - knob.height / 2, knobHeight: knob.height, doc)
            }
            return needsDisplay = true
        }
        if let knob = horizontalKnob(doc), horizontalTrack.contains(p) {
            drag = .horizontal(grab: knob.contains(p) ? p.x - knob.minX : knob.width / 2)
            if !knob.contains(p) { scrollHorizontal(to: p.x - knob.width / 2, knobWidth: knob.width, doc) }
            return needsDisplay = true
        }
        guard doc.visualRows > 0 else { return }
        drag = .text
        var pos = position(at: p, doc)
        if p.x < gutterWidth { pos.column = 0 }
        if event.modifierFlags.contains(.shift), doc.anchor != nil {
            doc.head = pos
        } else if event.clickCount == 2, let c = cachedLine(pos.row, doc) {
            let r = Self.wordRange(in: c.row.text as NSString, at: pos.column)
            doc.anchor = LargeFilePosition(row: pos.row, column: r.location)
            doc.head = LargeFilePosition(row: pos.row, column: NSMaxRange(r))
            if doc.isFiltering { delegate?.largeFileJumpFromFilter() }
        } else if event.clickCount >= 3 || p.x < gutterWidth {
            doc.anchor = LargeFilePosition(row: pos.row, column: 0)
            doc.head = rowEnd(pos.row, doc)
        } else {
            doc.anchor = pos
            doc.head = pos
        }
        doc.currentMatch = nil
        selectionChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .vertical(let grab):
            if let knob = verticalKnob(doc) { scrollVertical(to: p.y - grab, knobHeight: knob.height, doc) }
        case .horizontal(let grab):
            if let knob = horizontalKnob(doc) { scrollHorizontal(to: p.x - grab, knobWidth: knob.width, doc) }
        case .text:
            if p.y < 0 { doc.topRow = max(doc.topRow - 2, 0) }
            if p.y > textHeight { doc.topRow = min(doc.topRow + 2, doc.maxTopRow()) }
            doc.head = position(at: NSPoint(x: p.x, y: min(max(p.y, 0), textHeight - 1)), doc)
            selectionChanged()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        needsDisplay = true
    }

    private func scrollVertical(to y: CGFloat, knobHeight: CGFloat, _ doc: LargeFileDocument) {
        let span = verticalTrack.height - knobHeight
        guard span > 0 else { return }
        doc.topRow = (Double(min(max(y / span, 0), 1)) * doc.maxTopRow()).rounded()
        if doc.follow, doc.topRow < doc.maxTopRow() { doc.setFollow(false) }
        needsDisplay = true
    }

    private func scrollHorizontal(to x: CGFloat, knobWidth: CGFloat, _ doc: LargeFileDocument) {
        let span = horizontalTrack.width - knobWidth
        guard span > 0 else { return }
        doc.xOffset = min(max((x - horizontalTrack.minX) / span, 0), 1) * maxXOffset
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let doc = document else { return }
        let precise = event.hasPreciseScrollingDeltas
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight * 3
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * charWidth * 3
        doc.topRow = min(max(doc.topRow - Double(dy / lineHeight), 0), doc.maxTopRow())
        doc.xOffset = min(max(doc.xOffset - dx, 0), maxXOffset)
        if dy > 0, doc.follow { doc.setFollow(false) }
        needsDisplay = true
    }

    private func rowEnd(_ row: Int, _ doc: LargeFileDocument) -> LargeFilePosition {
        if row + 1 < doc.visualRows { return LargeFilePosition(row: row + 1, column: 0) }
        return LargeFilePosition(row: row, column: (doc.visibleRow(row)?.text as NSString?)?.length ?? 0)
    }

    static func wordRange(in text: NSString, at column: Int) -> NSRange {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return word.contains(scalar)
        }
        guard isWord(column) || isWord(column - 1) else {
            return NSRange(location: min(column, text.length), length: column < text.length ? 1 : 0)
        }
        var start = isWord(column) ? column : column - 1
        var end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func selectionChanged() {
        needsDisplay = true
        delegate?.largeFileSelectionChanged()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let doc = document, doc.visualRows > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let pos = position(at: p, doc)
        if let rows = doc.selectedVisualRows, !rows.contains(pos.row) || !doc.hasSelection {
            doc.anchor = LargeFilePosition(row: pos.row, column: 0)
            doc.head = rowEnd(pos.row, doc)
            selectionChanged()
        } else if doc.selectionRange == nil {
            doc.anchor = LargeFilePosition(row: pos.row, column: 0)
            doc.head = rowEnd(pos.row, doc)
            selectionChanged()
        }
        let menu = NSMenu()
        if doc.isFiltering {
            menu.addItem(withTitle: String(localized: "Show in File"), action: #selector(showInFile(_:)), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: String(localized: "Edit Lines…"), action: #selector(editLines(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Delete Lines"), action: #selector(deleteLines(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Open in New Tab"), action: #selector(openSelection(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Keys and commands

    override func keyDown(with event: NSEvent) {
        guard let doc = document else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let page = Double(max(doc.viewportRows - 1, 1))
        func scroll(_ rows: Double) {
            doc.topRow = min(max(doc.topRow + rows, 0), doc.maxTopRow())
            if rows < 0, doc.follow { doc.setFollow(false) }
            needsDisplay = true
        }
        switch event.keyCode {
        case 126: flags.contains(.command) ? scroll(-doc.topRow) : scroll(-1)          // up
        case 125: flags.contains(.command) ? doc.scrollToEnd() : scroll(1)              // down
        case 116: scroll(-page)                                                          // page up
        case 121: scroll(page)                                                           // page down
        case 115: scroll(-doc.topRow)                                                    // home
        case 119: doc.scrollToEnd()                                                      // end
        case 123: doc.xOffset = max(doc.xOffset - charWidth * 8, 0); needsDisplay = true
        case 124: doc.xOffset = min(doc.xOffset + charWidth * 8, maxXOffset); needsDisplay = true
        case 36, 76: doc.isFiltering ? delegate?.largeFileJumpFromFilter() : delegate?.largeFileEditLines()
        case 51, 117:
            // The key takes whole lines only when that is what is selected; Delete Lines (menu) takes the touched lines.
            guard !doc.isFiltering, doc.hasSelection else { break }
            doc.selectionIsWholeRows ? delegate?.largeFileDeleteLines() : delegate?.largeFileDeleteNeedsWholeLines()
        default:
            let typed = event.characters?.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) } ?? false
            if typed, flags.isDisjoint(with: [.command, .control]) {
                delegate?.largeFileTypedWhileReadOnly()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) { delegate?.largeFileCopy() }
    @objc override func selectAll(_ sender: Any?) {
        document?.selectAll()
        selectionChanged()
    }
    @objc func undo(_ sender: Any?) { document?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { document?.undoManager.redo() }
    @objc private func editLines(_ sender: Any?) { delegate?.largeFileEditLines() }
    @objc private func deleteLines(_ sender: Any?) { delegate?.largeFileDeleteLines() }
    @objc private func openSelection(_ sender: Any?) { delegate?.largeFileOpenSelection() }
    @objc private func showInFile(_ sender: Any?) { delegate?.largeFileJumpFromFilter() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let doc = document else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(openSelection(_:)): return doc.hasSelection
        case #selector(undo(_:)):
            item.title = doc.undoManager.undoMenuItemTitle
            return doc.undoManager.canUndo && doc.canEdit
        case #selector(redo(_:)):
            item.title = doc.undoManager.redoMenuItemTitle
            return doc.undoManager.canRedo && doc.canEdit
        case #selector(editLines(_:)), #selector(deleteLines(_:)): return doc.canEdit
        default: return true
        }
    }
}

/// The level word of a log line (`ERROR`, `WARN`, `level=info`…) and its color. Only the first 200 characters
/// are looked at, and lowercase words only after `level=` or `"level":"`, so prose is left alone.
enum LogLevel {
    private static let colors: [String: NSColor] = [
        "FATAL": Theme.error, "CRITICAL": Theme.error, "ERROR": Theme.error, "ERR": Theme.error,
        "WARN": Theme.warning, "WARNING": Theme.warning,
        "INFO": Theme.accent, "NOTICE": Theme.accent,
        "DEBUG": Theme.textTertiary, "TRACE": Theme.textTertiary,
    ]

    static func find(in text: NSString) -> (NSRange, NSColor)? {
        let limit = min(text.length, 200)
        var i = 0
        while i < limit {
            let c = text.character(at: i)
            guard Self.isLetter(c) else { i += 1; continue }
            var end = i
            while end < text.length, Self.isLetter(text.character(at: end)) { end += 1 }
            let range = NSRange(location: i, length: end - i)
            if range.length <= 8 {
                let word = text.substring(with: range)
                if let color = colors[word] { return (range, color) }
                if let color = colors[word.uppercased()], afterLevelKey(text, i) { return (range, color) }
            }
            i = end
        }
        return nil
    }

    private static func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    private static func afterLevelKey(_ text: NSString, _ i: Int) -> Bool {
        for key in ["level=", "\"level\":\"", "level\":\"", "\"level\": \""] {
            let n = (key as NSString).length
            if i >= n, text.substring(with: NSRange(location: i - n, length: n)).lowercased() == key { return true }
        }
        return false
    }
}

/// The large-file view in the editor slot. AppState owns the one view of its window, like the text host.
struct LargeFileView: NSViewRepresentable {
    let view: LargeFileTextView
    let document: LargeFileDocument?
    let settings: EditorSettings

    func makeNSView(context: Context) -> LargeFileTextView { view }

    func updateNSView(_ nsView: LargeFileTextView, context: Context) {
        nsView.apply(settings: settings)
        if nsView.document !== document {
            nsView.document = document
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }
}
