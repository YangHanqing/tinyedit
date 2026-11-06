import Foundation

/// What the Tab key inserts. How wide a TAB character is drawn stays `EditorSettings.tabWidth`.
enum IndentStyle: Equatable, Sendable {
    case tabs
    case spaces(Int)

    /// "4 Spaces" or "Tabs", for menus.
    var label: String {
        switch self {
        case .tabs: String(localized: "Tabs")
        case .spaces(1): String(localized: "1 Space")
        case .spaces(let n): String(localized: "\(n) Spaces")
        }
    }

    var statusLabel: String { String(localized: "Indent: \(label)") }

    /// Order: a format's own rule, the text's style (nil when detection is off or found nothing), a language
    /// convention, then the user's preference. Makefile recipes need TABs and YAML forbids them; Go is gofmt's
    /// TABs and Python is PEP 8's four spaces unless the file already says otherwise.
    static func resolve(detected: IndentStyle?, language: EditorLanguage, preferred: IndentStyle) -> IndentStyle {
        switch language {
        case .makefile: return .tabs
        case .yaml:
            if case .spaces(let n)? = detected { return .spaces(n) }
            if case .spaces(let n) = preferred { return .spaces(n) }
            return .spaces(2)
        case .go: return detected ?? .tabs
        case .python: return detected ?? .spaces(4)
        default: return detected ?? preferred
        }
    }
}

enum IndentDetector {
    /// Guesses the indent style from leading whitespace. Nil when nothing is indented, so Settings applies.
    /// Bounded by `maxLines` indented lines and `maxUnits` UTF-16 units; runs off the main thread.
    static func detect(_ text: String, maxLines: Int = 2000, maxUnits: Int = 1 << 20) -> IndentStyle? {
        var tabLines = 0, spaceLines = 0
        var steps = [Int](repeating: 0, count: 9)   // indent increase between neighboring lines, 2...8
        var previous = 0                            // spaces of the last non-blank line; -1 after a TAB line
        var inLeading = true
        var spaces = 0, tabs = 0
        var scanned = 0
        for u in text.utf16 {
            scanned += 1
            if scanned > maxUnits || tabLines + spaceLines >= maxLines { break }
            if u == 0x0A {
                inLeading = true
                spaces = 0
                tabs = 0
                continue
            }
            guard inLeading else { continue }
            if u == 0x20 { spaces += 1; continue }
            if u == 0x09 { tabs += 1; continue }
            inLeading = false
            switch (tabs, spaces) {
            case (0, 0):
                previous = 0
            case (_, 0):
                tabLines += 1
                previous = -1
            case (0, 1):
                break   // " * " block-comment continuations say nothing about the indent unit
            case (0, _):
                spaceLines += 1
                let step = spaces - previous
                if previous >= 0, (2...8).contains(step) { steps[step] += 1 }
                previous = spaces
            default:
                previous = -1   // mixed TABs and spaces
            }
        }
        if tabLines == 0 && spaceLines == 0 { return nil }
        if tabLines > spaceLines { return .tabs }
        // Most frequent step; a tie goes to the smaller one.
        let best = (2...8).max { steps[$0] < steps[$1] || (steps[$0] == steps[$1] && $0 > $1) }!
        return steps[best] > 0 ? .spaces(best) : nil
    }
}

/// Pure edits behind Return, Tab, Shift-Tab and Backspace, so they can be tested without a text view.
enum IndentEditing {
    struct Edit: Equatable {
        var range: NSRange
        var string: String
    }

    /// Several edits applied as one undo step, in ascending order, plus the selection afterwards.
    struct LineEdits: Equatable {
        var edits: [Edit]
        var selection: NSRange
    }

    /// Return: a newline plus the current line's leading whitespace up to the caret. On a line that is only
    /// whitespace the indent moves down instead of being left behind as trailing whitespace.
    static func newline(in text: NSString, selection: NSRange) -> Edit {
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var wsEnd = lineStart
        while wsEnd < text.length, isBlank(text.character(at: wsEnd)) { wsEnd += 1 }
        let indent = text.substring(with: NSRange(location: lineStart, length: min(wsEnd, selection.location) - lineStart))
        let blankLine = wsEnd == text.length || text.character(at: wsEnd) == 0x0A
        if selection.length == 0, selection.location == wsEnd, blankLine, wsEnd > lineStart {
            return Edit(range: NSRange(location: lineStart, length: wsEnd - lineStart), string: "\n" + indent)
        }
        return Edit(range: selection, string: "\n" + indent)
    }

