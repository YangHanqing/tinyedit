import CoreGraphics
import Foundation

/// Turns what Vision recognized in a picture into plain text that keeps the picture's layout: lines top to
/// bottom, pieces of one line left to right, indentation from the left edge, a blank line where the gap
/// between two lines is about a line high, and tables (macOS 26) as Markdown. Pure geometry, so the
/// rules are testable without Vision.
enum ImageTextLayout {
    /// One recognized run of text. `rect` is in image pixels with the origin at the top left.
    struct Line: Equatable, Sendable {
        var text: String
        var rect: CGRect
    }

    /// Cell text by row, as Vision's document reader found it.
    struct Table: Equatable, Sendable {
        var rows: [[String]]
        var rect: CGRect
    }

    /// A gap between two lines taller than this many line heights is a blank line.
    static let paragraphGap: CGFloat = 0.7
    /// Pieces of one line farther apart than this many character widths keep the distance as spaces.
    static let maxSpacing = 40

    /// `indent` is how leading columns are written: spaces, or TABs of `tabWidth` columns plus spaces.
    static func text(lines: [Line], tables: [Table] = [], indent: IndentStyle, tabWidth: Int) -> String {
        let free = lines.compactMap { line -> Line? in
            var line = line
            line.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.text.isEmpty, line.rect.height > 0 else { return nil }
            let center = CGPoint(x: line.rect.midX, y: line.rect.midY)
            return tables.contains { $0.rect.contains(center) } ? nil : line
        }
        let charWidth = characterWidth(free)
        let lineHeight = median(free.map(\.rect.height)) ?? 0
        let left = free.map(\.rect.minX).min() ?? 0

        enum Block {
            case row([Line], CGRect)
            case table(Table)
            var top: CGFloat {
                switch self {
                case .row(_, let rect): rect.minY
                case .table(let table): table.rect.minY
                }
            }
        }
        let blocks = (rows(free).map { Block.row($0, $0.dropFirst().reduce($0[0].rect) { $0.union($1.rect) }) }
            + tables.filter { !$0.rows.isEmpty }.map(Block.table))
            .sorted { $0.top < $1.top }

        var out: [String] = []
        var previousBottom: CGFloat?
        var previousWasTable = false
        for block in blocks {
            switch block {
            case .row(let pieces, let rect):
                if let bottom = previousBottom,
                   previousWasTable || rect.minY - bottom > paragraphGap * lineHeight {
                    out.append("")
                }
                let columns = Int(((rect.minX - left) / charWidth).rounded())
                // One column is jitter in where Vision put the box, not an indent.
                out.append(leading(columns > 1 ? columns : 0, indent: indent, tabWidth: tabWidth)
                           + joined(pieces, charWidth: charWidth))
                previousBottom = rect.maxY
                previousWasTable = false
            case .table(let table):
                if !out.isEmpty { out.append("") }
                out.append(contentsOf: markdownTable(table.rows))
                previousBottom = table.rect.maxY
                previousWasTable = true
            }
        }
        return out.joined(separator: "\n")
    }

    /// Vision does not label headers. Use the first row as the Markdown header and pad missing cells.
    static func markdownTable(_ rows: [[String]]) -> [String] {
        guard let columns = rows.map(\.count).max(), columns > 0 else { return [] }
        func cell(_ value: String) -> String {
            var text = value.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            for character in ["\\", "|", "`", "*", "_", "[", "]"] {
                text = text.replacingOccurrences(of: character, with: "\\" + character)
            }
            return text
        }
        var lines = rows.map { row in
            "| " + (row.map(cell) + Array(repeating: "", count: columns - row.count)).joined(separator: " | ") + " |"
        }
        lines.insert("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |", at: 1)
        return lines
    }

    /// Lines whose vertical extents overlap by half the shorter one are one row, sorted left to right.
    static func rows(_ lines: [Line]) -> [[Line]] {
        var rows: [[Line]] = []
        var band = CGRect.null
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            let overlap = min(band.maxY, line.rect.maxY) - max(band.minY, line.rect.minY)
            if !rows.isEmpty, overlap >= 0.5 * min(band.height, line.rect.height) {
                rows[rows.count - 1].append(line)
                band = band.union(line.rect)
            } else {
                rows.append([line])
                band = line.rect
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// The median width of one column, from lines long enough to average out; CJK counts two columns.
    static func characterWidth(_ lines: [Line]) -> CGFloat {
        let widths = lines.compactMap { line -> CGFloat? in
            let columns = displayColumns(line.text)
            return columns >= 3 ? line.rect.width / CGFloat(columns) : nil
        }
        if let width = median(widths), width > 0 { return width }
        return max(1, 0.5 * (median(lines.map(\.rect.height)) ?? 2))
    }

    static func displayColumns(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func joined(_ pieces: [Line], charWidth: CGFloat) -> String {
        var text = pieces[0].text
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            let columns = Int(((b.rect.minX - a.rect.maxX) / charWidth).rounded())
            if columns >= 2 {
                text += String(repeating: " ", count: min(columns, maxSpacing))
            } else if columns <= 0, let last = a.text.unicodeScalars.last, let first = b.text.unicodeScalars.first,
                      isWide(last) || isWide(first) {
                // CJK runs split into two boxes join without a space.
            } else {
                text += " "
            }
            text += b.text
        }
        return text
    }

    private static func leading(_ columns: Int, indent: IndentStyle, tabWidth: Int) -> String {
        switch indent {
        case .spaces: String(repeating: " ", count: columns)
        case .tabs:
            String(repeating: "\t", count: columns / max(1, tabWidth))
                + String(repeating: " ", count: columns % max(1, tabWidth))
        }
    }

    /// East Asian wide and fullwidth characters: Hangul, CJK, kana, fullwidth forms.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
