import AppKit

/// Which editor decorations are on, from `EditorSettings`. Each decoration can be disabled independently.
struct EditorDecorationOptions: Equatable {
    var currentLine = true
    var indentGuides = true
    var invisibles = false
    var matchingBrackets = true
    var selectionOccurrences = true
    var jsonMarks = JSONMarkOptions()
}

/// Which JSON value marks are drawn (Settings ▸ Editor ▸ JSON). Generic decode marks are off by default.
struct JSONMarkOptions: Equatable {
    var images = true
    var links = true
    var colors = true
    var times = true
    /// A JWT's expiry; with this off, a JWT gets the decode icon when `decodes` is on.
    var jwtExpiry = true
    var decodes = false

    /// The mark as drawn under these options: a JWT's expiry dropped when it is off, nil when hidden.
    func shown(_ kind: JSONValueMark.Kind) -> JSONValueMark.Kind? {
        switch kind {
        case .image: images ? kind : nil
        case .link: links ? kind : nil
        case .color: colors ? kind : nil
        case .date: times ? kind : nil
        case .decode(let expiry?) where jwtExpiry: .decode(jwtExpiry: expiry)
        case .decode: decodes ? .decode(jwtExpiry: nil) : nil
        }
    }
}

/// What the clip view paints beneath the text for the visible rect, in text-view coordinates. The clip
/// view converts them to its own coordinates when drawing. Beneath, so selection and text draw on top, and never
/// in the text storage, so none of it can be copied, undone or saved.
struct EditorDecorations: Equatable {
    struct Guide: Equatable {
        var x: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// A mark after a line of a JSON tab for a value on it: a Preview icon for a picture, an open icon for
    /// a link, a swatch for a color, the local time for a Unix timestamp, a decode icon (with the expiry for
    /// a JWT that has one). All but the swatch take a click.
    struct ValueMark: Equatable {
        enum Kind: Equatable {
            case image, link, decode
            case color(JSONColor)
            case time(String)
            /// `exp 2026-01-01 08:00` and `expired` or `in 3 days`; both empty when only the symbol fits.
            case jwt(String, status: String, expired: Bool)
        }

        /// The mark's drawing, hit and hover area.
        var rect: NSRect
        var valueRange: NSRange
        var kind: Kind
        var hovered = false

        /// `exp 2026-01-01 08:00 · in 3 days`.
        static func jwtLabel(_ text: String, _ status: String) -> String { text + " · " + status }

        var isClickable: Bool {
            switch kind {
            case .color: false
            default: true
            }
        }
    }

    /// The caret's line, painted across the whole width. Only with an empty selection.
    var currentLine: NSRect?
    /// The bracket at the caret and its partner, when on screen.
    var brackets: [NSRect] = []
    /// Other occurrences of the selected text on screen.
    var occurrences: [NSRect] = []
    var guides: [Guide] = []
    var valueMarks: [ValueMark] = []
    /// The font of the time marks' text.
    var markFont: NSFont?

    /// Selected text shorter than this, on one line, has its other occurrences marked.
    static let occurrenceMaxLength = 200
    static let occurrenceLimit = 500
}

extension EditorTextView {
    /// Decorations for the lines that intersect `visible`. Lays out only those lines.
    func decorations(in visible: NSRect) -> EditorDecorations {
        var result = EditorDecorations()
        guard visible.width > 0, visible.height > 0, let lm = textLayoutManager, let cs = textContentStorage,
              let text = cs.textStorage?.string as NSString? else { return result }
        let origin = textContainerOrigin
        let doc = cs.documentRange.location
        let drawingFont = font ?? EditorConfiguration.font(size: 13)
        let lineHeight = ceil(drawingFont.ascender - drawingFont.descender + drawingFont.leading)
        let sel = selectedRange()
        let caretOnly = selectedRanges.count == 1 && sel.length == 0

        // The visible paragraphs: their start offsets and frames.
        var fragments: [(start: Int, fragment: NSTextLayoutFragment)] = []
        if text.length > 0, let first = lm.textLayoutFragment(for: CGPoint(x: 0, y: max(visible.minY - origin.y, 0))) {
            lm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
                if origin.y + fragment.layoutFragmentFrame.minY > visible.maxY { return false }
                fragments.append((cs.offset(from: doc, to: fragment.rangeInElement.location), fragment))
                return true
            }
        }
        let visibleStart = fragments.first?.start ?? 0
        let visibleEnd = fragments.last.map { $0.start + cs.offset(from: $0.fragment.rangeInElement.location, to: $0.fragment.rangeInElement.endLocation) } ?? 0

        if decorationOptions.currentLine, caretOnly {
            result.currentLine = caretLineRect(sel.location, text: text, fragments: fragments, origin: origin, lineHeight: lineHeight)
        }

