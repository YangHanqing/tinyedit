import Foundation

/// One cursor line, decided synchronously. Nothing here touches the text storage.
///
/// The trimmed line must be one complete expression with at least one operation (a binary operator,
/// a function call, `√` or `!`), optionally ending in `=` or in an already-written result (`=` / `≈`
/// and a number). Fullwidth digits, operators and letters are normalized first. Arithmetic is decimal
/// (Foundation `Decimal` fractions) while it can stay exact, and floating point (marked `≈`) once it cannot.
///
/// Operators: `+ - * / ^` (also `**`), parentheses, postfix `!` (factorial), `%` (divide by 100) and
/// `°` (degrees to radians). Constants: `pi` / `π`, `e`. Functions: `sqrt` (or `√`), `cbrt`, `root(x, n)`,
/// `pow`, `abs`, `mod(a, b)` (the divisor's sign), `max`, `min`, `avg`, `round(x[, places])` (half away
/// from zero), `floor`, `ceil`, `log` / `log10`, `log2`, `log(x, base)`, `ln`, `exp`, `sin`, `cos`, `tan`,
/// `asin`, `acos`, `atan` (radians). Settings lists them from `InlineCalculationReference`.
///
/// Not an expression, so no ghost: a bare number or constant, an unknown name or any other character,
/// an unfinished expression, `!=`, a non-finite result, or a domain error (division by zero, `sqrt(-1)`,
/// `ln(0)`, `asin(2)`, `2.5!`).
///
/// Dates and phone numbers are excluded up front, rather than shown as subtraction:
/// - Date: after spaces are removed, a 4-digit year, then `-` or `/`, a 1–2 digit month, the same
///   separator, and a 1–2 digit day (`2024-01-02`, `2024/1/2`, and `2024 - 01 - 02 + 1`).
/// - Phone: an integer token longer than one digit that starts with `0` (`010-12345678`, `010+1`),
///   or a line that is only integers separated by `-` (an optional leading `+`, spaces ignored) in
///   one of these shapes: 3 digits then 4 (`555-1234`); 2–4 digits then 7–8 (`021-12345678`);
///   three or more groups totalling 8 digits or more (`123-456-7890`).
///   `100-20`, `1000-2000` and `1-2-3` stay subtraction.
enum InlineCalculator {
    static let maxLineLength = 200
    static let maxParenDepth = 32
    /// Non-terminating division keeps this many significant digits and is marked `≈`.
    static let significantDigits = 12

    struct Context: Equatable {
        var mode: InlineCalculationMode
        var language: EditorLanguage
    }

    enum Edit: Equatable {
        /// Insert at the end of the line (before the newline). The ghost is this string.
        case append(String)
        /// Replace this UTF-16 range of the line with `text`. The ghost is the `→` hint, not `text`.
        case replace(NSRange, String)
    }

    struct Proposal: Equatable {
        var ghost: String
        var edit: Edit
    }

    /// `nil` when the line must not offer a ghost. `line` does not include the newline.
    static func proposal(forLine line: String) -> Proposal? {
        if line.count > maxLineLength || line.contains(where: \.isNewline) { return nil }
        let units = normalize(line)
        var lo = 0
        var hi = units.count
        while lo < hi, isSpace(units[lo]) { lo += 1 }
        while hi > lo, isSpace(units[hi - 1]) { hi -= 1 }
        if lo == hi || !units[lo..<hi].allSatisfy(isAllowed) { return nil }
        let core = Array(units[lo..<hi])
        if zip(core, core.dropFirst()).contains(where: { $0 == bangChar && $1 == eqChar }) { return nil }
        let trailingSpace = hi < units.count

        if let result = splitResult(core), let value = evaluate(Array(core[0..<result.exprEnd])) {
            guard let formatted = format(value) else { return nil }
            if sameNumber(result.number, formatted.text) { return nil }
            let marker: UInt16 = formatted.approximate ? approxChar : eqChar
            let text = markerText(marker, spaced: result.spaced, number: formatted.text)
            let range = NSRange(location: lo + result.markerIndex, length: units.count - (lo + result.markerIndex))
            return Proposal(ghost: (trailingSpace ? "" : " ") + "→ " + formatted.text, edit: .replace(range, text))
        }
        if let trail = splitTrailingEquals(core), let value = evaluate(Array(core[0..<trail.exprEnd])) {
            guard let formatted = format(value) else { return nil }
            let insert = appendAfterEquals(formatted.text, spaceBeforeEquals: trail.spaceBefore, trailingSpace: trailingSpace)
            return Proposal(ghost: insert, edit: .append(insert))
        }
        if let value = evaluate(core), let formatted = format(value) {
            let marker = formatted.approximate ? "≈" : "="
            let insert = (trailingSpace ? "" : " ") + marker + " " + formatted.text
            return Proposal(ghost: insert, edit: .append(insert))
        }
        return nil
    }

    /// Plain text always, markdown only outside fenced blocks and lines that contain a backtick.
    /// A markdown prefix longer than 256 Ki UTF-16 units is skipped (no ghost) so a keystroke never walks a huge file.
    static func isEligible(_ context: Context, text: NSString, index: Int) -> Bool {
        switch context.mode {
        case .off:
            return false
        case .plainText:
            return context.language == .plain
        case .plainTextAndMarkdown:
            if context.language == .plain { return true }
            if context.language == .markdown { return !markdownBlocks(text, index: index) }
            return false
        }
    }

    // MARK: Adopted lines

    private struct TrailingResult {
        var exprEnd: Int
        var markerIndex: Int
        var spaced: Bool
        var number: String
    }

