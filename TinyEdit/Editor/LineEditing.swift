import Foundation

/// Pure edits behind the Edit ▸ Line commands, Toggle Comment and the save-time cleanup. Each result is
/// applied by the text view as one undo step, like the edits in `IndentEditing`.
enum LineEditing {
    typealias Edit = IndentEditing.Edit
    typealias LineEdits = IndentEditing.LineEdits

    /// The whole lines the selection touches, with the last one's newline when it has one. A selection that
    /// ends at a line start does not touch that line.
    static func block(in text: NSString, selection: NSRange) -> NSRange {
        let start = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let end = NSMaxRange(text.lineRange(for: NSRange(location: min(last, text.length), length: 0)))
        return NSRange(location: start, length: end - start)
    }

    private static func endsWithNewline(_ text: NSString, _ range: NSRange) -> Bool {
        range.length > 0 && text.character(at: NSMaxRange(range) - 1) == 0x0A
    }

    private static func shifted(_ selection: NSRange, by delta: Int) -> NSRange {
        NSRange(location: selection.location + delta, length: selection.length)
    }

    /// The touched lines again below themselves; the selection moves to the copy.
    static func duplicate(in text: NSString, selection: NSRange) -> LineEdits {
        let b = block(in: text, selection: selection)
        let s = text.substring(with: b)
        let insert = endsWithNewline(text, b) ? s : "\n" + s
        return LineEdits(edits: [Edit(range: NSRange(location: NSMaxRange(b), length: 0), string: insert)],
                         selection: shifted(selection, by: (insert as NSString).length))
    }

    /// Swaps the touched lines with the line above. Nil on the first line.
    static func moveUp(in text: NSString, selection: NSRange) -> LineEdits? {
        let b = block(in: text, selection: selection)
        guard b.location > 0 else { return nil }
        let prev = text.lineRange(for: NSRange(location: b.location - 1, length: 0))
        let moved = text.substring(with: b), above = text.substring(with: prev)
        let joined = endsWithNewline(text, b) ? moved + above : moved + "\n" + above.dropLast()
        return LineEdits(edits: [Edit(range: NSRange(location: prev.location, length: prev.length + b.length), string: joined)],
                         selection: shifted(selection, by: -prev.length))
    }

    /// Swaps the touched lines with the line below. Nil on the last line.
    static func moveDown(in text: NSString, selection: NSRange) -> LineEdits? {
        let b = block(in: text, selection: selection)
        guard endsWithNewline(text, b), NSMaxRange(b) < text.length else { return nil }
        let next = text.lineRange(for: NSRange(location: NSMaxRange(b), length: 0))
        let moved = text.substring(with: b), below = text.substring(with: next)
        let nextHasNewline = endsWithNewline(text, next)
        let joined = nextHasNewline ? below + moved : below + "\n" + moved.dropLast()
        return LineEdits(edits: [Edit(range: NSRange(location: b.location, length: b.length + next.length), string: joined)],
                         selection: shifted(selection, by: next.length + (nextHasNewline ? 0 : 1)))
    }

    /// Removes the touched lines. On the last line the newline before it goes instead, so no empty line stays.
    static func deleteLines(in text: NSString, selection: NSRange) -> LineEdits? {
        let b = block(in: text, selection: selection)
        guard b.length > 0 || b.location > 0 else { return nil }
        if endsWithNewline(text, b) || b.location == 0 {
            return LineEdits(edits: [Edit(range: b, string: "")], selection: NSRange(location: b.location, length: 0))
        }
        let caret = text.lineRange(for: NSRange(location: b.location - 1, length: 0)).location
        return LineEdits(edits: [Edit(range: NSRange(location: b.location - 1, length: b.length + 1), string: "")],
                         selection: NSRange(location: caret, length: 0))
    }

