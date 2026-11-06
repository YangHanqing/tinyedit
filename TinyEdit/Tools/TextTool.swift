import Foundation

/// A Tools submenu, and the category shown beside a tool in the command palette.
enum TextToolGroup: CaseIterable, Sendable {
    case json, encoding, lines, textCase, cleanup

    var title: String {
        switch self {
        case .json: "JSON"
        case .encoding: String(localized: "Encode & Decode")
        case .lines: String(localized: "Lines")
        case .textCase: String(localized: "Change Case")
        case .cleanup: String(localized: "Clean Up")
        }
    }

    var tools: [TextTool] { TextTool.allCases.filter { $0.group == self } }
}

/// The text tools offered by the command palette and the Tools menu, in display order.
/// Each one reads the selection (or the whole tab) and replaces it; undo restores the input.
enum TextTool: String, CaseIterable, Identifiable, Sendable {
    case formatJSON, minifyJSON, unescapeJSONString, escapeJSONString
    case base64Decode, base64Encode, urlDecode, urlEncode, unescapeUnicode
    case decodeJWT, timestampToDate
    case sortLinesAscending, sortLinesDescending, reverseLines, shuffleLines, removeDuplicateLines
    case uppercase, lowercase, titleCase, camelCase, pascalCase, snakeCase, constantCase, kebabCase
    case removeBlankLines, trimTrailingWhitespace, removeANSIEscapes, removeInvisibleCharacters

    var id: String { rawValue }

    /// English source. The palette matches this even when `title` is translated.
    var englishTitle: String {
        switch self {
        case .formatJSON: "Format JSON"
        case .minifyJSON: "Minify JSON"
        case .unescapeJSONString: "Unescape JSON String"
        case .escapeJSONString: "Escape as JSON String"
        case .base64Decode: "Base64 Decode"
        case .base64Encode: "Base64 Encode"
        case .urlDecode: "URL Decode"
        case .urlEncode: "URL Encode"
        case .unescapeUnicode: "Unescape Unicode (\\uXXXX)"
        case .decodeJWT: "Decode JWT"
        case .timestampToDate: "Unix Timestamp to Date"
        case .sortLinesAscending: "Sort Lines Ascending"
        case .sortLinesDescending: "Sort Lines Descending"
        case .reverseLines: "Reverse Lines"
        case .shuffleLines: "Shuffle Lines"
        case .removeDuplicateLines: "Remove Duplicate Lines"
        case .removeBlankLines: "Remove Blank Lines"
        case .trimTrailingWhitespace: "Trim Trailing Whitespace"
        case .removeANSIEscapes: "Remove ANSI Escape Codes"
        case .removeInvisibleCharacters: "Remove Invisible Characters"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .camelCase: "camelCase"
        case .pascalCase: "PascalCase"
        case .snakeCase: "snake_case"
        case .constantCase: "CONSTANT_CASE"
        case .kebabCase: "kebab-case"
        }
    }

    var title: String {
        switch self {
        case .formatJSON: String(localized: "Format JSON")
        case .minifyJSON: String(localized: "Minify JSON")
        case .unescapeJSONString: String(localized: "Unescape JSON String")
        case .escapeJSONString: String(localized: "Escape as JSON String")
        case .base64Decode: String(localized: "Base64 Decode")
        case .base64Encode: String(localized: "Base64 Encode")
        case .urlDecode: String(localized: "URL Decode")
        case .urlEncode: String(localized: "URL Encode")
        case .unescapeUnicode: String(localized: "Unescape Unicode (\\uXXXX)")
        case .decodeJWT: String(localized: "Decode JWT")
        case .timestampToDate: String(localized: "Unix Timestamp to Date")
        case .sortLinesAscending: String(localized: "Sort Lines Ascending")
        case .sortLinesDescending: String(localized: "Sort Lines Descending")
        case .reverseLines: String(localized: "Reverse Lines")
        case .shuffleLines: String(localized: "Shuffle Lines")
        case .removeDuplicateLines: String(localized: "Remove Duplicate Lines")
        case .removeBlankLines: String(localized: "Remove Blank Lines")
        case .trimTrailingWhitespace: String(localized: "Trim Trailing Whitespace")
        case .removeANSIEscapes: String(localized: "Remove ANSI Escape Codes")
        case .removeInvisibleCharacters: String(localized: "Remove Invisible Characters")
        case .uppercase: String(localized: "UPPERCASE")
        case .lowercase: String(localized: "lowercase")
        case .titleCase: String(localized: "Title Case")
        case .camelCase, .pascalCase, .snakeCase, .constantCase, .kebabCase: englishTitle
        }
    }