    /// `expr = number` or `expr ≈ number`, with the number tight against the end of the trimmed line.
    private static func splitResult(_ core: [UInt16]) -> TrailingResult? {
        guard let markerIndex = core.lastIndex(where: { $0 == eqChar || $0 == approxChar }) else { return nil }
        var i = markerIndex + 1
        while i < core.count, isSpace(core[i]) { i += 1 }
        let spaced = i > markerIndex + 1
        guard i < core.count else { return nil }
        let numStart = i
        if core[i] == plusChar || core[i] == minusChar { i += 1 }
        var sawDigit = false
        var sawDot = false
        while i < core.count {
            if isDigit(core[i]) { sawDigit = true; i += 1 }
            else if core[i] == dotChar, !sawDot { sawDot = true; i += 1 }
            else { break }
        }
        if sawDigit, i + 1 < core.count, core[i] == 0x65 || core[i] == 0x45 {
            var j = i + 1
            if core[j] == plusChar || core[j] == minusChar { j += 1 }
            let digitsStart = j
            while j < core.count, isDigit(core[j]) { j += 1 }
            if j > digitsStart { i = j }
        }
        guard sawDigit, i == core.count else { return nil }
        var exprEnd = markerIndex
        while exprEnd > 0, isSpace(core[exprEnd - 1]) { exprEnd -= 1 }
        guard exprEnd > 0 else { return nil }
        let number = decode(core[numStart..<i])
        return TrailingResult(exprEnd: exprEnd, markerIndex: markerIndex, spaced: spaced, number: number)
    }

    /// A trailing `=` with nothing after it. The caller's line may still have spaces after that `=`.
    private static func splitTrailingEquals(_ core: [UInt16]) -> (exprEnd: Int, spaceBefore: Bool)? {
        guard let markerIndex = core.lastIndex(of: eqChar) else { return nil }
        if markerIndex + 1 != core.count { return nil }
        var exprEnd = markerIndex
        while exprEnd > 0, isSpace(core[exprEnd - 1]) { exprEnd -= 1 }
        guard exprEnd > 0 else { return nil }
        return (exprEnd, exprEnd < markerIndex)
    }

    private static func appendAfterEquals(_ number: String, spaceBeforeEquals: Bool, trailingSpace: Bool) -> String {
        if trailingSpace || !spaceBeforeEquals { return number }
        return " " + number
    }

    private static func markerText(_ marker: UInt16, spaced: Bool, number: String) -> String {
        let sign = marker == approxChar ? "≈" : "="
        return spaced ? sign + " " + number : sign + number
    }

    /// Numeric equality, so `2`, `2.0` and `+2` all count as the same adopted result. A result in
    /// scientific notation must be written as shown.
    private static func sameNumber(_ user: String, _ canonical: String) -> Bool {
        if user == canonical || user == "+" + canonical { return true }
        guard let a = signedFraction(user), let b = signedFraction(canonical) else { return false }
        guard let left = mul(a.num, b.den), let right = mul(b.num, a.den) else { return false }
        return left == right
    }

    private static func signedFraction(_ text: String) -> Fraction? {
        let units = Array(text.utf16)
        var i = 0
        var negative = false
        if i < units.count, units[i] == plusChar { i += 1 }
        else if i < units.count, units[i] == minusChar { negative = true; i += 1 }
        guard i < units.count, var value = fraction(units[i..<units.count]) else { return nil }
        if negative {
            guard let n = negDec(value.num) else { return nil }
            value.num = n
        }
        return value.reduced()
    }

    // MARK: Eligibility

    private static let markdownScanLimit = 1 << 18

    private static func markdownBlocks(_ text: NSString, index: Int) -> Bool {
        let safe = min(max(index, 0), text.length)
        let line = text.lineRange(for: NSRange(location: safe, length: 0))
        var contentEnd = NSMaxRange(line)
        if contentEnd > line.location, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        if line.location > markdownScanLimit { return true }
        for i in line.location..<contentEnd where text.character(at: i) == 0x60 { return true }
        if fenceMarker(text, start: line.location, end: contentEnd) != 0 { return true }
        var i = 0
        var fence: unichar = 0
        while i < line.location {
            var end = i
            while end < text.length, text.character(at: end) != 0x0A { end += 1 }
            let marker = fenceMarker(text, start: i, end: end)
            if fence != 0 {
                if marker == fence { fence = 0 }
            } else if marker != 0 {
                fence = marker
            }
            if end >= text.length { break }
            i = end + 1
        }
        return fence != 0
    }

    /// Opening run of a fence, matching `MarkdownHighlighter`: 3+ `` ` `` or `~` after leading whitespace.
    private static func fenceMarker(_ text: NSString, start: Int, end: Int) -> unichar {
        var p = start
        while p < end, text.character(at: p) == 0x20 || text.character(at: p) == 0x09 { p += 1 }
        guard p < end else { return 0 }
        let ch = text.character(at: p)
        guard ch == 0x60 || ch == 0x7E else { return 0 }
        var n = 0
        while p + n < end, text.character(at: p + n) == ch { n += 1 }
        return n >= 3 ? ch : 0
    }

    // MARK: Characters

    private static let plusChar: UInt16 = 0x2B
    private static let minusChar: UInt16 = 0x2D
    private static let starChar: UInt16 = 0x2A
    private static let slashChar: UInt16 = 0x2F
    private static let dotChar: UInt16 = 0x2E
    private static let lParen: UInt16 = 0x28
    private static let rParen: UInt16 = 0x29
    private static let eqChar: UInt16 = 0x3D
    private static let approxChar: UInt16 = 0x2248
    private static let caretChar: UInt16 = 0x5E
    private static let percentChar: UInt16 = 0x25
    private static let bangChar: UInt16 = 0x21
    private static let commaChar: UInt16 = 0x2C
    private static let degreeChar: UInt16 = 0x00B0
    private static let sqrtChar: UInt16 = 0x221A
    private static let piChar: UInt16 = 0x03C0

    private static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    private static func isLetter(_ u: UInt16) -> Bool { (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) }

    private static func isAllowed(_ u: UInt16) -> Bool {
        isSpace(u) || isDigit(u) || u == dotChar || u == plusChar || u == minusChar || u == starChar
            || u == slashChar || u == lParen || u == rParen || u == eqChar || u == approxChar || isLetter(u)
            || u == caretChar || u == percentChar || u == bangChar || u == commaChar || u == degreeChar
            || u == sqrtChar || u == piChar
    }