    /// Return in code, when the code before the caret ends with an opening bracket (or, in Python and YAML,
    /// a colon): the new line is one level deeper. With the matching closer right after the caret
    /// (`{|}`), the pair splits onto three lines and the caret goes on the middle one. Blanks around the
    /// caret are dropped. A trailing line comment is ignored; an opener inside an unclosed string is not one.
    /// Nil when no rule applies, and `newline` decides.
    static func smartNewline(in text: NSString, selection: NSRange, language: EditorLanguage,
                             style: IndentStyle) -> LineEdits? {
        let colon = language == .python || language == .yaml
        guard opensBlocks(language) else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        guard let codeEnd = codeEnd(text, from: lineStart, to: selection.location, language: language) else { return nil }
        var last = codeEnd
        while last > lineStart, isBlank(text.character(at: last - 1)) { last -= 1 }
        guard last > lineStart else { return nil }
        let opener = text.character(at: last - 1)
        let closer: unichar? = switch opener {
        case 0x7B: 0x7D   // { }
        case 0x5B: 0x5D   // [ ]
        case 0x28: 0x29   // ( )
        default: nil
        }
        guard closer != nil || (colon && opener == 0x3A) else { return nil }

        var wsEnd = lineStart
        while wsEnd < last, isBlank(text.character(at: wsEnd)) { wsEnd += 1 }
        let indent = text.substring(with: NSRange(location: lineStart, length: wsEnd - lineStart))
        let unit = switch style {
        case .tabs: "\t"
        case .spaces(let n): String(repeating: " ", count: max(n, 1))
        }
        // Replace from the end of the code before the caret (trailing blanks go) to the next non-blank after it.
        var after = NSMaxRange(selection)
        while after < text.length, isBlank(text.character(at: after)) { after += 1 }
        let start = selection.location == codeEnd ? last : selection.location
        let range = NSRange(location: start, length: after - start)
        let inner = "\n" + indent + unit
        let caret = start + (inner as NSString).length
        if let closer, after < text.length, text.character(at: after) == closer {
            return LineEdits(edits: [Edit(range: range, string: inner + "\n" + indent)],
                             selection: NSRange(location: caret, length: 0))
        }
        return LineEdits(edits: [Edit(range: range, string: inner)], selection: NSRange(location: caret, length: 0))
    }

    /// Languages whose blocks open with a bracket or colon at the end of a line. Prose, markup and
    /// line-oriented formats keep the plain indent.
    private static func opensBlocks(_ language: EditorLanguage) -> Bool {
        switch language {
        case .plain, .markdown, .diff, .html, .xml, .makefile, .dockerfile, .ini, .latex: false
        default: true
        }
    }

    /// Where the code before `caret` ends: at the caret, or where a line comment starts. Nil when the caret
    /// is inside a string. Quotes are `"`, `` ` `` and `'` (not in Rust, whose lifetimes are a lone `'`).
    private static func codeEnd(_ text: NSString, from lineStart: Int, to caret: Int, language: EditorLanguage) -> Int? {
        var comment: [unichar] = []
        if case .line(let token)? = LineEditing.commentSyntax(for: language) { comment = Array(token.utf16) }
        let single = language != .rust
        var quote: unichar?
        var i = lineStart
        while i < caret {
            let u = text.character(at: i)
            if let q = quote {
                if u == 0x5C { i += 2; continue }   // backslash escape
                if u == q { quote = nil }
            } else if u == 0x22 || u == 0x60 || (single && u == 0x27) {
                quote = u
            } else if !comment.isEmpty, u == comment[0], i + comment.count <= caret,
                      (0..<comment.count).allSatisfy({ text.character(at: i + $0) == comment[$0] }) {
                return i
            }
            i += 1
        }
        return quote == nil ? caret : nil
    }

    /// Tab: a TAB, or spaces. In the leading whitespace the spaces run to the next multiple of the indent width
    /// (a TAB before the caret runs to the next `tabWidth` stop), so a ragged indent snaps onto the grid. After
    /// text it is always `width` spaces: column alignment there would assume CJK and emoji fallback glyphs are
    /// exactly two columns wide, which they are not.
    static func tab(in text: NSString, selection: NSRange, style: IndentStyle, tabWidth: Int) -> String {
        guard case .spaces(let width) = style, width > 0 else { return "\t" }
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = NSRange(location: lineStart, length: selection.location - lineStart)
        let (wsEnd, column) = leadingWhitespace(text, before, tabWidth: tabWidth)
        guard wsEnd == selection.location else { return String(repeating: " ", count: width) }
        return String(repeating: " ", count: width - column % width)
    }

    /// True when Tab should indent lines instead of replacing the selection: it spans a line break.
    static func selectionSpansLines(in text: NSString, selection: NSRange) -> Bool {
        selection.length > 0 && text.range(of: "\n", range: selection).location != NSNotFound
    }