        if decorationOptions.matchingBrackets, caretOnly, let (near, far) = BracketMatcher.match(in: text, caret: sel.location) {
            for r in [near, far] where r.location >= visibleStart && NSMaxRange(r) <= visibleEnd {
                result.brackets += segmentRects(r, lm: lm, cs: cs, origin: origin)
            }
        }

        if decorationOptions.selectionOccurrences, selectedRanges.count == 1, (1...EditorDecorations.occurrenceMaxLength).contains(sel.length), NSMaxRange(sel) <= text.length {
            let needle = text.substring(with: sel)
            if !needle.contains("\n"), !needle.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let wholeWord = needle.unicodeScalars.allSatisfy(Self.isWordScalar)
                var from = visibleStart
                while from < visibleEnd, result.occurrences.count < EditorDecorations.occurrenceLimit {
                    let r = text.range(of: needle, options: [.literal], range: NSRange(location: from, length: visibleEnd - from))
                    if r.location == NSNotFound { break }
                    from = NSMaxRange(r)
                    if r == sel { continue }
                    if wholeWord, !isWordBoundary(text, r) { continue }
                    result.occurrences += segmentRects(r, lm: lm, cs: cs, origin: origin)
                }
            }
        }

        if decorationOptions.indentGuides, !fragments.isEmpty {
            result.guides = indentGuides(text: text, fragments: fragments, origin: origin, font: drawingFont)
        }