    /// Fullwidth digits, letters and operators, `×` `÷`, and the unicode minus, mapped 1:1 so indexes still match the line.
    private static func normalize(_ line: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(line.utf16.count)
        for u in line.utf16 {
            switch u {
            case 0xFF10...0xFF19: out.append(u - 0xFF10 + 0x30)
            case 0xFF0B: out.append(plusChar)
            case 0xFF0D, 0x2212: out.append(minusChar)
            case 0xFF08: out.append(lParen)
            case 0xFF09: out.append(rParen)
            case 0xFF0A, 0x00D7: out.append(starChar)
            case 0xFF0F, 0x00F7: out.append(slashChar)
            case 0xFF1D: out.append(eqChar)
            case 0xFF0E: out.append(dotChar)
            case 0xFF0C: out.append(commaChar)
            case 0xFF3E: out.append(caretChar)
            case 0xFF05: out.append(percentChar)
            case 0xFF01: out.append(bangChar)
            case 0xFF21...0xFF3A, 0xFF41...0xFF5A: out.append(u - 0xFF21 + 0x41)
            case 0x3000, 0x00A0: out.append(0x20)
            default: out.append(u)
            }
        }
        return out
    }

    private static func decode(_ units: ArraySlice<UInt16>) -> String {
        String(utf16CodeUnits: Array(units), count: units.count)
    }

    // MARK: Exclusions

    private static func containsDate(_ expr: [UInt16]) -> Bool {
        let compact = expr.filter { !isSpace($0) }
        var i = 0
        while i < compact.count {
            guard isDigit(compact[i]), i == 0 || !isDigit(compact[i - 1]) else { i += 1; continue }
            var end = i
            while end < compact.count, isDigit(compact[end]) { end += 1 }
            if end - i == 4, let sep = separator(compact, end), let month = readDigits(compact, sep.index + 1),
               (1...2).contains(month.count), month.end < compact.count, compact[month.end] == sep.char,
               let day = readDigits(compact, month.end + 1), (1...2).contains(day.count),
               day.end == compact.count || !isDigit(compact[day.end]) {
                return true
            }
            i = end
        }
        return false
    }

    private static func separator(_ u: [UInt16], _ i: Int) -> (char: UInt16, index: Int)? {
        guard i < u.count, u[i] == minusChar || u[i] == slashChar else { return nil }
        return (u[i], i)
    }

    private static func readDigits(_ u: [UInt16], _ start: Int) -> (count: Int, end: Int)? {
        guard start < u.count, isDigit(u[start]) else { return nil }
        var end = start
        while end < u.count, isDigit(u[end]) { end += 1 }
        return (end - start, end)
    }

    private static func isPhone(_ expr: [UInt16]) -> Bool {
        if hasLeadingZeroInteger(expr) { return true }
        var body = expr.filter { !isSpace($0) }
        if body.first == plusChar { body.removeFirst() }
        guard let first = body.first, isDigit(first) else { return false }
        var groups: [Int] = []
        var i = 0
        while i < body.count {
            guard isDigit(body[i]) else { return false }
            let start = i
            while i < body.count, isDigit(body[i]) { i += 1 }
            groups.append(i - start)
            if i == body.count { break }
            guard body[i] == minusChar else { return false }
            i += 1
            if i == body.count { return false }
        }
        guard groups.count >= 2 else { return false }
        if groups.count == 2 {
            let left = groups[0], right = groups[1]
            if left == 3, right == 4 { return true }
            if (2...4).contains(left), (7...8).contains(right) { return true }
            return false
        }
        return groups.reduce(0, +) >= 8
    }

    private static func hasLeadingZeroInteger(_ expr: [UInt16]) -> Bool {
        var i = 0
        while i < expr.count {
            guard isDigit(expr[i]) else { i += 1; continue }
            let start = i
            while i < expr.count, isDigit(expr[i]) { i += 1 }
            let precededByDot = start > 0 && expr[start - 1] == dotChar
            let followedByDot = i < expr.count && expr[i] == dotChar
            if !precededByDot, !followedByDot, i - start > 1, expr[start] == 0x30 { return true }
        }
        return false
    }

    // MARK: Decimal arithmetic

    private struct Fraction {
        var num: Decimal
        var den: Decimal

        func reduced() -> Fraction? { InlineCalculator.reduce(self) }
    }

    private struct Formatted {
        var text: String
        var approximate: Bool
    }

    /// Exact while every step can stay a fraction; floating point once a step cannot (irrational
    /// results, constants, trigonometry) or an exact step would pass 10^38. Floating-point results are marked `≈`.
    private enum Value {
        case exact(Fraction)
        case approx(Double)
    }

    private static func evaluate(_ expr: [UInt16]) -> Value? {
        if expr.isEmpty || containsDate(expr) || isPhone(expr) { return nil }
        var parser = Parser(units: expr)
        guard let value = parser.parseExpression() else { return nil }
        parser.skip()
        guard parser.i == expr.count, parser.operations >= 1, parser.maxDepth <= maxParenDepth else { return nil }
        if case .exact(let f) = value {
            guard let reduced = f.reduced() else { return nil }
            return .exact(reduced)
        }
        return value
    }

    /// Precedence, lowest first: `+ -`, `* /`, unary sign, `^` (right-associative, so `-2^2` is -4 and
    /// `2^3^2` is 512), postfix `!` `%` `°`, then numbers, constants, `(…)`, function calls and `√`.
    /// `operations` counts binary operators, function calls, `√` and `!`; a line needs at least one.
    private struct Parser {
        let units: [UInt16]
        var i = 0
        var operations = 0
        var depth = 0
        var maxDepth = 0

        mutating func skip() {
            while i < units.count, isSpace(units[i]) { i += 1 }
        }

        var current: UInt16? { i < units.count ? units[i] : nil }

