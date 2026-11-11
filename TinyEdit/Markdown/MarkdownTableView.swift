import AppKit
import SwiftUI

/// A table of text is one AppKit view that places a `MarkdownLabelView` per cell itself. As a SwiftUI
/// `Grid` every cell was several views to build and tear down while scrolling, and a table has many.
/// A table holding a picture still goes through the grid (`MarkdownTableGrid`).
struct MarkdownTableTextView: NSViewRepresentable {
    let table: MarkdownTable
    let size: CGFloat
    let availableWidth: CGFloat
    let path: String
    @Environment(\.markdownSelection) private var selection

    static func canShow(_ table: MarkdownTable) -> Bool {
        !(table.header + table.rows.joined()).contains { $0.runs.contains { $0.imageURL != nil } }
    }

    func makeNSView(context: Context) -> MarkdownTableNSView { MarkdownTableNSView() }

    func updateNSView(_ view: MarkdownTableNSView, context: Context) {
        view.setContent(table, size: size, secondary: context.environment.markdownSecondaryText, openURL: context.environment.openURL)
        view.setAvailableWidth(availableWidth)
        view.bindSelection(selection, path: path)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTableNSView, context: Context) -> CGSize? {
        nsView.setAvailableWidth(availableWidth)
        return nsView.tableSize
    }
}

final class MarkdownTableNSView: NSView {
    static let cellPadding: CGFloat = 10
    private static let rowPadding: CGFloat = 8
    /// Keeps the border's stroke inside the view.
    private static let borderInset: CGFloat = 1

    private var table: MarkdownTable?
    private var size: CGFloat = 0
    private var secondary = false
    /// Header first, then the rows, each `columns` long.
    private var cells: [MarkdownLabelView] = []
    private var columns = 0
    /// Each column's one-line width, kept until the table changes, so a new width only re-runs the layout.
    private var natural: [CGFloat] = []
    private var availableWidth: CGFloat = -1
    private var rowLines: [CGFloat] = []
    private(set) var tableSize = CGSize.zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func bindSelection(_ selection: MarkdownSelection?, path: String) {
        for (index, cell) in cells.enumerated() {
            cell.bindSelection(selection, id: "\(path).r\(index / columns).c\(index % columns).0")
        }
    }

    func setContent(_ table: MarkdownTable, size: CGFloat, secondary: Bool, openURL: OpenURLAction) {
        if table != self.table || size != self.size || secondary != self.secondary {
            self.table = table
            self.size = size
            self.secondary = secondary
            columns = table.columns.count
            let texts = [table.header] + table.rows
            let count = texts.count * columns
            while cells.count > count { cells.removeLast().removeFromSuperview() }
            while cells.count < count {
                let cell = MarkdownLabelView()
                cells.append(cell)
                addSubview(cell)
            }
            natural = Array(repeating: 0, count: columns)
            for (row, values) in texts.enumerated() {
                for column in 0..<columns {
                    let cell = cells[row * columns + column]
                    cell.setContent(MarkdownText.attributed(values[column], style: .init(size: size,
                        weight: row == 0 ? .semibold : .regular, secondary: secondary, alignment: alignment(table.columns[column]))))
                    natural[column] = max(natural[column], cell.fittingSize(width: nil).width)
                }
            }
            availableWidth = -1
        }
        for cell in cells { cell.openURL = openURL }
    }

    func setAvailableWidth(_ width: CGFloat) {
        guard width != availableWidth, columns > 0 else { return }
        availableWidth = width
        let widths = MarkdownTableLayout.widths(natural: natural,
            available: width - CGFloat(columns) * 2 * Self.cellPadding - 2 * Self.borderInset)
        var y = Self.borderInset
        rowLines = []
        for row in 0..<(cells.count / columns) {
            if row > 0 { rowLines.append(y); y += 1 }
            let heights = (0..<columns).map { cells[row * columns + $0].fittingSize(width: widths[$0]).height }
            var x = Self.borderInset
            for column in 0..<columns {
                cells[row * columns + column].frame = NSRect(x: x + Self.cellPadding, y: y + Self.rowPadding,
                                                             width: widths[column], height: heights[column])
                x += widths[column] + 2 * Self.cellPadding
            }
            y += (heights.max() ?? 0) + 2 * Self.rowPadding
        }
        tableSize = CGSize(width: widths.reduce(0, +) + CGFloat(columns) * 2 * Self.cellPadding + 2 * Self.borderInset,
                           height: y + Self.borderInset)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(origin: .zero, size: tableSize).insetBy(dx: Self.borderInset, dy: Self.borderInset)
        if let context = NSGraphicsContext.current?.cgContext {
            NSColor.separatorColor.setFill()
            for (index, y) in rowLines.enumerated() {
                // The line under the header is full strength, the ones between rows half.
                context.setAlpha(index == 0 ? 1 : 0.5)
                NSRect(x: box.minX, y: y, width: box.width, height: 1).fill(using: .sourceOver)
            }
            context.setAlpha(1)
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).stroke()
    }

    private func alignment(_ alignment: MarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}