    /// Extra words the palette matches besides the title.
    var keywords: String {
        switch self {
        case .formatJSON: "pretty beautify indent"
        case .minifyJSON: "compact compress"
        case .unescapeJSONString: "stringified quotes backslash"
        case .escapeJSONString: "stringify quote backslash"
        case .base64Decode, .base64Encode: "b64"
        case .urlDecode, .urlEncode: "percent query"
        case .unescapeUnicode: "escape chinese"
        case .decodeJWT: "token bearer jws"
        case .timestampToDate: "epoch time seconds milliseconds"
        case .sortLinesAscending, .sortLinesDescending: "order alphabetical natural"
        case .reverseLines: "flip invert order"
        case .shuffleLines: "random randomize"
        case .removeDuplicateLines: "unique dedupe deduplicate uniq"
        case .removeBlankLines: "empty delete clean"
        case .trimTrailingWhitespace: "spaces strip end clean"
        case .removeANSIEscapes: "color colour terminal escape sequences strip clean"
        case .removeInvisibleCharacters: "zero width hidden unicode bidi control strip clean"
        case .uppercase: "upper capital caps"
        case .lowercase: "lower small"
        case .titleCase: "capitalize words headline"
        case .camelCase: "identifier variable lower camel"
        case .pascalCase: "identifier type upper camel"
        case .snakeCase: "identifier underscore python"
        case .constantCase: "identifier underscore screaming upper constant"
        case .kebabCase: "identifier dash hyphen slug css"
        }
    }

    var group: TextToolGroup {
        switch self {
        case .formatJSON, .minifyJSON, .unescapeJSONString, .escapeJSONString: .json
        case .base64Decode, .base64Encode, .urlDecode, .urlEncode, .unescapeUnicode,
             .decodeJWT, .timestampToDate: .encoding
        case .sortLinesAscending, .sortLinesDescending, .reverseLines, .shuffleLines, .removeDuplicateLines: .lines
        case .uppercase, .lowercase, .titleCase, .camelCase, .pascalCase, .snakeCase, .constantCase, .kebabCase: .textCase
        case .removeBlankLines, .trimTrailingWhitespace, .removeANSIEscapes, .removeInvisibleCharacters: .cleanup
        }
    }

    /// Within a submenu, a divider goes before a tool that starts a new run of related tools.
    var startsSubsection: Bool {
        switch self {
        case .decodeJWT, .reverseLines, .removeDuplicateLines, .camelCase, .removeANSIEscapes: true
        default: false
        }
    }

    /// Works on whole lines: the selection is widened to the lines it touches instead of being trimmed.
    var isLineTool: Bool {
        switch self {
        case .sortLinesAscending, .sortLinesDescending, .reverseLines, .shuffleLines, .removeDuplicateLines,
             .removeBlankLines, .trimTrailingWhitespace: true
        default: false
        }
    }
}

struct TextToolError: Error, Equatable {
    var message: String
}