        /// `**` is a power, not two multiplications.
        var atDoubleStar: Bool { i + 1 < units.count && units[i] == starChar && units[i + 1] == starChar }

        mutating func parseExpression() -> Value? {
            guard var left = parseTerm() else { return nil }
            while true {
                skip()
                guard let op = current, op == plusChar || op == minusChar else { break }
                i += 1
                operations += 1
                guard let right = parseTerm() else { return nil }
                guard let next = op == plusChar ? add(left, right) : subtract(left, right) else { return nil }
                left = next
            }
            return left
        }

        mutating func parseTerm() -> Value? {
            guard var left = parseUnary() else { return nil }
            while true {
                skip()
                guard let op = current, op == starChar || op == slashChar, !atDoubleStar else { break }
                i += 1
                operations += 1
                guard let right = parseUnary() else { return nil }
                guard let next = op == starChar ? multiply(left, right) : divide(left, right) else { return nil }
                left = next
            }
            return left
        }

        mutating func parseUnary() -> Value? {
            skip()
            guard let u = current else { return nil }
            if u == plusChar || u == minusChar {
                i += 1
                guard let value = parseUnary() else { return nil }
                return u == minusChar ? negate(value) : value
            }
            return parsePower()
        }

        mutating func parsePower() -> Value? {
            guard let base = parsePostfix() else { return nil }
            skip()
            if current == caretChar {
                i += 1
            } else if atDoubleStar {
                i += 2
            } else {
                return base
            }
            operations += 1
            guard let exponent = parseUnary() else { return nil }
            return power(base, exponent)
        }

        mutating func parsePostfix() -> Value? {
            guard var value = parsePrimary() else { return nil }
            while true {
                skip()
                guard let u = current else { break }
                let next: Value?
                if u == bangChar {
                    operations += 1
                    next = factorial(value)
                } else if u == percentChar {
                    next = divide(value, .exact(Fraction(num: 100, den: 1)))
                } else if u == degreeChar {
                    next = approx(double(value) * .pi / 180)
                } else {
                    break
                }
                i += 1
                guard let next else { return nil }
                value = next
            }
            return value
        }

        mutating func parsePrimary() -> Value? {
            skip()
            guard let u = current else { return nil }
            if u == lParen {
                i += 1
                guard enter() else { return nil }
                guard let value = parseExpression() else { return nil }
                skip()
                guard current == rParen else { return nil }
                i += 1
                depth -= 1
                return value
            }
            if u == sqrtChar {
                i += 1
                operations += 1
                guard let value = parsePostfix() else { return nil }
                return root(value, 2)
            }
            if u == piChar {
                i += 1
                return .approx(.pi)
            }
            if isLetter(u) { return parseName() }
            return parseNumber()
        }

        mutating func enter() -> Bool {
            depth += 1
            maxDepth = max(maxDepth, depth)
            return maxDepth <= maxParenDepth
        }

        /// A constant (`pi`, `e`) or a function call; names ignore case. Anything else is not an expression.
        mutating func parseName() -> Value? {
            let start = i
            while i < units.count, isLetter(units[i]) || isDigit(units[i]) { i += 1 }
            let name = decode(units[start..<i]).lowercased()
            skip()
            guard current == lParen else {
                switch name {
                case "pi": return .approx(.pi)
                case "e": return .approx(M_E)
                default: return nil
                }
            }
            i += 1
            guard enter() else { return nil }
            var args: [Value] = []
            while true {
                guard let arg = parseExpression() else { return nil }
                args.append(arg)
                skip()
                guard current == commaChar else { break }
                i += 1
            }
            guard current == rParen else { return nil }
            i += 1
            depth -= 1
            operations += 1
            return call(name, args)
        }

        /// Digits with at most one `.`, then an optional exponent (`1e5`, `2.5E-3`).
        mutating func parseNumber() -> Value? {
            skip()
            let start = i
            var sawDigit = false
            var sawDot = false
            while i < units.count {
                if isDigit(units[i]) {
                    sawDigit = true
                    i += 1
                } else if units[i] == dotChar, !sawDot {
                    sawDot = true
                    i += 1
                } else {
                    break
                }
            }
            guard sawDigit, let mantissa = fraction(units[start..<i]) else { return nil }
            guard let exponent = parseExponent() else { return .exact(mantissa) }
            if abs(exponent) <= 38, let scale = exactPower(Fraction(num: 10, den: 1), exponent),
               let value = multiply(mantissa, scale) {
                return .exact(value)
            }
            return approx(Double(decode(units[start..<i])) ?? .nan)
        }

        mutating func parseExponent() -> Int? {
            guard i < units.count, units[i] == 0x65 || units[i] == 0x45 else { return nil }
            var j = i + 1
            var negative = false
            if j < units.count, units[j] == plusChar || units[j] == minusChar {
                negative = units[j] == minusChar
                j += 1
            }
            let digitsStart = j
            while j < units.count, isDigit(units[j]), j - digitsStart < 4 { j += 1 }
            guard j > digitsStart, j == units.count || !isDigit(units[j]),
                  let magnitude = Int(decode(units[digitsStart..<j])) else { return nil }
            i = j
            return negative ? -magnitude : magnitude
        }
    }

    // MARK: Functions

