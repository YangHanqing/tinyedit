import Foundation

enum PasteDecodeKind: Hashable, Sendable {
    case jwt
    case jsonString
    case base64
    case url
    case unicodeEscape
    case timestamp
}

struct PasteDecodeCandidate: Equatable, Sendable, Identifiable {
    var kind: PasteDecodeKind
    var decoded: String
    /// The decode is a JSON object or array, pretty-printed. Replace also switches the tab to JSON.
    var isJSON = false
    var id: PasteDecodeKind { kind }
}

/// Escape codes or invisible characters a paste brought in (`TextCleanup`).
struct PasteCleanup: Equatable, Sendable {
    var report: TextCleanup.Report
    /// The pasted text. Still where it was while the card shows: the next edit hides the card.
    var range: NSRange
    /// The paste filled the tab, so the usual offer (language, decodes) is made once they are removed.
    var fillsTab: Bool
}

/// A pasted curl command the card offers to send.
struct CurlOffer: Equatable, Sendable {
    var command: CurlCommand
    var summary: CurlSummary
    /// The text the command was parsed from: the pasted text, or the whole tab.
    var range: NSRange

    init(_ command: CurlCommand, range: NSRange) {
        self.command = command
        summary = CurlSummary(command)
        self.range = range
    }
}

/// What the suggestion card offers after a paste. Not stored in the session manifest.
struct PasteSuggestion: Equatable, Sendable {
    /// When set, the card offers only to remove these; the other fields are empty.
    var cleanup: PasteCleanup?
    /// When set, the card offers only to send it; the other fields are empty.
    var curl: CurlOffer?
    var candidates: [PasteDecodeCandidate] = []
    /// What the pasted text looks like. Never the tab's language at detection time.
    var language: EditorLanguage?
    /// The text is JSON that Format JSON would change.
    var canFormatJSON = false
    /// The pasted line the candidates were read from, without surrounding whitespace; Replace swaps it.
    /// Still where it was while the card shows: the next edit hides the card.
    var decodeRange: NSRange?

    var isEmpty: Bool { cleanup == nil && curl == nil && candidates.isEmpty && language == nil && !canFormatJSON }
}

/// Local checks for pasted text. Nothing is uploaded. Language and Format JSON are offered only for a
/// paste that left the tab holding only the pasted text; decodes for any one-line paste. Each reading runs
/// the same transform as its Tools menu entry, after a cheap shape check, and is offered only when that
/// transform succeeds with a useful result. A line may match more than one reading.
enum PasteDecodeDetector {
    static let maxBytes = 1_048_576
    private static let minimumBase64Length = 8
    /// 2000-01-01 ..< 2100-01-01 UTC. Any 10-digit number parses as seconds; only plausible dates are offered.
    private static let timestampRange: ClosedRange<Int64> = 946_684_800...4_102_444_799

    /// `nil` when the text is empty, too large, or matches nothing.
    static func suggestion(in document: String, currentLanguage: EditorLanguage,
                           timeZone: TimeZone = .current) -> PasteSuggestion? {
        guard document.utf8.count <= maxBytes else { return nil }
        var result = decodeSuggestion(in: document, at: 0, timeZone: timeZone) ?? PasteSuggestion()
        let complete = document.utf16.count <= ContentLanguageDetector.sampleLimit
        if let detected = ContentLanguageDetector.detect(document, isComplete: complete) {
            if detected == .json, case .formatted = JSONFormatter.format(text: document, selection: nil) {
                result.canFormatJSON = true
            }
            if detected != currentLanguage { result.language = detected }
        }
        return result.isEmpty ? nil : result
    }

    /// Decode readings only, for text pasted at `location` (UTF-16) among other text.
    static func decodeSuggestion(in pasted: String, at location: Int,
                                 timeZone: TimeZone = .current) -> PasteSuggestion? {
        guard let found = candidates(in: pasted, timeZone: timeZone),
              let range = contentRange(in: pasted as NSString) else { return nil }
        return PasteSuggestion(candidates: found, decodeRange: NSRange(location: location + range.location, length: range.length))
    }

    /// Decode readings of the text's single content line, most specific first. Surrounding whitespace is ignored.
    static func candidates(in document: String, timeZone: TimeZone = .current) -> [PasteDecodeCandidate]? {
        guard document.utf8.count <= maxBytes, let line = contentLine(document) else { return nil }
        var found: [PasteDecodeCandidate] = []
        func add(_ kind: PasteDecodeKind, _ decoded: String?) {
            guard let decoded else { return }
            found.append(prettyJSON(decoded).map { PasteDecodeCandidate(kind: kind, decoded: $0, isJSON: true) }
                         ?? PasteDecodeCandidate(kind: kind, decoded: LineEnding.normalizeToLF(decoded)))
        }
        add(.jwt, jwtText(line))
        let jsonString = jsonStringText(line)
        add(.jsonString, jsonString)
        add(.base64, base64Text(line))
        add(.url, urlText(line))
        if jsonString == nil { add(.unicodeEscape, unicodeEscapeText(line)) }
        if let date = timestampText(line, timeZone: timeZone) {
            found.append(PasteDecodeCandidate(kind: .timestamp, decoded: date))
        }
        return found.isEmpty ? nil : found
    }

