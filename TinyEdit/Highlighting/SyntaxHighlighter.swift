import Foundation

enum TokenKind: Sendable {
    case string, number, keyword, comment, boolean, null, heading, code
    case key, tag, attribute, preprocessor, added, removed
    /// Markdown task list: an open item's `[ ]`, and a done item from its marker to the line end.
    case taskBox, taskDone
}

struct HighlightSpan: Sendable, Equatable {
    var range: NSRange
    var kind: TokenKind
}

enum HighlightPolicy {
    static let fullLimit = 2_000_000
    /// Up to this many UTF-16 units a keystroke is recolored at once: scanning takes about a millisecond, and
    /// 200 ms later is long enough to see a typed quote or comment marker change the line's colors late.
    static let promptLimit = 256_000
    static let offLimit = 5_000_000
}

/// Pure scanners. No AppKit.
enum SyntaxHighlighter {
    /// `limit` is a UTF-16 range expanded to line boundaries by the caller; nil scans the whole text.
    static func spans(language: EditorLanguage, text: String, limit: NSRange?) -> [HighlightSpan] {
        let all = Array(text.utf16)
        let lo = max(0, min(limit?.location ?? 0, all.count))
        let hi = max(lo, min(lo + (limit?.length ?? all.count), all.count))
        let slice = Array(all[lo..<hi])
        let local: [HighlightSpan]
        switch language {
        case .plain: return []
        case .json: local = JSONHighlighter.scan(slice)
        case .python: local = PythonHighlighter.scan(slice)
        case .markdown: local = MarkdownHighlighter.scan(slice)
        case .html, .xml: local = MarkupHighlighter.scan(slice)
        case .diff: local = MarkupHighlighter.scanDiff(slice)
        default: local = GenericHighlighter.scan(slice, syntax: LanguageSyntax.table[language] ?? LanguageSyntax())
        }
        return local.map { HighlightSpan(range: NSRange(location: $0.range.location + lo, length: $0.range.length), kind: $0.kind) }
    }

    static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
}