    /// Joins the touched lines, or the caret's line with the next. Each line break and the next line's
    /// indent become one space; no space is added after a blank or before an empty line.
    static func joinLines(in text: NSString, selection: NSRange) -> LineEdits? {
        let b = block(in: text, selection: selection)
        var end = endsWithNewline(text, b) ? NSMaxRange(b) - 1 : NSMaxRange(b)
        if text.range(of: "\n", range: NSRange(location: b.location, length: end - b.location)).location == NSNotFound {
            guard end < text.length else { return nil }   // one line, and it is the last
            let next = text.lineRange(for: NSRange(location: end + 1, length: 0))
            end = endsWithNewline(text, next) ? NSMaxRange(next) - 1 : NSMaxRange(next)
        }
        var edits: [Edit] = []
        var i = b.location
        while i < end {
            if text.character(at: i) == 0x0A {
                var j = i + 1
                while j < end, isBlank(text.character(at: j)) { j += 1 }
                let afterBlank = i > b.location && isBlank(text.character(at: i - 1))
                let nextEmpty = j >= end || text.character(at: j) == 0x0A
                edits.append(Edit(range: NSRange(location: i, length: j - i), string: afterBlank || nextEmpty ? "" : " "))
                i = j
            } else {
                i += 1
            }
        }
        guard !edits.isEmpty else { return nil }
        if selection.length == 0, edits.count == 1 {
            return LineEdits(edits: edits, selection: NSRange(location: edits[0].range.location, length: 0))
        }
        let delta = edits.reduce(0) { $0 + ($1.string as NSString).length - $1.range.length }
        return LineEdits(edits: edits, selection: NSRange(location: b.location, length: end - b.location + delta))
    }

    // MARK: Comments

    enum CommentSyntax: Equatable {
        case line(String)
        case block(String, String)
    }

    static func commentSyntax(for language: EditorLanguage) -> CommentSyntax? {
        switch language {
        case .plain, .json, .diff: return nil
        case .markdown, .html, .xml: return .block("<!--", "-->")
        case .css: return .block("/*", "*/")
        case .python: return .line("#")
        default:
            guard let token = LanguageSyntax.table[language]?.lineComments.first else { return nil }
            return .line(String(decoding: token, as: UTF16.self))
        }
    }

    /// Comments the touched non-blank lines at their smallest indent, or uncomments them when every one
    /// already is. Block syntax wraps each line on its own. With only blank lines, the caret's line is commented.
    static func toggleComment(in text: NSString, selection: NSRange, syntax: CommentSyntax) -> LineEdits {
        var lines = contentLines(in: text, selection: selection)
        var content = lines.filter { firstNonBlank(text, $0) < NSMaxRange($0) }
        if content.isEmpty {
            lines = [lines[0]]
            content = lines
        }
        let indent = content.map { firstNonBlank(text, $0) - $0.location }.min() ?? 0
        var edits: [Edit] = []
        switch syntax {
        case .line(let token):
            let t = token as NSString
            let commented = content.allSatisfy { has(text, t, at: firstNonBlank(text, $0), before: NSMaxRange($0)) }
            for line in content {
                if commented {
                    let at = firstNonBlank(text, line)
                    var length = t.length
                    if at + length < NSMaxRange(line), text.character(at: at + length) == 0x20 { length += 1 }
                    edits.append(Edit(range: NSRange(location: at, length: length), string: ""))
                } else {
                    edits.append(Edit(range: NSRange(location: line.location + indent, length: 0), string: token + " "))
                }
            }
        case .block(let open, let close):
            let o = open as NSString, c = close as NSString
            let wrapped = content.allSatisfy { line in
                let start = firstNonBlank(text, line), end = lastNonBlankEnd(text, line)
                return end - start >= o.length + c.length && has(text, o, at: start, before: end) && has(text, c, at: end - c.length, before: end)
            }
            for line in content {
                if wrapped {
                    let start = firstNonBlank(text, line), end = lastNonBlankEnd(text, line)
                    var openLength = o.length, closeStart = end - c.length
                    if start + openLength < closeStart, text.character(at: start + openLength) == 0x20 { openLength += 1 }
                    if closeStart > start + openLength, text.character(at: closeStart - 1) == 0x20 { closeStart -= 1 }
                    edits.append(Edit(range: NSRange(location: start, length: openLength), string: ""))
                    edits.append(Edit(range: NSRange(location: closeStart, length: end - closeStart), string: ""))
                } else {
                    edits.append(Edit(range: NSRange(location: line.location + indent, length: 0), string: open + " "))
                    edits.append(Edit(range: NSRange(location: lastNonBlankEnd(text, line), length: 0), string: " " + close))
                }
            }
        }
        return LineEdits(edits: edits, selection: IndentEditing.mapped(selection, through: edits))
    }