    private static func call(_ name: String, _ args: [Value]) -> Value? {
        switch (name, args.count) {
        case ("sqrt", 1): return root(args[0], 2)
        case ("cbrt", 1): return root(args[0], 3)
        case ("root", 2): return root(args[0], args[1])
        case ("pow", 2): return power(args[0], args[1])
        case ("abs", 1): return sign(args[0]) < 0 ? negate(args[0]) : args[0]
        case ("mod", 2): return modulo(args[0], args[1])
        case ("max", 1...): return extreme(args, wantLarger: true)
        case ("min", 1...): return extreme(args, wantLarger: false)
        case ("avg", 1...):
            var sum = args[0]
            for arg in args.dropFirst() {
                guard let next = add(sum, arg) else { return nil }
                sum = next
            }
            return divide(sum, .exact(Fraction(num: Decimal(args.count), den: 1)))
        case ("round", 1): return roundValue(args[0], places: 0)
        case ("round", 2):
            guard let places = smallInteger(args[1]), abs(places) <= 15 else { return nil }
            return roundValue(args[0], places: places)
        case ("floor", 1): return floorValue(args[0])
        case ("ceil", 1):
            guard let negated = negate(args[0]), let floored = floorValue(negated) else { return nil }
            return negate(floored)
        case ("log", 1), ("log10", 1): return logarithm(args[0], base: .exact(Fraction(num: 10, den: 1)))
        case ("log2", 1): return logarithm(args[0], base: .exact(Fraction(num: 2, den: 1)))
        case ("log", 2): return logarithm(args[0], base: args[1])
        case ("ln", 1): return logarithm(args[0], base: .approx(M_E))
        case ("exp", 1): return approx(Foundation.exp(double(args[0])))
        case ("sin", 1): return snapped(Foundation.sin(double(args[0])))
        case ("cos", 1): return snapped(Foundation.cos(double(args[0])))
        case ("tan", 1):
            let x = double(args[0])
            if Swift.abs(Foundation.cos(x)) < 1e-12 { return nil }
            return snapped(Foundation.tan(x))
        case ("asin", 1):
            let x = double(args[0])
            return Swift.abs(x) <= 1 ? approx(Foundation.asin(x)) : nil
        case ("acos", 1):
            let x = double(args[0])
            return Swift.abs(x) <= 1 ? approx(Foundation.acos(x)) : nil
        case ("atan", 1): return approx(Foundation.atan(double(args[0])))
        default: return nil
        }
    }

    private static func power(_ base: Value, _ exponent: Value) -> Value? {
        if case .exact(let rawBase) = base, case .exact(let rawExponent) = exponent,
           let b = rawBase.reduced(), let e = rawExponent.reduced() {
            if b.num == 0, e.num < 0 { return nil }
            if e.den == 1, let n = smallInteger(exponent), let r = exactPower(b, n) { return .exact(r) }
            // A rational exponent p/q is exact when the base is a perfect q-th power: 8^(2/3), 4^0.5.
            if e.den != 1, let q = smallInteger(.exact(Fraction(num: e.den, den: 1))),
               let p = smallInteger(.exact(Fraction(num: e.num, den: 1))),
               let rooted = exactRoot(b, q), let r = exactPower(rooted, p) {
                return .exact(r)
            }
        }
        let x = double(base)
        let y = double(exponent)
        if x == 0, y < 0 { return nil }
        if x < 0, y != y.rounded() { return nil }
        return approx(Foundation.pow(x, y))
    }

    /// Real roots only: an even root of a negative number has none.
    private static func root(_ value: Value, _ degree: Value) -> Value? {
        guard let n = smallInteger(degree) else {
            let x = double(value)
            let d = double(degree)
            guard x >= 0, d != 0 else { return nil }
            return approx(Foundation.pow(x, 1 / d))
        }
        if n == 0 { return nil }
        if n < 0 {
            guard let positive = root(value, -n) else { return nil }
            return divide(.exact(Fraction(num: 1, den: 1)), positive)
        }
        return root(value, n)
    }

    private static func root(_ value: Value, _ n: Int) -> Value? {
        if case .exact(let f) = value, let r = exactRoot(f, n) { return .exact(r) }
        let x = double(value)
        if x < 0, n % 2 == 0 { return nil }
        switch n {
        case 1: return value
        case 2: return approx(x.squareRoot())
        case 3: return approx(Foundation.cbrt(x))
        default:
            let r = Foundation.pow(Swift.abs(x), 1 / Double(n))
            return approx(x < 0 ? -r : r)
        }
    }

    /// Non-negative integers only. Exact up to 33! (below 10^38), floating point up to 170!.
    private static func factorial(_ value: Value) -> Value? {
        guard let n = smallInteger(value), n >= 0, n <= 170 else { return nil }
        var result = Decimal(1)
        for k in stride(from: 2, through: n, by: 1) {
            guard let next = mul(result, Decimal(k)) else { return approx(Foundation.tgamma(Double(n) + 1)) }
            result = next
        }
        return .exact(Fraction(num: result, den: 1))
    }

    /// The result takes the divisor's sign: `mod(-7, 3)` is 2.
    private static func modulo(_ a: Value, _ b: Value) -> Value? {
        if sign(b) == 0 { return nil }
        if case .exact = a, case .exact = b,
           let q = divide(a, b), let f = floorValue(q), let p = multiply(b, f), let r = subtract(a, p), case .exact = r {
            return r
        }
        let x = double(a)
        let y = double(b)
        var r = Foundation.fmod(x, y)
        if r != 0, (r < 0) != (y < 0) { r += y }
        return approx(r)
    }

    private static func extreme(_ values: [Value], wantLarger: Bool) -> Value? {
        var best = values[0]
        for value in values.dropFirst() {
            guard let diff = subtract(value, best) else { return nil }
            let s = sign(diff)
            if wantLarger ? s > 0 : s < 0 { best = value }
        }
        return best
    }

    /// Half away from zero, at `places` decimals (negative rounds to tens, hundreds, …).
    private static func roundValue(_ value: Value, places: Int) -> Value? {
        guard let scale = exactPower(Fraction(num: 10, den: 1), places) else { return nil }
        if case .exact(let f) = value, let scaled = multiply(f, scale) {
            let negative = scaled.num < 0
            let magnitude: Fraction? = negative ? negate(scaled) : scaled
            if let magnitude, let shifted = add(magnitude, Fraction(num: 1, den: 2)),
               case .exact(let q)? = floorValue(.exact(shifted)),
               let signed = negative ? negate(q) : q, let back = divide(signed, scale) {
                return .exact(back)
            }
        }
        let p = Foundation.pow(10, Double(places))
        return approx((double(value) * p).rounded(.toNearestOrAwayFromZero) / p)
    }

