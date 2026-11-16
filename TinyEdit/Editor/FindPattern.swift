import Foundation

/// Regular-expression find, shared by the editor and large files: `^` and `$` match at line breaks, and a
/// match of nothing (`^`, `a*`) is not a match, so Next always moves and counts mean something.
enum FindPattern {
    nonisolated static func regex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
    }

    nonisolated static func matches(_ regex: NSRegularExpression, in text: NSString, range: NSRange? = nil,
                                    limit: Int = .max) -> [NSTextCheckingResult] {
        var out: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: text as String, options: [], range: range ?? NSRange(location: 0, length: text.length)) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            out.append(m)
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    nonisolated static func ranges(_ regex: NSRegularExpression, in text: NSString) -> [NSRange] {
        matches(regex, in: text).map(\.range)
    }

    /// `text` with the matches at `ranges` replaced by the template (`$1`; `\$` for a dollar sign).
    nonisolated static func replacing(_ regex: NSRegularExpression, in text: NSString, ranges: [NSRange],
                                      template: String) -> String {
        let out = NSMutableString(string: text)
        for r in ranges.reversed() {
            guard let m = regex.firstMatch(in: text as String, options: [], range: r), m.range == r else { continue }
            out.replaceCharacters(in: r, with: regex.replacementString(for: m, in: text as String, offset: 0, template: template))
        }
        return out as String
    }
}

enum FindMatches {
    /// Counting stops here; the card then shows "9999+".
    static let limit = 9_999

    /// Every non-overlapping match, in document order.
    nonisolated static func ranges(of query: String, in text: NSString, caseSensitive: Bool, regex: Bool = false,
                                   limit: Int = limit) -> (ranges: [NSRange], capped: Bool) {
        guard !query.isEmpty else { return ([], false) }
        if regex {
            guard let re = FindPattern.regex(query, caseSensitive: caseSensitive) else { return ([], false) }
            let found = FindPattern.matches(re, in: text, limit: limit + 1).map(\.range)
            return (Array(found.prefix(limit)), found.count > limit)
        }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var ranges: [NSRange] = []
        var from = 0
        while from < text.length {
            let r = text.range(of: query, options: options, range: NSRange(location: from, length: text.length - from))
            if r.location == NSNotFound { break }
            if ranges.count == limit { return (ranges, true) }
            ranges.append(r)
            from = NSMaxRange(r)
        }
        return (ranges, false)
    }

    /// Index of the match equal to `selection`, by binary search over the sorted ranges.
    static func index(of selection: NSRange, in ranges: [NSRange]) -> Int? {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location < selection.location { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo] == selection ? lo : nil
    }

    /// The first match at or after `location`, wrapping to the first one.
    static func firstIndex(atOrAfter location: Int, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.firstIndex { $0.location >= location } ?? 0
    }
}