        if let values = jsonValueMarks?(), !values.isEmpty, !fragments.isEmpty {
            let markFont = NSFont(descriptor: drawingFont.fontDescriptor, size: max(drawingFont.pointSize - 1, 8)) ?? drawingFont
            result.valueMarks = valueMarks(values, options: decorationOptions.jsonMarks, text: text, fragments: fragments,
                                           origin: origin, font: drawingFont, markFont: markFont, caret: sel.location)
            result.markFont = result.valueMarks.isEmpty ? nil : markFont
        }
        return result
    }

    /// One mark per visible paragraph that holds a value the options show, after its last character: for the
    /// innermost value holding the caret when it starts on that paragraph, else for the first. Not drawn when
    /// it would not fit.
    private func valueMarks(_ values: [JSONValueMark], options: JSONMarkOptions, text: NSString,
                            fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                            origin: NSPoint, font: NSFont, markFont: NSFont, caret: Int) -> [EditorDecorations.ValueMark] {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        var next = values.partitioningIndex { $0.valueRange.location >= fragments[0].start }
        var marks: [EditorDecorations.ValueMark] = []
        for (start, fragment) in fragments {
            let end = start + fragment.rangeInElement.length(in: textContentStorage)
            var here: [JSONValueMark] = []
            while next < values.count, values[next].valueRange.location < end {
                if values[next].valueRange.location >= start, let kind = options.shown(values[next].kind) {
                    here.append(JSONValueMark(valueRange: values[next].valueRange, kind: kind))
                }
                next += 1
            }
            guard let first = here.first else { continue }
            let value = here.filter { $0.valueRange.location <= caret && caret <= NSMaxRange($0.valueRange) }
                .min { $0.valueRange.length < $1.valueRange.length } ?? first
            var contentEnd = end
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            let offset = contentEnd - start
            let lines = fragment.textLineFragments
            guard let line = lines.first(where: { NSLocationInRange(offset, $0.characterRange) })
                ?? lines.last(where: { $0.characterRange.length > 0 }) else { continue }
            let frame = fragment.layoutFragmentFrame
            let bounds = line.typographicBounds
            let x = origin.x + frame.minX + bounds.minX + line.locationForCharacter(at: offset).x
            let side = ceil(min(bounds.height, font.pointSize * 1.3))
            var kind: EditorDecorations.ValueMark.Kind
            var width: CGFloat
            switch value.kind {
            case .image:
                (kind, width) = (.image, side + 6)
            case .link:
                (kind, width) = (.link, side + 6)
            case .color(let color):
                (kind, width) = (.color(color), side)
            case .date(let date, let milliseconds):
                let label = JSONValueInsight.dateText(date, milliseconds: milliseconds)
                (kind, width) = (.time(label), labelWidth(label, markFont) + 8)
            case .decode(nil):
                (kind, width) = (.decode, side + 6)
            case .decode(let expiry?):
                let e = JSONValueInsight.expiryText(expiry)
                (kind, width) = (.jwt(e.text, status: e.status, expired: e.expired),
                                 side + 4 + labelWidth(EditorDecorations.ValueMark.jwtLabel(e.text, e.status), markFont) + 8)
            }
            var rect = NSRect(x: (x + max(space, 6)).rounded(), y: (origin.y + frame.minY + bounds.minY + (bounds.height - side) / 2).rounded(),
                              width: width, height: side)
            // A JWT's expiry that does not fit leaves its symbol, which still opens the decode card.
            if rect.maxX > self.bounds.width - 2, case .jwt(_, _, let expired) = kind {
                (kind, width) = (.jwt("", status: "", expired: expired), side + 6)
                rect.size.width = width
            }
            guard rect.maxX <= self.bounds.width - 2 else { continue }
            let mark = EditorDecorations.ValueMark(rect: rect, valueRange: value.valueRange, kind: kind)
            marks.append(mark)
            marks[marks.count - 1].hovered = mark.isClickable && (mouse.map(rect.contains) ?? false)
        }
        return marks
    }

    private func labelWidth(_ label: String, _ font: NSFont) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Parts

    /// The caret's visual line. After a final newline (or in an empty document) the caret is on the extra
    /// line below the last paragraph.
    private func caretLineRect(_ caret: Int, text: NSString, fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                               origin: NSPoint, lineHeight: CGFloat) -> NSRect? {
        let onExtraLine = caret == text.length && (text.length == 0 || text.character(at: text.length - 1) == 0x0A)
        if onExtraLine {
            guard text.length > 0 else { return NSRect(x: 0, y: origin.y, width: 0, height: lineHeight) }
            guard let last = fragments.last, last.start + last.fragment.rangeInElement.length(in: textContentStorage) == text.length
            else { return nil }
            let frame = last.fragment.layoutFragmentFrame
            if let extra = last.fragment.textLineFragments.last, last.fragment.textLineFragments.count > 1, extra.characterRange.length == 0 {
                return NSRect(x: 0, y: origin.y + frame.minY + extra.typographicBounds.minY, width: 0, height: extra.typographicBounds.height)
            }
            return NSRect(x: 0, y: origin.y + frame.maxY, width: 0, height: lineHeight)
        }
        for (start, fragment) in fragments {
            let length = fragment.rangeInElement.length(in: textContentStorage)
            guard caret >= start, caret < start + length || (caret == start + length && caret == text.length) else { continue }
            let offset = caret - start
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let line = lines.first { NSLocationInRange(offset, $0.characterRange) } ?? lines.last
            guard let line else { return nil }
            return NSRect(x: 0, y: origin.y + frame.minY + line.typographicBounds.minY, width: 0, height: line.typographicBounds.height)
        }
        return nil
    }

    private func segmentRects(_ range: NSRange, lm: NSTextLayoutManager, cs: NSTextContentStorage, origin: NSPoint) -> [NSRect] {
        guard let tr = cs.textRange(for: range) else { return [] }
        var rects: [NSRect] = []
        lm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
            if frame.width > 0 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
            return true
        }
        return rects
    }

    /// One guide per indent level of each visible paragraph, at the left edge of that level's column. A blank
    /// line takes the smaller indent of its neighbors, so guides run through blank lines inside a block.
    private func indentGuides(text: NSString, fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                              origin: NSPoint, font: NSFont) -> [EditorDecorations.Guide] {
        let style = indentStyle?() ?? .spaces(tabWidth)
        let width: Int
        switch style {
        case .tabs: width = max(tabWidth, 1)
        case .spaces(let n): width = max(n, 1)
        }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let tw = max(tabWidth, 1)
        var columns: [Int?] = fragments.map { start, _ in
            var i = start, column = 0
            while i < text.length, i - start < 400 {
                let u = text.character(at: i)
                if u == 0x20 { column += 1 } else if u == 0x09 { column = (column / tw + 1) * tw } else { break }
                i += 1
            }
            return i >= text.length || text.character(at: i) == 0x0A ? nil : column
        }
        // Blank lines: the smaller of the nearest non-blank indents above and below.
        var above: Int?
        var filled = columns
        for k in columns.indices {
            if let c = columns[k] { above = c; continue }
            let below = columns[(k + 1)...].lazy.compactMap { $0 }.first
            filled[k] = [above, below].compactMap { $0 }.min() ?? 0
        }
        columns = filled

        var guides: [EditorDecorations.Guide] = []
        for (k, (_, fragment)) in fragments.enumerated() {
            let levels = (columns[k] ?? 0) / width
            guard levels > 0 else { continue }
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let minY = origin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0)
            let maxY = origin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height)
            for level in 0..<levels {
                let x = (origin.x + frame.minX + CGFloat(level * width) * space).rounded(.down) + 0.5
                guides.append(.init(x: x, minY: minY, maxY: maxY))
            }
        }
        return guides
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        s == "_" || CharacterSet.alphanumerics.contains(s)
    }

    private func isWordBoundary(_ text: NSString, _ r: NSRange) -> Bool {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let s = Unicode.Scalar(text.character(at: i)) else { return false }
            return Self.isWordScalar(s)
        }
        return !isWord(r.location - 1) && !isWord(NSMaxRange(r))
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, which is false then true across the array.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