    private static func floorValue(_ value: Value) -> Value? {
        switch value {
        case .exact(let f):
            guard let f = f.reduced() else { return nil }
            if f.num >= 0 {
                guard let (q, _) = divmod(f.num, f.den) else { return nil }
                return .exact(Fraction(num: q, den: 1))
            }
            guard let absn = negDec(f.num), let (q, r) = divmod(absn, f.den) else { return nil }
            guard let up = r == 0 ? q : addDec(q, 1), let n = negDec(up) else { return nil }
            return .exact(Fraction(num: n, den: 1))
        case .approx(let d):
            return approx(d.rounded(.down))
        }
    }

    /// Exact when the argument is an exact integer power of an exact base: `log10(1000)` is 3.
    private static func logarithm(_ value: Value, base: Value) -> Value? {
        let x = double(value)
        let b = double(base)
        guard x > 0, b > 0, b != 1 else { return nil }
        let r: Double
        switch b {
        case 10: r = Foundation.log10(x)
        case 2: r = Foundation.log2(x)
        default: r = Foundation.log(x) / Foundation.log(b)
        }
        if case .exact(let f) = value, case .exact(let bf) = base, r.isFinite {
            let k = r.rounded()
            if Swift.abs(r - k) < 1e-9, Swift.abs(k) <= 1000, let p = exactPower(bf, Int(k)),
               let pr = p.reduced(), let fr = f.reduced(), pr.num == fr.num, pr.den == fr.den {
                return .exact(Fraction(num: Decimal(Int(k)), den: 1))
            }
        }
        return approx(r)
    }

    // MARK: Values

    private static func double(_ value: Value) -> Double {
        switch value {
        case .exact(let f): NSDecimalNumber(decimal: f.num).doubleValue / NSDecimalNumber(decimal: f.den).doubleValue
        case .approx(let d): d
        }
    }

    private static func approx(_ d: Double) -> Value? {
        d.isFinite ? .approx(d) : nil
    }

    /// Trigonometry of a multiple of π lands a rounding error away from 0; show 0.
    private static func snapped(_ d: Double) -> Value? {
        approx(Swift.abs(d) < 1e-12 ? 0 : d)
    }

    private static func sign(_ value: Value) -> Int {
        switch value {
        case .exact(let f): f.num == 0 ? 0 : ((f.num < 0) == (f.den < 0) ? 1 : -1)
        case .approx(let d): d == 0 ? 0 : (d < 0 ? -1 : 1)
        }
    }

    /// An integer of magnitude 10 000 or less, written exactly or floating point with no fraction.
    private static func smallInteger(_ value: Value) -> Int? {
        switch value {
        case .exact(let f):
            guard let f = f.reduced(), f.den == 1, f.num.magnitude <= 10_000 else { return nil }
            return NSDecimalNumber(decimal: f.num).intValue
        case .approx(let d):
            guard d == d.rounded(), Swift.abs(d) <= 10_000 else { return nil }
            return Int(d)
        }
    }

    private static func add(_ a: Value, _ b: Value) -> Value? {
        if case .exact(let x) = a, case .exact(let y) = b, let r = add(x, y) { return .exact(r) }
        return cancelled(double(a) + double(b), double(a), double(b))
    }

    private static func subtract(_ a: Value, _ b: Value) -> Value? {
        if case .exact(let x) = a, case .exact(let y) = b, let r = subtract(x, y) { return .exact(r) }
        return cancelled(double(a) - double(b), double(a), double(b))
    }

    /// `sqrt(2)^2 - 2` is a rounding error, not 4.4e-16.
    private static func cancelled(_ r: Double, _ a: Double, _ b: Double) -> Value? {
        approx(Swift.abs(r) <= max(Swift.abs(a), Swift.abs(b)) * 1e-12 ? 0 : r)
    }

    private static func multiply(_ a: Value, _ b: Value) -> Value? {
        if case .exact(let x) = a, case .exact(let y) = b, let r = multiply(x, y) { return .exact(r) }
        return approx(double(a) * double(b))
    }

    private static func divide(_ a: Value, _ b: Value) -> Value? {
        if sign(b) == 0 { return nil }
        if case .exact(let x) = a, case .exact(let y) = b, let r = divide(x, y) { return .exact(r) }
        return approx(double(a) / double(b))
    }

    private static func negate(_ a: Value) -> Value? {
        switch a {
        case .exact(let f): negate(f).map { .exact($0) }
        case .approx(let d): .approx(-d)
        }
    }

    /// Nil when an intermediate passes the exact range; the caller then falls back to floating point.
    private static func exactPower(_ base: Fraction, _ n: Int) -> Fraction? {
        var b = base
        var e = n
        if e < 0 {
            if b.num == 0 { return nil }
            b = Fraction(num: base.den, den: base.num)
            e = -e
        }
        var result = Fraction(num: 1, den: 1)
        while e > 0 {
            if e & 1 == 1 {
                guard let next = multiply(result, b) else { return nil }
                result = next
            }
            e >>= 1
            if e > 0 {
                guard let next = multiply(b, b) else { return nil }
                b = next
            }
        }
        return result.reduced()
    }

    /// The n-th root when numerator and denominator are both perfect n-th powers.
    private static func exactRoot(_ f: Fraction, _ n: Int) -> Fraction? {
        guard n >= 1, let f = f.reduced() else { return nil }
        if n == 1 { return f }
        if f.num < 0 {
            guard n % 2 == 1, let positive = negDec(f.num), let r = exactRoot(Fraction(num: positive, den: f.den), n) else { return nil }
            return negate(r)
        }
        guard let num = integerRoot(f.num, n), let den = integerRoot(f.den, n) else { return nil }
        return Fraction(num: num, den: den)
    }

