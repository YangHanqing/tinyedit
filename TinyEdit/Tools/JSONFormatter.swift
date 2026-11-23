import Foundation

enum JSONFormatResult: Equatable {
    case unchanged
    case formatted(String, replacedRange: NSRange)
    case invalid(line: Int?, column: Int?)
}

/// Foundation-only. A strict scanner builds an ordered tree (key order, duplicate keys, number and
/// string lexemes preserved); `JSONSerialization` is only a validity gate.
enum JSONFormatter {
    indirect enum Node {
        case object([(key: String, value: Node)])
        case array([Node])
        case scalar(String)
    }

    struct ParseError: Error { var offset: Int }

    static func format(text: String, selection: NSRange?, maximumOutputBytes: Int? = nil) -> JSONFormatResult {
        run(text: text, selection: selection, pretty: true, maximumOutputBytes: maximumOutputBytes)
    }

    static func minify(text: String, selection: NSRange?) -> JSONFormatResult {
        run(text: text, selection: selection, pretty: false)
    }

    // MARK: Driver

    private static func run(text: String, selection: NSRange?, pretty: Bool,
                            maximumOutputBytes: Int? = nil) -> JSONFormatResult {
        let units = Array(text.utf16)
        var lo = 0, hi = units.count
        let wholeDocument = selection == nil || selection!.length == 0
        if !wholeDocument, let sel = selection {
            guard sel.location >= 0, sel.location + sel.length <= units.count else { return .invalid(line: nil, column: nil) }
            lo = sel.location; hi = sel.location + sel.length
            while lo < hi, isSpace(units[lo]) { lo += 1 }
            while hi > lo, isSpace(units[hi - 1]) { hi -= 1 }
        }
        var parser = Parser(units: units, end: hi)
        let node: Node
        do {
            parser.pos = lo
            node = try parser.parseDocument()
        } catch let e as ParseError {
            let (l, c) = position(of: e.offset, in: units)
            return .invalid(line: l, column: c)
        } catch { return .invalid(line: nil, column: nil) }

        let inner = String(decoding: units[lo..<hi], as: UTF16.self)
        guard let data = inner.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return .invalid(line: nil, column: nil)
        }

