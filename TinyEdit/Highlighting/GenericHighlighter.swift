import Foundation

/// One scanner for every language that `LanguageSyntax` can describe. Pure and allocation-light.
enum GenericHighlighter {
    private static let nullish: Set<String> = ["null", "nil", "none", "undefined", "NULL", "Null", "~"]

    static func scan(_ u: [UInt16], syntax s: LanguageSyntax) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        let n = u.count
        var i = 0
        var lineStart = true            // only whitespace (and a YAML "- ") seen on this line so far
        var bracketDepth = 0, braceDepth = 0   // open `[` and `{` in values, for `valueBrackets` and `inlineTableKeys`

        func at(_ token: [UInt16], _ p: Int) -> Bool {
            guard !token.isEmpty, p + token.count <= n else { return false }
            for k in 0..<token.count where u[p + k] != token[k] { return false }
            return true
        }
        func lineEnd(_ p: Int) -> Int { var j = p; while j < n, u[j] != 0x0A { j += 1 }; return j }
        func add(_ a: Int, _ b: Int, _ k: TokenKind) { if b > a { out.append(HighlightSpan(range: NSRange(location: a, length: b - a), kind: k)) } }
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }
        func isHex(_ c: UInt16) -> Bool { SyntaxHighlighter.isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        func identPart(_ c: UInt16) -> Bool { SyntaxHighlighter.isIdentPart(c) || (s.dashIdentifiers && c == 0x2D) }
        func bareKeyPart(_ c: UInt16) -> Bool { SyntaxHighlighter.isIdentPart(c) || c == 0x2D || c == 0x2E || isSpace(c) }
        func digits(_ p: Int, _ count: Int) -> Bool {
            guard p + count <= n else { return false }
            for k in p..<(p + count) where !SyntaxHighlighter.isDigit(u[k]) { return false }
            return true
        }
        /// End of `HH:MM[:SS[.frac]]` at `p`, or nil.
        func timeEnd(_ p: Int) -> Int? {
            guard digits(p, 2), p + 2 < n, u[p + 2] == 0x3A, digits(p + 3, 2) else { return nil }
            var e = p + 5
            if e < n, u[e] == 0x3A, digits(e + 1, 2) { e += 3 }
            if e + 1 < n, u[e] == 0x2E, SyntaxHighlighter.isDigit(u[e + 1]) { e += 1; while e < n, SyntaxHighlighter.isDigit(u[e]) { e += 1 } }
            return e
        }
        /// End of a date, time or date-time literal at `p` (`1979-05-27`, `07:32:00`, `1979-05-27T07:32:00.5-07:00`), or nil.
        func dateTimeEnd(_ p: Int) -> Int? {
            var e: Int
            if digits(p, 4), p + 4 < n, u[p + 4] == 0x2D, digits(p + 5, 2), p + 7 < n, u[p + 7] == 0x2D, digits(p + 8, 2) {
                e = p + 10
                if e < n, u[e] == 0x54 || u[e] == 0x74 || u[e] == 0x20, let t = timeEnd(e + 1) {
                    e = t
                    if e < n, u[e] == 0x5A || u[e] == 0x7A { e += 1 }
                    else if e < n, u[e] == 0x2B || u[e] == 0x2D, digits(e + 1, 2), e + 3 < n, u[e + 3] == 0x3A, digits(e + 4, 2) { e += 6 }
                }
            } else if let t = timeEnd(p) {
                e = t
            } else {
                return nil
            }
            return e < n && SyntaxHighlighter.isIdentPart(u[e]) ? nil : e
        }
        /// After a quoted key at `p`: the end of the whole (dotted) key when `=` or `: ` follows, else nil.
        func quotedKeyEnd(_ p: Int) -> Int? {
            var k = p, end = p
            while k < n {
                let d = u[k]
                if d == 0x3D || (d == 0x3A && (k + 1 >= n || isSpace(u[k + 1]) || u[k + 1] == 0x0A)) { return end }
                if d == 0x22 || d == 0x27 {
                    var m = k + 1
                    while m < n, u[m] != d, u[m] != 0x0A { m += 1 }
                    guard m < n, u[m] == d else { return nil }
                    k = m + 1; end = k
                    continue
                }
                guard bareKeyPart(d) else { return nil }
                k += 1
                if !isSpace(d) { end = k }
            }
            return nil
        }

        outer: while i < n {
            let c = u[i]
            if c == 0x0A { lineStart = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            let wasLineStart = lineStart
            lineStart = false
            let afterListDash = i >= 2 && u[i - 1] == 0x20 && u[i - 2] == 0x2D
            var inlineKey = false
            if s.inlineTableKeys, braceDepth > 0 {
                var p = i - 1
                while p >= 0, isSpace(u[p]) { p -= 1 }
                inlineKey = p >= 0 && (u[p] == 0x7B || u[p] == 0x2C)
            }
            let keyPosition = s.keyValue && (wasLineStart || afterListDash || inlineKey)

            // Block comments
            for (o, cl) in s.blockComments where at(o, i) {
                var j = i + o.count
                while j < n, !at(cl, j) { j += 1 }
                let e = min(n, j + cl.count)
                add(i, e, .comment)
                i = e
                continue outer
            }
            // `#include`-style lines
            if s.preprocessor, c == 0x23, wasLineStart {
                var j = lineEnd(i)
                while j < n, j > i, u[j - 1] == 0x5C { j = lineEnd(j + 1) }   // backslash continuation
                add(i, j, .preprocessor)
                i = j
                continue
            }
            // Line comments
            for p in s.lineComments where at(p, i) {
                if s.hashNeedsBoundary, c == 0x23, i > 0 {
                    let prev = u[i - 1]
                    if !(isSpace(prev) || prev == 0x0A || prev == 0x3B || prev == 0x28 || prev == 0x7C || prev == 0x26) { break }
                }
                let j = lineEnd(i)
                add(i, j, .comment)
                i = j
                continue outer
            }
            // Strings
            for rule in s.strings where at(rule.open, i) {
                var j = i + rule.open.count
                var closed = false
                let limit = rule.maxLength.map { min(n, j + $0) } ?? n
                while j < limit {
                    if rule.escapes, u[j] == 0x5C { j += 2; continue }
                    if at(rule.close, j) { j += rule.close.count; closed = true; break }
                    if !rule.multiline, u[j] == 0x0A { break }
                    j += 1
                }
                j = min(j, n)
                if rule.maxLength != nil, !closed { continue }     // not a literal after all, try the next rule
                if keyPosition, closed, !rule.multiline, let e = quotedKeyEnd(j) {   // `"quoted key" = v`, `"a".b = v`
                    add(i, e, .key)
                    i = e
                    continue outer
                }
                add(i, j, .string)
                i = j
                continue outer
            }
            // Section headers and keys
            if wasLineStart, s.sectionHeaders, c == 0x5B, !s.valueBrackets || bracketDepth == 0 {
                // To the closing `]` (`]]` for a TOML array of tables), so a comment after it is still a comment.
                let double = i + 1 < n && u[i + 1] == 0x5B
                let e = lineEnd(i)
                var j = i + (double ? 2 : 1), end = e
                while j < e {
                    if u[j] == 0x22 || u[j] == 0x27 {
                        let q = u[j]
                        j += 1
                        while j < e, u[j] != q { j += 1 }
                    } else if u[j] == 0x5D {
                        end = min(e, j + (double && j + 1 < e && u[j + 1] == 0x5D ? 2 : 1))
                        break
                    }
                    j += 1
                }
                add(i, end, .heading)
                i = end
                continue
            }
            if inlineKey, SyntaxHighlighter.isIdentPart(c) || c == 0x2D {
                var j = i
                while j < n, bareKeyPart(u[j]) { j += 1 }
                if j < n, u[j] == 0x3D {
                    var e = j
                    while e > i, isSpace(u[e - 1]) { e -= 1 }
                    add(i, e, .key); i = j
                    continue
                }
            }
            if s.keyValue, wasLineStart || afterListDash {
                if c == 0x2D, i + 1 < n, u[i + 1] == 0x20 { lineStart = true; i += 1; continue }   // YAML "- key: v"
                if SyntaxHighlighter.isIdentStart(c) || SyntaxHighlighter.isDigit(c) || c == 0x2E || c == 0x2D || c == 0x24 {
                    var j = i
                    while j < n, u[j] != 0x0A, u[j] != 0x3A, u[j] != 0x3D, u[j] != 0x23 { j += 1 }
                    if j < n, u[j] == 0x3D || (u[j] == 0x3A && (j + 1 >= n || isSpace(u[j + 1]) || u[j + 1] == 0x0A)) {
                        var e = j
                        while e > i, isSpace(u[e - 1]) { e -= 1 }
                        if e - i <= 80 {
                            // A key line cannot be inside a TOML array, so an unclosed `[` above it ends here.
                            if u[j] == 0x3D { bracketDepth = 0; braceDepth = 0 }
                            add(i, e, .key); i = j
                            continue
                        }
                    }
                }
            }
            // @attribute / @media / \command
            if let prefix = s.attributePrefix, c == prefix, i + 1 < n, SyntaxHighlighter.isIdentStart(u[i + 1]) {
                var j = i + 1
                while j < n, SyntaxHighlighter.isIdentPart(u[j]) || (u[j] == 0x2E && prefix == 0x40 && j + 1 < n && SyntaxHighlighter.isIdentStart(u[j + 1])) { j += 1 }
                add(i, j, .attribute)
                i = j
                continue
            }
            if s.hexColors, c == 0x23 {
                var j = i + 1
                while j < n, isHex(u[j]) { j += 1 }
                if (4...9).contains(j - i), j >= n || !SyntaxHighlighter.isIdentPart(u[j]) { add(i, j, .number); i = j; continue }
            }
            if s.dollarVariables, c == 0x24 {
                var j = i + 1
                if j < n, u[j] == 0x7B { while j < n, u[j] != 0x7D, u[j] != 0x0A { j += 1 }; j = min(n, j + 1) }
                else { while j < n, SyntaxHighlighter.isIdentPart(u[j]) || u[j] == 0x3F || u[j] == 0x40 || u[j] == 0x23 { j += 1 } }
                i = max(j, i + 1)
                continue
            }
            // Words
            if SyntaxHighlighter.isIdentStart(c) {
                var j = i
                while j < n, identPart(u[j]) { j += 1 }
                if j - i <= 24 {
                    let raw = String(decoding: u[i..<j], as: UTF16.self)
                    let word = s.caseInsensitive ? raw.lowercased() : raw
                    if s.keywords.contains(word) || (s.caseInsensitive && s.keywords.contains(raw.lowercased())) {
                        add(i, j, .keyword)
                    } else if s.constants.contains(raw) || (s.caseInsensitive && s.constants.contains(word)) {
                        add(i, j, nullish.contains(raw) ? .null : .boolean)
                    } else if s.colonSpaceKeys {
                        var k = j
                        while k < n, isSpace(u[k]) { k += 1 }
                        if k + 1 < n, u[k] == 0x3A, isSpace(u[k + 1]) { add(i, j, .key) }
                    }
                }
                i = j
                continue
            }
            if s.dateTimes, SyntaxHighlighter.isDigit(c), let e = dateTimeEnd(i) {
                add(i, e, .number)
                i = e
                continue
            }
            // Numbers
            if SyntaxHighlighter.isDigit(c) {
                var j = i
                while j < n, SyntaxHighlighter.isIdentPart(u[j]) || (u[j] == 0x2E && j + 1 < n && SyntaxHighlighter.isDigit(u[j + 1])) { j += 1 }
                add(i, j, .number)
                i = j
                continue
            }
            switch c {
            case 0x5B: bracketDepth += 1
            case 0x5D: bracketDepth = max(0, bracketDepth - 1)
            case 0x7B: braceDepth += 1
            case 0x7D: braceDepth = max(0, braceDepth - 1)
            default: break
            }
            i += 1
        }
        return out
    }
}