    private static func integerRoot(_ x: Decimal, _ n: Int) -> Decimal? {
        if x == 0 || x == 1 { return x }
        let guess = Foundation.pow(NSDecimalNumber(decimal: x).doubleValue, 1 / Double(n)).rounded()
        guard guess.isFinite, guess < 1e19, let center = Decimal(string: String(format: "%.0f", guess)) else { return nil }
        for delta in [Decimal(0), Decimal(-1), Decimal(1)] {
            guard let candidate = addDec(center, delta), candidate > 0,
                  let p = exactPower(Fraction(num: candidate, den: 1), n) else { continue }
            if p.den == 1, p.num == x { return candidate }
        }
        return nil
    }

    private static func fraction(_ units: ArraySlice<UInt16>) -> Fraction? {
        var num = Decimal(0)
        var scale = 0
        var seenDot = false
        var digits = 0
        for u in units {
            if u == dotChar { seenDot = true; continue }
            guard let scaled = mul(num, 10), let next = addDec(scaled, Decimal(Int(u - 0x30))) else { return nil }
            num = next
            digits += 1
            if seenDot { scale += 1 }
            if digits > 38 { return nil }
        }
        var den = Decimal(1)
        for _ in 0..<scale {
            guard let next = mul(den, 10) else { return nil }
            den = next
        }
        return Fraction(num: num, den: den)
    }