        let finalNewline = wholeDocument && pretty && units.last == 0x0A
        var out: String
        if pretty {
            guard let formatted = printPretty(node, maximumBytes: maximumOutputBytes.map { $0 - (finalNewline ? 1 : 0) })
            else { return .unchanged }
            out = formatted
        } else {
            out = printMinified(node)
        }
        let range: NSRange
        if wholeDocument {
            if finalNewline { out += "\n" }
            range = NSRange(location: 0, length: units.count)
        } else {
            range = NSRange(location: lo, length: hi - lo)
        }
        let original = String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
        return out == original ? .unchanged : .formatted(out, replacedRange: range)
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D }

    /// 1-based line and UTF-16 column for an offset into `units`.
    static func position(of offset: Int, in units: [UInt16]) -> (Int, Int) {
        var line = 1, lineStart = 0
        let end = min(offset, units.count)
        for i in 0..<end where units[i] == 0x0A { line += 1; lineStart = i + 1 }
        return (line, offset - lineStart + 1)
    }

    /// Maps `NSJSONSerializationErrorIndex` (a byte offset into the UTF-8 that was parsed) to line and column.
    static func position(forUTF8Offset byteOffset: Int, in text: String, baseOffset: Int = 0) -> (Int, Int)? {
        let utf8 = Array(text.utf8)
        guard byteOffset >= 0, byteOffset <= utf8.count else { return nil }
        let prefix = String(decoding: utf8[0..<byteOffset], as: UTF8.self)
        let units = Array(text.utf16)
        return position(of: prefix.utf16.count + baseOffset, in: units)
    }

    // MARK: Printing

    private static func printPretty(_ node: Node, maximumBytes: Int?) -> String? {
        var output = ""
        var remaining = maximumBytes
        func append(_ text: String) -> Bool {
            if let budget = remaining {
                let bytes = text.utf8.count
                guard bytes <= budget else { return false }
                remaining = budget - bytes
            }
            output += text
            return true
        }
        func write(_ node: Node, indent: String) -> Bool {
            switch node {
            case .scalar(let text):
                return append(text)
            case .array(let items):
                if items.isEmpty { return append("[]") }
                guard append("[") else { return false }
                let child = indent + "  "
                for (index, item) in items.enumerated() {
                    guard append(index == 0 ? "\n" : ",\n"), append(child), write(item, indent: child) else { return false }
                }
                return append("\n") && append(indent) && append("]")
            case .object(let pairs):
                if pairs.isEmpty { return append("{}") }
                guard append("{") else { return false }
                let child = indent + "  "
                for (index, pair) in pairs.enumerated() {
                    guard append(index == 0 ? "\n" : ",\n"), append(child), append(pair.key),
                          append(": "), write(pair.value, indent: child) else { return false }
                }
                return append("\n") && append(indent) && append("}")
            }
        }
        return write(node, indent: "") ? output : nil
    }

    private static func printMinified(_ n: Node) -> String {
        switch n {
        case .scalar(let s): return s
        case .array(let items): return "[" + items.map(printMinified).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { "\($0.key):\(printMinified($0.value))" }.joined(separator: ",") + "}"
        }
    }

    // MARK: Scanner

    private struct Parser {
        let units: [UInt16]
        let end: Int
        var pos = 0
        var depth = 0

        init(units: [UInt16], end: Int) { self.units = units; self.end = end }

        mutating func parseDocument() throws -> Node {
            skipSpace()
            let v = try parseValue()
            skipSpace()
            if pos != end { throw ParseError(offset: pos) }
            return v
        }

        mutating func skipSpace() { while pos < end, JSONFormatter.isSpace(units[pos]) { pos += 1 } }

        func peek() -> UInt16? { pos < end ? units[pos] : nil }

        mutating func parseValue() throws -> Node {
            guard let c = peek() else { throw ParseError(offset: pos) }
            switch c {
            case 0x7B: return try parseObject()
            case 0x5B: return try parseArray()
            case 0x22: return .scalar(try parseString())
            case 0x74: return try literal("true")
            case 0x66: return try literal("false")
            case 0x6E: return try literal("null")
            default:
                if c == 0x2D || (c >= 0x30 && c <= 0x39) { return .scalar(try parseNumber()) }
                throw ParseError(offset: pos)
            }
        }

        mutating func literal(_ word: String) throws -> Node {
            let w = Array(word.utf16)
            guard pos + w.count <= end, Array(units[pos..<(pos + w.count)]) == w else { throw ParseError(offset: pos) }
            pos += w.count
            return .scalar(word)
        }

        mutating func parseObject() throws -> Node {
            depth += 1; defer { depth -= 1 }
            if depth > 512 { throw ParseError(offset: pos) }
            pos += 1
            var pairs: [(key: String, value: Node)] = []
            skipSpace()
            if peek() == 0x7D { pos += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard peek() == 0x22 else { throw ParseError(offset: pos) }
                let key = try parseString()
                skipSpace()
                guard peek() == 0x3A else { throw ParseError(offset: pos) }
                pos += 1
                skipSpace()
                pairs.append((key, try parseValue()))
                skipSpace()
                switch peek() {
                case 0x2C: pos += 1
                case 0x7D: pos += 1; return .object(pairs)
                default: throw ParseError(offset: pos)
                }
            }
        }

        mutating func parseArray() throws -> Node {
            depth += 1; defer { depth -= 1 }
            if depth > 512 { throw ParseError(offset: pos) }
            pos += 1
            var items: [Node] = []
            skipSpace()
            if peek() == 0x5D { pos += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try parseValue())
                skipSpace()
                switch peek() {
                case 0x2C: pos += 1
                case 0x5D: pos += 1; return .array(items)
                default: throw ParseError(offset: pos)
                }
            }
        }

        mutating func parseString() throws -> String {
            let start = pos
            pos += 1
            while let c = peek() {
                if c == 0x22 { pos += 1; return String(decoding: units[start..<pos], as: UTF16.self) }
                if c < 0x20 { throw ParseError(offset: pos) }
                if c == 0x5C {
                    pos += 1
                    guard let e = peek() else { throw ParseError(offset: pos) }
                    if e == 0x75 {
                        for k in 1...4 {
                            guard pos + k < end, Self.isHex(units[pos + k]) else { throw ParseError(offset: pos + k) }
                        }
                        pos += 5
                    } else if "\"\\/bfnrt".utf16.contains(e) {
                        pos += 1
                    } else { throw ParseError(offset: pos) }
                } else { pos += 1 }
            }
            throw ParseError(offset: pos)
        }

        static func isHex(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66)
        }

        func isDigit(_ u: UInt16?) -> Bool { u.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }

        mutating func parseNumber() throws -> String {
            let start = pos
            if peek() == 0x2D { pos += 1 }
            guard isDigit(peek()) else { throw ParseError(offset: pos) }
            if peek() == 0x30 { pos += 1 } else { while isDigit(peek()) { pos += 1 } }
            if peek() == 0x2E {
                pos += 1
                guard isDigit(peek()) else { throw ParseError(offset: pos) }
                while isDigit(peek()) { pos += 1 }
            }
            if peek() == 0x65 || peek() == 0x45 {
                pos += 1
                if peek() == 0x2B || peek() == 0x2D { pos += 1 }
                guard isDigit(peek()) else { throw ParseError(offset: pos) }
                while isDigit(peek()) { pos += 1 }
            }
            return String(decoding: units[start..<pos], as: UTF16.self)
        }
    }
}
