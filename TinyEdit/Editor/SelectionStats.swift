import Foundation

/// Counts for the status bar while text is selected. Several selected ranges add up.
struct SelectionStats: Equatable, Sendable {
    /// User-perceived characters (grapheme clusters): an emoji family or an accented letter is one.
    /// Spaces and line breaks count.
    var characters = 0
    /// Words as word processors count them: a space-separated language by its words (found by the
    /// system's word breaker, which also splits Thai and similar scripts), Chinese and Japanese by
    /// each ideograph or kana. Punctuation and emoji are not words.
    var words = 0
    /// Lines touched. A range ending at the start of a line does not touch it.
    var lines = 0
    var utf8Bytes = 0
    /// The numbers' total when the selection is nothing but two or more numbers, as a selected column is.
    var numbers: NumberSum?

    /// Larger selections are counted off the main thread.
    static let synchronousLimit = 20_000

    init(characters: Int = 0, words: Int = 0, lines: Int = 0, utf8Bytes: Int = 0) {
        self.characters = characters
        self.words = words
        self.lines = lines
        self.utf8Bytes = utf8Bytes
    }

    init(_ pieces: [String]) {
        for piece in pieces where !piece.isEmpty {
            characters += piece.count
            utf8Bytes += piece.utf8.count
            words += Self.wordCount(piece)
            var breaks = piece.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if piece.utf8.last == 0x0A { breaks -= 1 }
            lines += breaks + 1
        }
        numbers = NumberSum(pieces)
    }

    static func wordCount(_ s: String) -> Int {
        var count = 0
        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { word, _, _, _ in
            guard let word else { return }
            var ideographs = 0
            var other = false
            for scalar in word.unicodeScalars {
                if isIdeographOrKana(scalar) {
                    ideographs += 1
                } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    other = true
                }
            }
            count += ideographs == 0 ? 1 : ideographs + (other ? 1 : 0)
        }
        return count
    }

    /// Hangul is not here: Korean separates words with spaces.
    private static func isIdeographOrKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true   // hiragana, katakana, half-width katakana
        default: s.properties.isIdeographic
        }
    }
}

/// The sum of a selection made only of numbers: separated by blanks, line breaks, `,` `;` `|`, with an
/// optional sign, decimals, `1,234` grouping, a currency symbol before or a `%` after. Any other word
/// means the selection is not a list of numbers, so the status bar shows no sum. Exact decimal arithmetic.
struct NumberSum: Equatable, Sendable {
    var count: Int
    var sum: Decimal

    var average: Decimal { sum / Decimal(count) }

    /// `1234.5`, for the pasteboard.
    var plainSum: String { NSDecimalNumber(decimal: sum).stringValue }

    init?(_ pieces: [String]) {
        var count = 0
        var sum = Decimal(0)
        for piece in pieces {
            for token in piece.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" }) {
                if let value = Self.number(token) {
                    sum += value; count += 1
                    continue
                }
                // `1,2,3`: commas that are not grouping separate numbers.
                for part in token.split(separator: ",") {
                    guard let value = Self.number(part) else { return nil }
                    sum += value; count += 1
                }
            }
        }
        guard count >= 2 else { return nil }
        self.count = count
        self.sum = sum
    }

    private static let currency: Set<Character> = ["$", "¥", "€", "£", "₩", "₹"]

    /// A trailing `,` (a list) and one `%` or leading currency symbol are allowed around the number.
    static func number(_ token: Substring) -> Decimal? {
        var t = token
        if t.last == "," { t = t.dropLast() }
        if t.last == "%" { t = t.dropLast() }
        var negative = false
        if let c = t.first, c == "-" || c == "+" || c == "\u{2212}" { negative = c != "+"; t = t.dropFirst() }
        if let c = t.first, currency.contains(c) { t = t.dropFirst() }
        guard let first = t.first, first.isASCII, first.isNumber else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let integer = parts[0]
        if parts.count == 2 { guard !parts[1].isEmpty, parts[1].allSatisfy(isDigit) else { return nil } }
        let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else { return nil }
        if groups.count > 1 {
            guard groups[0].count <= 3, groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let plain = groups.joined() + (parts.count == 2 ? "." + parts[1] : "")
        guard let value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}