private extension NSTextRange {
    func length(in cs: NSTextContentStorage?) -> Int {
        cs?.offset(from: location, to: endLocation) ?? 0
    }
}

@MainActor
enum EditorDecorationDrawing {
    /// Painted after the background pattern, beneath the text. `width` spans the clip view.
    static func draw(_ d: EditorDecorations, in bounds: NSRect, dirtyRect: NSRect) {
        if let line = d.currentLine {
            let r = NSRect(x: bounds.minX, y: line.minY, width: bounds.width, height: line.height)
            if r.intersects(dirtyRect) {
                Theme.currentLine.setFill()
                r.fill()
            }
        }
        if !d.guides.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 1
            for g in d.guides where g.maxY >= dirtyRect.minY && g.minY <= dirtyRect.maxY {
                path.move(to: NSPoint(x: g.x, y: g.minY))
                path.line(to: NSPoint(x: g.x, y: g.maxY))
            }
            Theme.indentGuide.setStroke()
            path.stroke()
        }
        for r in d.occurrences where r.intersects(dirtyRect) {
            Theme.occurrenceHighlight.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        for mark in d.valueMarks where mark.rect.intersects(dirtyRect) {
            drawValueMark(mark, font: d.markFont)
        }
        for r in d.brackets where r.intersects(dirtyRect) {
            let box = r.insetBy(dx: 0.5, dy: 0.5)
            Theme.bracketMatch.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            Theme.bracketMatchBorder.setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// An accent symbol for a picture, a link or a decode, a swatch for a color, a time or a size in faint
    /// text, a JWT's symbol and expiry (the status in the warning color once expired); the clickable ones on
    /// a chip while the pointer is over them.
    private static func drawValueMark(_ mark: EditorDecorations.ValueMark, font: NSFont?) {
        if mark.hovered {
            Theme.occurrenceHighlight.setFill()
            NSBezierPath(roundedRect: mark.rect, xRadius: 4, yRadius: 4).fill()
        }
        switch mark.kind {
        case .image:
            drawSymbol("photo", in: mark.rect)
        case .link:
            drawSymbol("arrow.up.right.square", in: mark.rect)
        case .decode:
            drawSymbol("wand.and.stars", in: mark.rect)
        case .color(let c):
            let side = (mark.rect.height * 0.72).rounded()
            let box = NSRect(x: (mark.rect.midX - side / 2).rounded(), y: (mark.rect.midY - side / 2).rounded(),
                             width: side, height: side).insetBy(dx: 0.5, dy: 0.5)
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            Theme.separator.setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()
        case .time(let label):
            guard let font else { return }
            drawLabel(NSAttributedString(string: label, attributes: labelAttributes(font, hovered: mark.hovered)),
                      at: mark.rect.minX + 4, in: mark.rect)
        case .jwt(let text, _, _) where text.isEmpty:
            drawSymbol("key", in: mark.rect)
        case .jwt(let text, let status, let expired):
            guard let font else { return }
            let side = mark.rect.height
            drawSymbol("key", in: NSRect(x: mark.rect.minX, y: mark.rect.minY, width: side + 4, height: side))
            let attributes = labelAttributes(font, hovered: mark.hovered)
            let label = NSMutableAttributedString(string: text + " · ", attributes: attributes)
            var statusAttributes = attributes
            if expired { statusAttributes[.foregroundColor] = Theme.warning }
            label.append(NSAttributedString(string: status, attributes: statusAttributes))
            drawLabel(label, at: mark.rect.minX + side + 4, in: mark.rect)
        }
    }

    private static func labelAttributes(_ font: NSFont, hovered: Bool) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: hovered ? Theme.textSecondary : Theme.textTertiary]
    }

    private static func drawLabel(_ label: NSAttributedString, at x: CGFloat, in rect: NSRect) {
        let height = label.size().height
        label.draw(at: NSPoint(x: x, y: (rect.midY - height / 2).rounded()))
    }

    private static func drawSymbol(_ name: String, in rect: NSRect) {
        // Resolved here, in the view's appearance: the symbol's palette does not follow a dynamic color.
        let color = Theme.accent.usingColorSpace(.sRGB) ?? Theme.accent
        let config = NSImage.SymbolConfiguration(pointSize: (rect.height * 0.72).rounded(), weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let size = symbol.size
        let r = NSRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
        symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