enum MarkupHighlighter {
    static func scan(_ u: [UInt16]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        let n = u.count
        var i = 0
        func add(_ a: Int, _ b: Int, _ k: TokenKind) { if b > a { out.append(HighlightSpan(range: NSRange(location: a, length: b - a), kind: k)) } }
        func starts(_ s: String, at p: Int) -> Bool {
            let t = Array(s.utf16)
            guard p + t.count <= n else { return false }
            for k in 0..<t.count where u[p + k] != t[k] { return false }
            return true
        }
        func nameChar(_ c: UInt16) -> Bool { SyntaxHighlighter.isIdentPart(c) || c == 0x2D || c == 0x3A || c == 0x2E }

        while i < n {
            guard u[i] == 0x3C else { i += 1; continue }
            if starts("<!--", at: i) {
                var j = i + 4
                while j < n, !starts("-->", at: j) { j += 1 }
                let e = min(n, j + 3)
                add(i, e, .comment); i = e; continue
            }
            if starts("<![CDATA[", at: i) {
                var j = i + 9
                while j < n, !starts("]]>", at: j) { j += 1 }
                let e = min(n, j + 3)
                add(i, e, .string); i = e; continue
            }
            var j = i + 1
            if j < n, u[j] == 0x2F || u[j] == 0x3F || u[j] == 0x21 { j += 1 }
            guard j < n, SyntaxHighlighter.isIdentStart(u[j]) else { i += 1; continue }
            let nameStart = i + 1
            while j < n, nameChar(u[j]) { j += 1 }
            add(nameStart, j, u[nameStart] == 0x21 ? .keyword : .tag)
            // attributes until '>'
            while j < n, u[j] != 0x3E {
                let c = u[j]
                if c == 0x22 || c == 0x27 {
                    var k = j + 1
                    while k < n, u[k] != c { k += 1 }
                    let e = min(n, k + 1)
                    add(j, e, .string); j = e
                } else if SyntaxHighlighter.isIdentStart(c) {
                    var k = j
                    while k < n, nameChar(u[k]) { k += 1 }
                    add(j, k, .attribute); j = k
                } else if c == 0x3C {
                    break      // unterminated tag: let the outer loop restart at the next '<'
                } else { j += 1 }
            }
            i = j
        }
        return out
    }

    static func scanDiff(_ u: [UInt16]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        let n = u.count
        var i = 0
        while i < n {
            var e = i
            while e < n, u[e] != 0x0A { e += 1 }
            let c = u[i]
            let second: UInt16 = i + 1 < e ? u[i + 1] : 0
            var kind: TokenKind?
            if c == 0x2B { kind = second == 0x2B ? .keyword : .added }
            else if c == 0x2D { kind = second == 0x2D ? .keyword : .removed }
            else if c == 0x40 && second == 0x40 { kind = .tag }
            else if c == 0x64 || c == 0x69 { kind = .attribute }      // "diff --git", "index …"
            if let kind, e > i { out.append(HighlightSpan(range: NSRange(location: i, length: e - i), kind: kind)) }
            i = e + 1
        }
        return out
    }
}