    private static func add(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let ad = mul(a.num, b.den), let bc = mul(b.num, a.den), let num = addDec(ad, bc), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func subtract(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let ad = mul(a.num, b.den), let bc = mul(b.num, a.den), let num = subDec(ad, bc), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func multiply(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let num = mul(a.num, b.num), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func divide(_ a: Fraction, _ b: Fraction) -> Fraction? {
        if b.num == 0 { return nil }
        guard let num = mul(a.num, b.den), let den = mul(a.den, b.num) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func negate(_ a: Fraction) -> Fraction? {
        guard let num = negDec(a.num) else { return nil }
        return Fraction(num: num, den: a.den).reduced()
    }

    private static func reduce(_ f: Fraction) -> Fraction? {
        if f.den == 0 || !f.num.isFinite || !f.den.isFinite { return nil }
        var n = f.num
        var d = f.den
        if d < 0 {
            guard let nn = negDec(n), let dd = negDec(d) else { return nil }
            n = nn
            d = dd
        }
        let an: Decimal
        if n < 0 {
            guard let absn = negDec(n) else { return nil }
            an = absn
        } else {
            an = n
        }
        guard let g = gcd(an, d) else { return nil }
        guard let nn = divExact(n, g), let dd = divExact(d, g) else { return nil }
        return Fraction(num: nn, den: dd)
    }

    // MARK: Display

    private static func format(_ value: Value) -> Formatted? {
        switch value {
        case .exact(let f):
            if let exact = format(f) { return exact }
            return formatDouble(double(value)).map { Formatted(text: $0, approximate: true) }
        case .approx(let d):
            return formatDouble(d).map { Formatted(text: $0, approximate: true) }
        }
    }

    /// 12 significant digits; scientific notation (`1.60693804426e60`) from 10^15 up and below 10^-6.
    private static func formatDouble(_ d: Double) -> String? {
        guard d.isFinite else { return nil }
        if d == 0 { return "0" }
        let magnitude = Swift.abs(d)
        if magnitude >= 1e15 || magnitude < 1e-6 {
            let s = String(format: "%.\(significantDigits - 1)e", d)
            guard let e = s.firstIndex(of: "e") else { return nil }
            let mantissa = trimZeros(String(s[..<e]))
            var exponent = String(s[s.index(after: e)...])
            let negative = exponent.hasPrefix("-")
            exponent.removeAll { $0 == "+" || $0 == "-" }
            while exponent.count > 1, exponent.hasPrefix("0") { exponent.removeFirst() }
            return mantissa + "e" + (negative ? "-" : "") + exponent
        }
        let places = max(0, significantDigits - 1 - Int(Foundation.floor(Foundation.log10(magnitude))))
        let text = trimZeros(String(format: "%.\(places)f", d))
        return text == "-0" ? "0" : text
    }

    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Terminating decimals are printed in full (up to 48 places). Anything else rounds to 12 significant digits.
    private static func format(_ fraction: Fraction) -> Formatted? {
        guard let reduced = fraction.reduced() else { return nil }
        let negative = reduced.num < 0
        let num: Decimal
        if negative {
            guard let absn = negDec(reduced.num) else { return nil }
            num = absn
        } else {
            num = reduced.num
        }
        guard let (ip, rem) = divmod(num, reduced.den), let intStr = integerDigits(ip) else { return nil }
        if rem == 0 {
            return Formatted(text: negative && ip != 0 ? "-" + intStr : intStr, approximate: false)
        }
        if let scale = terminatingScale(reduced.den), scale <= 48 {
            var digits: [Int] = []
            var rest = rem
            for _ in 0..<scale {
                guard let times = mul(rest, 10), let (qd, rd) = divmod(times, reduced.den), let digit = asDigit(qd) else { return nil }
                digits.append(digit)
                rest = rd
            }
            guard rest == 0 else { return nil }
            while digits.last == 0 { digits.removeLast() }
            if digits.isEmpty { return Formatted(text: negative && ip != 0 ? "-" + intStr : intStr, approximate: false) }
            let body = intStr + "." + digits.map(String.init).joined()
            return Formatted(text: (negative ? "-" : "") + body, approximate: false)
        }
        // Zeros between the decimal point and the first nonzero digit are not significant.
        // Keep dividing until 12 significant digits and one rounding digit are in hand.
        let intSig = intStr == "0" ? 0 : intStr.count
        var frac: [Int] = []
        var rest = rem
        var sig = intSig
        let target = significantDigits + 1
        while rest != 0, sig < target, frac.count < 160 {
            guard let times = mul(rest, 10), let (qd, rd) = divmod(times, reduced.den), let digit = asDigit(qd) else { return nil }
            frac.append(digit)
            rest = rd
            if sig > 0 || digit != 0 { sig += 1 }
        }
        if rest != 0, sig < target { return nil }
        guard let text = roundSignificant(intStr: intStr, frac: frac, negative: negative) else { return nil }
        return Formatted(text: text, approximate: true)
    }

    /// Decimal places of a lowest-terms denominator whose only prime factors are 2 and 5. Nil when it repeats.
    private static func terminatingScale(_ den: Decimal) -> Int? {
        var d = den
        var twos = 0
        var fives = 0
        while d != 1 {
            guard let (q2, r2) = divmod(d, 2) else { return nil }
            if r2 == 0 { twos += 1; d = q2; continue }
            guard let (q5, r5) = divmod(d, 5) else { return nil }
            if r5 == 0 { fives += 1; d = q5; continue }
            return nil
        }
        return max(twos, fives)
    }

    private static func roundSignificant(intStr: String, frac: [Int], negative: Bool) -> String? {
        var digits = intStr.compactMap(\.wholeNumberValue)
        guard digits.count == intStr.count else { return nil }
        let decimalAt = digits.count
        digits.append(contentsOf: frac)
        guard let first = digits.firstIndex(where: { $0 != 0 }) else { return "0" }
        let end = first + significantDigits
        while digits.count <= end { digits.append(0) }
        let roundDigit = digits[end]
        var kept = Array(digits[0..<end])
        var point = decimalAt
        if roundDigit >= 5 {
            var index = kept.count - 1
            var carry = true
            while carry, index >= 0 {
                if kept[index] < 9 {
                    kept[index] += 1
                    carry = false
                } else {
                    kept[index] = 0
                    index -= 1
                }
            }
            if carry {
                kept.insert(1, at: 0)
                point += 1
            }
        }
        let intDigits: [Int]
        let fracDigits: [Int]
        if point >= kept.count {
            intDigits = kept + Array(repeating: 0, count: point - kept.count)
            fracDigits = []
        } else if point <= 0 {
            intDigits = [0]
            fracDigits = Array(repeating: 0, count: -point) + kept
        } else {
            intDigits = Array(kept[0..<point])
            fracDigits = Array(kept[point...])
        }
        var ints = intDigits
        while ints.count > 1, ints[0] == 0 { ints.removeFirst() }
        var fracs = fracDigits
        while fracs.last == 0 { fracs.removeLast() }
        var text = ints.map(String.init).joined()
        if !fracs.isEmpty { text += "." + fracs.map(String.init).joined() }
        if negative, text != "0" { text = "-" + text }
        return text
    }

    private static func integerDigits(_ n: Decimal) -> String? {
        if n == 0 { return "0" }
        if n < 0 { return nil }
        var x = n
        var digits: [Int] = []
        var steps = 0
        while x != 0 {
            steps += 1
            if steps > 40 { return nil }
            guard let (q, r) = divmod(x, 10), let digit = asDigit(r) else { return nil }
            digits.append(digit)
            x = q
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func asDigit(_ n: Decimal) -> Int? {
        guard n >= 0, n <= 9 else { return nil }
        let value = NSDecimalNumber(decimal: n).intValue
        return Decimal(value) == n ? value : nil
    }

    private static func mul(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalMultiply(&r, &x, &y, .plain), r)
    }

    private static func addDec(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalAdd(&r, &x, &y, .plain), r)
    }

    private static func subDec(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalSubtract(&r, &x, &y, .plain), r)
    }

    private static func negDec(_ a: Decimal) -> Decimal? { subDec(0, a) }

    /// Integer quotient and remainder. Both arguments are non-negative and the divisor is not zero.
    private static func divmod(_ n: Decimal, _ d: Decimal) -> (Decimal, Decimal)? {
        if d == 0 || n < 0 || d < 0 { return nil }
        var q = Decimal(), nn = n, dd = d
        let err = NSDecimalDivide(&q, &nn, &dd, .down)
        if decimalFailed(err), err != .lossOfPrecision || !q.isFinite { return nil }
        var qi = Decimal(), qq = q
        NSDecimalRound(&qi, &qq, 0, .down)
        guard let prod = mul(qi, d), let rem = subDec(n, prod) else { return nil }
        if rem < 0 {
            guard let qi2 = subDec(qi, 1), let prod2 = mul(qi2, d), let rem2 = subDec(n, prod2), rem2 >= 0, rem2 < d else { return nil }
            return (qi2, rem2)
        }
        if rem >= d {
            guard let qi2 = addDec(qi, 1), let prod2 = mul(qi2, d), let rem2 = subDec(n, prod2), rem2 >= 0, rem2 < d else { return nil }
            return (qi2, rem2)
        }
        return (qi, rem)
    }

    private static func divExact(_ n: Decimal, _ d: Decimal) -> Decimal? {
        if d == 0 { return nil }
        var q = Decimal(), nn = n, dd = d
        let err = NSDecimalDivide(&q, &nn, &dd, .plain)
        guard let prod = mul(q, d), prod == n, err == .noError || err == .lossOfPrecision, q.isFinite else { return nil }
        return q
    }

    private static func gcd(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var x = a, y = b
        var steps = 0
        while y != 0 {
            steps += 1
            if steps > 80 { return nil }
            guard let (_, r) = divmod(x, y) else { return nil }
            x = y
            y = r
        }
        return x == 0 ? nil : x
    }

    /// Numerators and denominators are integers, which `Decimal` holds exactly below 10^38. Past that it
    /// rounds silently and still reports `.noError`, so a larger result is refused rather than shown as exact.
    private static let exactLimit = Decimal(sign: .plus, exponent: 38, significand: 1)

    private static func checked(_ err: NSDecimalNumber.CalculationError, _ value: Decimal) -> Decimal? {
        if decimalFailed(err) || !value.isFinite || value.magnitude >= exactLimit { return nil }
        return value
    }

    /// One error is reported at a time. Loss of precision is a failure: the ghost must not round mid-expression.
    private static func decimalFailed(_ err: NSDecimalNumber.CalculationError) -> Bool {
        err != .noError
    }
}