    /// Tab over a multi-line selection: each touched non-empty line gets one more indent level. Space indents
    /// go to the next multiple of the width, so a ragged line snaps onto the grid.
    static func indentLines(in text: NSString, selection: NSRange, style: IndentStyle, tabWidth: Int) -> LineEdits {
        var edits: [Edit] = []
        for line in touchedLines(in: text, selection: selection) {
            guard line.length > 0 else { continue }
            let (wsEnd, column) = leadingWhitespace(text, line, tabWidth: tabWidth)
            switch style {
            case .tabs:
                edits.append(Edit(range: NSRange(location: line.location, length: 0), string: "\t"))
            case .spaces(let width):
                let w = max(width, 1)
                edits.append(Edit(range: NSRange(location: wsEnd, length: 0),
                                  string: String(repeating: " ", count: w - column % w)))
            }
        }
        return LineEdits(edits: edits, selection: mapped(selection, through: edits))
    }

    /// Shift-Tab: each touched line loses one indent level, a leading TAB or spaces back to the previous
    /// multiple of the width (`tabWidth` when indenting with TABs). Lines without indent are left alone.
    static func outdentLines(in text: NSString, selection: NSRange, style: IndentStyle, tabWidth: Int) -> LineEdits {
        let width: Int
        switch style {
        case .tabs: width = max(tabWidth, 1)
        case .spaces(let n): width = max(n, 1)
        }
        var edits: [Edit] = []
        for line in touchedLines(in: text, selection: selection) {
            let end = NSMaxRange(line)
            guard line.location < end else { continue }
            if text.character(at: line.location) == 0x09 {
                edits.append(Edit(range: NSRange(location: line.location, length: 1), string: ""))
                continue
            }
            var spaces = 0
            while line.location + spaces < end, text.character(at: line.location + spaces) == 0x20 { spaces += 1 }
            guard spaces > 0 else { continue }
            let remove = spaces % width == 0 ? width : spaces % width
            edits.append(Edit(range: NSRange(location: line.location, length: remove), string: ""))
        }
        return LineEdits(edits: edits, selection: mapped(selection, through: edits))
    }

    /// Backspace in space indentation: with only spaces between the line start and the caret, delete back to
    /// the previous multiple of the width instead of one space. Nil leaves Backspace to AppKit.
    static func softTabDeletion(in text: NSString, caret: Int, style: IndentStyle) -> NSRange? {
        guard case .spaces(let width) = style, width > 1, caret > 0 else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let spaces = caret - lineStart
        guard spaces > 0 else { return nil }
        for i in lineStart..<caret where text.character(at: i) != 0x20 { return nil }
        let remove = spaces % width == 0 ? width : spaces % width
        return NSRange(location: caret - remove, length: remove)
    }

    // MARK: Helpers

    /// Lines the selection touches, without their newline. A selection that ends at a line start does not
    /// touch that line, unless the selection is empty.
    private static func touchedLines(in text: NSString, selection: NSRange) -> [NSRange] {
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        var lines: [NSRange] = []
        var location = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        repeat {
            let full = text.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(full)
            if end > full.location, text.character(at: end - 1) == 0x0A { end -= 1 }
            lines.append(NSRange(location: full.location, length: end - full.location))
            location = NSMaxRange(full)
        } while location <= last && location < text.length
        return lines
    }

    /// End of the line's leading blanks and their width in columns.
    private static func leadingWhitespace(_ text: NSString, _ line: NSRange, tabWidth: Int) -> (end: Int, column: Int) {
        var i = line.location, column = 0
        let tw = max(tabWidth, 1)
        while i < NSMaxRange(line) {
            let u = text.character(at: i)
            if u == 0x20 { column += 1 } else if u == 0x09 { column = (column / tw + 1) * tw } else { break }
            i += 1
        }
        return (i, column)
    }

    /// Where a position lands after the edits. A non-empty selection grows to take in an insertion at its
    /// start; a caret moves past one.
    static func mapped(_ selection: NSRange, through edits: [Edit]) -> NSRange {
        func map(_ p: Int, includeInsertAt: Bool) -> Int {
            var delta = 0
            for e in edits {
                let added = (e.string as NSString).length
                if e.range.length == 0 {
                    if e.range.location < p || (includeInsertAt && e.range.location == p) { delta += added }
                } else if e.range.location < p {
                    delta -= min(p, NSMaxRange(e.range)) - e.range.location
                }
            }
            return p + delta
        }
        if selection.length == 0 {
            let p = map(selection.location, includeInsertAt: true)
            return NSRange(location: p, length: 0)
        }
        let start = map(selection.location, includeInsertAt: false)
        let end = map(NSMaxRange(selection), includeInsertAt: false)
        return NSRange(location: start, length: max(end - start, 0))
    }

    private static func isBlank(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 }
}