/// Pure string transforms for every tool except Format / Minify JSON, which keep their own
/// selection and error-position rules in `JSONFormatter`. Input is already trimmed by the caller.
enum TextTransform {
    static func apply(_ tool: TextTool, to s: String, timeZone: TimeZone = .current) throws -> String {
        switch tool {
        case .formatJSON, .minifyJSON:
            preconditionFailure("JSON format and minify run through JSONFormatter")
        case .unescapeJSONString: return try unescapeJSONString(s)
        case .escapeJSONString: return try escapeJSONString(s)
        case .base64Decode: return try utf8(base64Data(s), else: "Decoded Base64 is not UTF-8 text")
        case .base64Encode: return Data(s.utf8).base64EncodedString()
        case .urlDecode:
            guard let out = s.removingPercentEncoding else { throw TextToolError(message: "Invalid percent-encoding") }
            return out
        case .urlEncode: return s.addingPercentEncoding(withAllowedCharacters: urlUnreserved) ?? s
        case .unescapeUnicode: return unescapeUnicode(s)
        case .decodeJWT: return try decodeJWT(s)
        case .timestampToDate: return try timestampToDate(s, timeZone: timeZone)
        case .sortLinesAscending: return lines(s) { $0.sorted(by: naturalOrder) }
        case .sortLinesDescending: return lines(s) { $0.sorted(by: naturalOrder).reversed() }
        case .reverseLines: return lines(s) { $0.reversed() }
        case .shuffleLines: return lines(s) { $0.shuffled() }
        case .removeDuplicateLines:
            return lines(s) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        case .removeBlankLines:
            return lines(s) { $0.filter { !$0.allSatisfy(\.isWhitespace) } }
        case .trimTrailingWhitespace:
            return lines(s) { $0.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) } }
        case .removeANSIEscapes: return TextCleanup.removingANSI(s)
        case .removeInvisibleCharacters: return TextCleanup.removingInvisible(s)
        case .uppercase: return s.uppercased()
        case .lowercase: return s.lowercased()
        case .titleCase: return s.capitalized
        case .camelCase: return identifiers(s) { w in w.enumerated().map { $0 == 0 ? $1.lowercased() : $1.capitalized }.joined() }
        case .pascalCase: return identifiers(s) { $0.map(\.capitalized).joined() }
        case .snakeCase: return identifiers(s) { $0.map { $0.lowercased() }.joined(separator: "_") }
        case .constantCase: return identifiers(s) { $0.map { $0.uppercased() }.joined(separator: "_") }
        case .kebabCase: return identifiers(s) { $0.map { $0.lowercased() }.joined(separator: "-") }
        }
    }

    // MARK: Case

    /// Each line's words joined by `join`, keeping the line's leading and trailing blanks. Words are runs of
    /// letters and digits, split at `_`, `-`, spaces and other punctuation, at a lowercase-to-uppercase step
    /// (`userName`) and before the last capital of an acronym (`HTTPServer` is `HTTP`, `Server`).
    private static func identifiers(_ s: String, _ join: ([String]) -> String) -> String {
        s.components(separatedBy: "\n").map { line in
            let words = words(line)
            guard !words.isEmpty else { return line }
            let lead = line.prefix(while: { $0 == " " || $0 == "\t" })
            let trail = String(line.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            return lead + join(words) + trail
        }.joined(separator: "\n")
    }

    static func words(_ s: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        let chars = Array(s)
        func flush() { if !current.isEmpty { words.append(String(current)); current = [] } }
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); continue }
            if let p = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if c.isUppercase, p.isLowercase || p.isNumber { flush() }
                else if c.isUppercase, p.isUppercase, next?.isLowercase == true { flush() }
            }
            current.append(c)
        }
        flush()
        return words
    }

    // MARK: Lines

    /// The lines `range` touches, each with its line break. A selection that ends at the start of a
    /// line, as whole-line selections do, does not take that line.
    static func lineRange(covering range: NSRange, in text: NSString) -> NSRange {
        var r = range
        if r.length > 0, text.character(at: NSMaxRange(r) - 1) == 0x0A { r.length -= 1 }
        return text.lineRange(for: r)
    }

    /// `range` without the spaces, tabs and line breaks at its ends: what a tool that is not a line tool reads.
    static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        func isSpace(_ i: Int) -> Bool { [0x20, 0x09, 0x0A].contains(text.character(at: i)) }
        var r = range
        while r.length > 0, isSpace(r.location) { r.location += 1; r.length -= 1 }
        while r.length > 0, isSpace(NSMaxRange(r) - 1) { r.length -= 1 }
        return r
    }

    /// Applies `transform` to the lines of `s`. One final line break belongs to the last line, not
    /// to an empty line after it, so it stays at the end instead of being sorted or dropped.
    private static func lines(_ s: String, _ transform: ([String]) -> [String]) -> String {
        let finalBreak = s.hasSuffix("\n")
        let body = finalBreak ? String(s.dropLast()) : s
        let out = transform(body.components(separatedBy: "\n")).joined(separator: "\n")
        return finalBreak ? out + "\n" : out
    }

    /// Finder order (case-insensitive, numbers by value, the user's locale), then code point order so
    /// that lines differing only in case still sort the same way every time.
    private static func naturalOrder(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }

    // MARK: JSON strings

    /// Accepts `"a\"b"` or the bare inside `a\"b`, as copied out of a log line.
    private static func unescapeJSONString(_ s: String) throws -> String {
        let quoted = s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 ? s : "\"\(s)\""
        guard let value = try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: [.fragmentsAllowed]) as? String else {
            throw TextToolError(message: "Not a valid JSON string")
        }
        return value
    }

    private static func escapeJSONString(_ s: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Base64 and URL

    /// Standard or URL-safe alphabet, padding optional, line breaks ignored.
    private static func base64Data(_ s: String) throws -> Data {
        var t = String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        t = t.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
        guard let data = Data(base64Encoded: t) else { throw TextToolError(message: "Invalid Base64") }
        return data
    }

    private static func utf8(_ data: Data, else message: String) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else { throw TextToolError(message: message) }
        return s
    }

    /// RFC 3986 unreserved characters. `CharacterSet.alphanumerics` would also pass non-ASCII letters.
    private static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Unicode escapes

    /// `\uXXXX` to the character, surrogate pairs included; everything else is left as written.
    private static func unescapeUnicode(_ s: String) -> String {
        let u = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == 0x5C, i + 1 < u.count, u[i + 1] == 0x75, let v = hex4(u, i + 2) {
                out.append(v); i += 6
            } else {
                out.append(u[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func hex4(_ u: [UInt16], _ at: Int) -> UInt16? {
        guard at + 4 <= u.count else { return nil }
        var v: UInt16 = 0
        for k in at..<(at + 4) {
            let c = u[k]
            let d: UInt16
            switch c {
            case 0x30...0x39: d = c - 0x30
            case 0x41...0x46: d = c - 0x41 + 10
            case 0x61...0x66: d = c - 0x61 + 10
            default: return nil
            }
            v = v << 4 | d
        }
        return v
    }

    // MARK: JWT

    /// Header and payload as one formatted JSON object. The signature is not verified.
    private static func decodeJWT(_ s: String) throws -> String {
        var token = s
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let invalid = TextToolError(message: "Not a JWT")
        guard parts.count == 3 || parts.count == 2 else { throw invalid }
        func json(_ part: Substring) throws -> String {
            guard let data = try? base64Data(String(part)),
                  let text = String(data: data, encoding: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { throw invalid }
            return text
        }
        let combined = "{\"header\":\(try json(parts[0])),\"payload\":\(try json(parts[1]))}"
        switch JSONFormatter.format(text: combined, selection: nil) {
        case .formatted(let out, _): return out
        case .unchanged: return combined
        case .invalid: throw invalid
        }
    }

    // MARK: Timestamps

    /// Seconds, milliseconds, microseconds or nanoseconds, told apart by magnitude.
    private static func timestampToDate(_ s: String, timeZone: TimeZone) throws -> String {
        guard s.count <= 20, let n = Int64(s) else { throw TextToolError(message: "Not a Unix timestamp") }
        let magnitude = n.magnitude
        let divisor: Double = magnitude < 100_000_000_000 ? 1
            : magnitude < 100_000_000_000_000 ? 1_000
            : magnitude < 100_000_000_000_000_000 ? 1_000_000 : 1_000_000_000
        let seconds = Double(n) / divisor
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = divisor == 1 ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}