    /// The touched lines without their newlines.
    static func contentLines(in text: NSString, selection: NSRange) -> [NSRange] {
        let b = block(in: text, selection: selection)
        var lines: [NSRange] = []
        var location = b.location
        repeat {
            let full = text.lineRange(for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: full.location, length: endsWithNewline(text, full) ? full.length - 1 : full.length))
            location = NSMaxRange(full)
        } while location < NSMaxRange(b)
        return lines
    }

    static func firstNonBlank(_ text: NSString, _ line: NSRange) -> Int {
        var i = line.location
        while i < NSMaxRange(line), isBlank(text.character(at: i)) { i += 1 }
        return i
    }

    private static func lastNonBlankEnd(_ text: NSString, _ line: NSRange) -> Int {
        var i = NSMaxRange(line)
        while i > line.location, isBlank(text.character(at: i - 1)) { i -= 1 }
        return i
    }

    private static func has(_ text: NSString, _ token: NSString, at location: Int, before end: Int) -> Bool {
        location + token.length <= end && text.substring(with: NSRange(location: location, length: token.length)) == token as String
    }

    private static func isBlank(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 }

    // MARK: Save cleanup

    /// Edits that drop spaces and TABs at line ends and add a final newline to non-empty text.
    static func saveCleanup(in text: NSString, trimTrailingWhitespace: Bool, ensureFinalNewline: Bool) -> [Edit] {
        var edits: [Edit] = []
        var blankStart = -1
        var i = 0
        var last: UInt16 = 0
        for u in (text as String).utf16 {
            if u == 0x20 || u == 0x09 {
                if blankStart < 0 { blankStart = i }
            } else {
                if u == 0x0A, blankStart >= 0, trimTrailingWhitespace {
                    edits.append(Edit(range: NSRange(location: blankStart, length: i - blankStart), string: ""))
                }
                blankStart = -1
            }
            last = u
            i += 1
        }
        if trimTrailingWhitespace, blankStart >= 0 {
            edits.append(Edit(range: NSRange(location: blankStart, length: i - blankStart), string: ""))
        }
        if ensureFinalNewline, i > 0, last != 0x0A {
            edits.append(Edit(range: NSRange(location: i, length: 0), string: "\n"))
        }
        return edits
    }

    // MARK: Go to line

    /// "12", "12:5" or "12,5" as a 1-based line and optional column. Nil when it is not that.
    static func parseLineTarget(_ input: String) -> (line: Int, column: Int?)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "：" || $0 == "，" })
        guard (1...2).contains(parts.count), let line = Int(parts[0].trimmingCharacters(in: .whitespaces)), line > 0 else { return nil }
        if parts.count == 1 { return (line, nil) }
        guard let column = Int(parts[1].trimmingCharacters(in: .whitespaces)), column > 0 else { return nil }
        return (line, column)
    }
}

/// The bracket next to the caret and its partner, by nesting depth. Strings and comments are not skipped.
enum BracketMatcher {
    static let scanLimit = 50_000

    /// (bracket at the caret, its partner). The character before the caret wins over the one after it.
    static func match(in text: NSString, caret: Int) -> (NSRange, NSRange)? {
        for index in [caret - 1, caret] where index >= 0 && index < text.length {
            if let partner = partner(of: index, in: text) {
                return (NSRange(location: index, length: 1), NSRange(location: partner, length: 1))
            }
        }
        return nil
    }

    /// Where Go to Matching Bracket puts the caret: just past a closing partner, just before an opening one,
    /// so pressing it again jumps back. With no bracket next to the caret, the enclosing pair's opener.
    static func jumpTarget(in text: NSString, caret: Int) -> Int? {
        if let (near, far) = match(in: text, caret: caret) {
            return far.location > near.location ? NSMaxRange(far) : far.location
        }
        var depth = 0
        var i = caret - 1
        while i >= 0, caret - i <= scanLimit {
            if let (_, forward) = pairs[text.character(at: i)] {
                if !forward { depth += 1 } else if depth == 0 { return i } else { depth -= 1 }
            }
            i -= 1
        }
        return nil
    }

    private static let pairs: [unichar: (unichar, Bool)] = [
        0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),     // ( [ {
        0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false),   // ) ] }
    ]

    private static func partner(of index: Int, in text: NSString) -> Int? {
        let c = text.character(at: index)
        guard let (other, forward) = pairs[c] else { return nil }
        var depth = 0
        var i = index
        var steps = 0
        while steps < scanLimit {
            i += forward ? 1 : -1
            steps += 1
            guard i >= 0, i < text.length else { return nil }
            let u = text.character(at: i)
            if u == c { depth += 1 } else if u == other {
                if depth == 0 { return i }
                depth -= 1
            }
        }
        return nil
    }
}