    /// The text without surrounding whitespace, when that is one line.
    static func contentRange(in text: NSString) -> NSRange? {
        var lo = 0, hi = text.length
        func isSpace(_ i: Int) -> Bool { [0x20, 0x09, 0x0A].contains(text.character(at: i)) }
        while lo < hi, isSpace(lo) { lo += 1 }
        while hi > lo, isSpace(hi - 1) { hi -= 1 }
        let range = NSRange(location: lo, length: hi - lo)
        guard range.length > 0, text.rangeOfCharacter(from: .newlines, range: range).location == NSNotFound else { return nil }
        return range
    }

    private static func contentLine(_ document: String) -> String? {
        let ns = document as NSString
        return contentRange(in: ns).map { ns.substring(with: $0) }
    }

    /// A JSON object or array, pretty-printed with key order kept. Scalars stay as they are.
    private static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        switch JSONFormatter.format(text: trimmed, selection: nil) {
        case .formatted(let out, _): return out
        case .unchanged: return trimmed
        case .invalid: return nil
        }
    }

    // MARK: Readings

    /// `header.payload[.signature]` in base64url, optionally after `Bearer `; header and payload must be JSON.
    private static func jwtText(_ line: String) -> String? {
        var token = Substring(line)
        if token.lowercased().hasPrefix("bearer ") { token = token.dropFirst(7).drop { $0 == " " } }
        guard token.contains("."),
              token.utf8.allSatisfy({ isBase64URL($0) || $0 == UInt8(ascii: ".") }) else { return nil }
        return try? TextTransform.apply(.decodeJWT, to: line)
    }

    /// A string copied out of JSON or a log line: quoted with an escape inside, or carrying `\"`.
    /// A bare backslash (a Windows path, a regex) is not enough.
    private static func jsonStringText(_ line: String) -> String? {
        guard line.contains("\\") else { return nil }
        let quoted = line.count >= 2 && line.hasPrefix("\"") && line.hasSuffix("\"")
        guard quoted || line.contains("\\\"") else { return nil }
        guard let decoded = try? TextTransform.apply(.unescapeJSONString, to: line),
              decoded != line, isReadable(decoded) else { return nil }
        return decoded
    }

    /// Standard (`+/`, `=` padding) or base64url (`-_`, padding optional). The decode has to be
    /// readable UTF-8. All-digit strings are rejected even when that decode is readable: digits are
    /// in the alphabet, so the readable-text check does not filter them.
    private static func base64Text(_ line: String) -> String? {
        let bytes = Array(line.utf8)
        guard bytes.count >= minimumBase64Length else { return nil }
        var digitOnly = true
        var standard = false
        var url = false
        var padding = 0
        for byte in bytes {
            if padding > 0 {
                guard byte == UInt8(ascii: "=") else { return nil }
                padding += 1
                continue
            }
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                break
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
                digitOnly = false
            case UInt8(ascii: "+"), UInt8(ascii: "/"):
                digitOnly = false
                standard = true
            case UInt8(ascii: "-"), UInt8(ascii: "_"):
                digitOnly = false
                url = true
            case UInt8(ascii: "="):
                digitOnly = false
                padding = 1
            default:
                return nil
            }
        }
        if digitOnly || (standard && url) { return nil }
        if padding > 0 {
            guard padding == 1 || padding == 2, bytes.count.isMultiple(of: 4) else { return nil }
        } else if bytes.count % 4 == 1 {
            return nil
        }
        guard let decoded = try? TextTransform.apply(.base64Decode, to: line), isReadable(decoded) else { return nil }
        return decoded
    }

    /// A bare `+` is not percent-encoding, and a URL with no `%XX` is not either.
    private static func urlText(_ line: String) -> String? {
        guard hasPercentEncodedByte(line) else { return nil }
        guard let decoded = try? TextTransform.apply(.urlDecode, to: line), decoded != line else { return nil }
        return decoded
    }

    /// `\uXXXX` outside a JSON string, as printed by Java, JavaScript and Python logs.
    private static func unicodeEscapeText(_ line: String) -> String? {
        guard line.contains("\\u"), let decoded = try? TextTransform.apply(.unescapeUnicode, to: line),
              decoded != line, isReadable(decoded) else { return nil }
        return decoded
    }

    /// 10 digits as seconds or 13 as milliseconds, within `timestampRange`.
    private static func timestampText(_ line: String, timeZone: TimeZone) -> String? {
        guard line.count == 10 || line.count == 13, line.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let n = Int64(line), timestampRange.contains(line.count == 13 ? n / 1000 : n) else { return nil }
        return try? TextTransform.apply(.timestampToDate, to: line, timeZone: timeZone)
    }

    // MARK: Character checks

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    private static func hasPercentEncodedByte(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), isHex(bytes[index + 1]), isHex(bytes[index + 2]) { return true }
            index += 1
        }
        return false
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "F"),
             UInt8(ascii: "a")...UInt8(ascii: "f"):
            return true
        default:
            return false
        }
    }

    /// Control characters other than tab and the line breaks are not "readable text".
    private static func isReadable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control {
            if scalar != "\t" && scalar != "\n" && scalar != "\r" { return false }
        }
        return true
    }
}
