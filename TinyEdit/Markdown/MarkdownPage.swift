import SwiftUI

/// The rendered document, shared by the editor's preview pane and the Quick Look extension. Image
/// access and the document URL come from the environment; without them images stay placeholders.
struct MarkdownPage: View {
    let blocks: [MarkdownNode]
    var message: String?
    /// A new value starts a new scroll position and drops a pending heading jump.
    var identity: AnyHashable?

    @State private var headings = MarkdownHeadingRegistry()
    @State private var selection = MarkdownSelection()
    /// Measured inside the scroll view, so a legacy vertical scroller's strip is already left out.
    @State private var contentWidth: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let message {
                    Text(message).foregroundStyle(.secondary).padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: MarkdownStyle.blockSpacing) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, node in
                            MarkdownBlockView(node: node, path: "\(index)")
                                .id("top-\(index)")
                        }
                    }
                    .padding(MarkdownStyle.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
            }
            .id(identity)
            .environment(\.openURL, OpenURLAction { url in
                if url.relativeString.hasPrefix("#") {
                    let navigation = MarkdownNavigation(blocks)
                    if let target = navigation.target(for: url) {
                        if !headings.canLocate(target.path) {
                            proxy.scrollTo("top-\(target.topLevel)", anchor: .top)
                        }
                        headings.jump(to: target.path)
                    }
                    return .handled
                }
                return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
            .transformEnvironment(\.markdownAvailableWidth) { width in
                if let contentWidth { width = max(1, contentWidth - 2 * MarkdownStyle.pagePadding) }
            }
        }
        .environment(\.markdownHeadingRegistry, headings)
        .environment(\.markdownSelection, selection)
        .background { MarkdownSelectionHost(selection: selection, blocks: blocks, identity: identity) }
        .onChange(of: identity) { _, _ in headings.cancelJump() }
        .onDisappear { headings.reset(); selection.endDrag() }
        // The pattern belongs to the editing surface; reading stays on a plain background.
        .background(Color.editorBackground)
    }
}

enum MarkdownStyle {
    static let pagePadding: CGFloat = 16
    static let quoteInset: CGFloat = 13
    /// Quick Look's body size, and the preview's at the editor's default 13 pt. A proportional face looks
    /// smaller than the editor's monospaced one at the same size, and reading wants a little more.
    static let defaultBodySize: CGFloat = 15
    static let blockSpacing: CGFloat = 12
    static let nestedSpacing: CGFloat = 8

    /// The preview follows the editor's font size, so Zoom In/Out and Reset Font Size scale both.
    static func bodySize(editorFontSize: Double) -> CGFloat { CGFloat(editorFontSize) + 2 }
    /// Code is set at the editor's own size.
    static func codeSize(body: CGFloat) -> CGFloat { body - 2 }
    /// How much larger than at the 13 pt the fixed list metrics were drawn for.
    static func scale(body: CGFloat) -> CGFloat { body / 13 }

    static func headingSize(_ level: Int, body: CGFloat) -> CGFloat {
        let ratio: CGFloat = switch level {
        case 1: 1.75
        case 2: 1.45
        case 3: 1.2
        case 4: 1.05
        default: 1
        }
        return (body * ratio).rounded()
    }
}

extension EnvironmentValues {
    @Entry var markdownBodySize = MarkdownStyle.defaultBodySize
    @Entry var markdownListDepth = 0
    @Entry var markdownSecondaryText = false
}

/// One view per node kind; containers lay out their children recursively, so nesting needs no flags.
private struct MarkdownBlockView: View {
    let node: MarkdownNode
    let path: String
    @Environment(\.markdownHeadingRegistry) private var headings
    @Environment(\.markdownAvailableWidth) private var availableWidth
    @Environment(\.markdownBodySize) private var bodySize

    var body: some View {
        content.environment(\.markdownSelectionID, path)
    }

    @ViewBuilder private var content: some View {
        switch node {
        case .paragraph(let text):
            MarkdownInlineView(text: text, size: bodySize)
        case .heading(let level, let text):
            let size = MarkdownStyle.headingSize(level, body: bodySize)
            MarkdownInlineView(text: text, size: size, weight: .bold)
                .environment(\.markdownSecondaryText, level >= 6)
                .padding(.top, level <= 2 ? 4 : 0)
                // Zero-sized, so the anchor can never sit over the heading's text and take its clicks.
                .background(alignment: .topLeading) {
                    MarkdownHeadingAnchor(path: path, registry: headings).frame(width: 0, height: 0)
                }
        case .codeBlock(let language, let code):
            MarkdownCodeView(language: language, code: code)
        case .blockQuote(let children):
            MarkdownBlockStack(blocks: children, path: path)
                .environment(\.markdownAvailableWidth, max(1, availableWidth - MarkdownStyle.quoteInset))
                .environment(\.markdownSecondaryText, true)
                .foregroundStyle(.secondary)
                .padding(.leading, MarkdownStyle.quoteInset)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                }
        case .list(let list):
            MarkdownListView(list: list, path: path)
        case .table(let table):
            if MarkdownTableTextView.canShow(table) {
                ScrollView(.horizontal) { MarkdownTableTextView(table: table, size: bodySize, availableWidth: availableWidth, path: path) }
            } else {
                MarkdownTableGrid(table: table, path: path)
            }
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        case .html(let source):
            MarkdownTextView(text: MarkdownText.plain(source,
                font: .monospacedSystemFont(ofSize: MarkdownStyle.codeSize(body: bodySize), weight: .regular), secondary: true))
        }
    }
}

private struct MarkdownBlockStack: View {
    let blocks: [MarkdownNode]
    let path: String

    var body: some View {
        if blocks.count == 1 {
            MarkdownBlockView(node: blocks[0], path: "\(path).0")
        } else {
            VStack(alignment: .leading, spacing: MarkdownStyle.nestedSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, node in
                    MarkdownBlockView(node: node, path: "\(path).\(index)")
                }
            }
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let path: String
    @Environment(\.markdownListDepth) private var depth
    @Environment(\.markdownAvailableWidth) private var availableWidth
    @Environment(\.markdownBodySize) private var bodySize

    private static let spacing: CGFloat = 6

    var body: some View {
        let scale = MarkdownStyle.scale(body: bodySize)
        let markerWidth = (list.ordered
            ? CGFloat(String(list.items.map(\.ordinal).max() ?? 1).count + 1) * 8
            : 12) * scale
        let boxWidth = MarkdownTaskBox.width(body: bodySize)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                // What the marker column takes from the row, so the item's blocks get the exact rest.
                let leading = markerWidth + Self.spacing
                    + (item.task != nil && list.ordered ? boxWidth + Self.spacing : 0)
                HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                    // A task's box replaces the bullet; an ordered task keeps its number before the box.
                    if let done = item.task, !list.ordered {
                        MarkdownTaskBox(done: done).frame(width: markerWidth, alignment: .trailing)
                    } else {
                        Text(marker(item))
                            .font(.system(size: bodySize))
                            .monospacedDigit()
                            .frame(width: markerWidth, alignment: .trailing)
                    }
                    if let done = item.task, list.ordered { MarkdownTaskBox(done: done) }
                    MarkdownBlockStack(blocks: item.blocks, path: "\(path).\(index)")
                        .environment(\.markdownAvailableWidth, max(1, availableWidth - leading))
                        .opacity(item.task == true ? 0.55 : 1)
                }
            }
        }
        .environment(\.markdownListDepth, depth + 1)
    }

    private func marker(_ item: MarkdownList.Item) -> String {
        if list.ordered { return "\(item.ordinal)." }
        return ["•", "◦", "▪"][depth % 3]
    }
}

/// Read-only: the preview shows the state, the editor changes it.
private struct MarkdownTaskBox: View {
    /// The symbol's width at the body size, so a list knows what an ordered task's box takes.
    static func width(body: CGFloat) -> CGFloat { (16 * MarkdownStyle.scale(body: body)).rounded() }
    let done: Bool
    @Environment(\.markdownBodySize) private var bodySize

    var body: some View {
        Image(systemName: done ? "checkmark.square.fill" : "square")
            .font(.system(size: bodySize))
            .frame(width: Self.width(body: bodySize))
            .foregroundStyle(done ? Color.accent : Color.textSecondary)
            .accessibilityLabel(done ? String(localized: "Task done") : String(localized: "Task open"))
    }
}

/// The table as SwiftUI views, for one that holds a picture (see `MarkdownTableTextView`).
private struct MarkdownTableGrid: View {
    let table: MarkdownTable
    let path: String
    @Environment(\.markdownAvailableWidth) private var availableWidth
    @Environment(\.markdownBodySize) private var bodySize
    @State private var measure = MarkdownTableMeasure()
    private static let cellPadding: CGFloat = 10
    /// Keeps the border's stroke inside the scroll view.
    private static let borderInset: CGFloat = 1

    var body: some View {
        let widths = MarkdownTableLayout.widths(natural: measure.natural(table, size: bodySize),
            available: availableWidth - CGFloat(table.columns.count) * 2 * Self.cellPadding - 2 * Self.borderInset)
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow(alignment: .top) {
                    ForEach(table.columns.indices, id: \.self) { column in
                        cell(table.header[column], row: 0, column: column, width: widths[column], weight: .semibold)
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(table.columns.indices, id: \.self) { column in
                            cell(table.rows[row][column], row: row + 1, column: column, width: widths[column], weight: .regular)
                        }
                    }
                    if row < table.rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .padding(Self.borderInset)
        }
    }

    private func cell(_ text: AttributedString, row: Int, column: Int, width: CGFloat, weight: NSFont.Weight) -> some View {
        MarkdownInlineView(text: text, size: bodySize, weight: weight, alignment: textAlignment(table.columns[column]))
            .environment(\.markdownSelectionID, "\(path).r\(row).c\(column)")
            .environment(\.markdownAvailableWidth, width)
            .frame(width: width, alignment: alignment(table.columns[column]))
            .gridColumnAlignment(horizontalAlignment(table.columns[column]))
            .padding(.horizontal, Self.cellPadding)
            .padding(.vertical, 8)
    }

    private func horizontalAlignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ alignment: MarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    private func alignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Each column's one-line width, kept until the table changes, so resizing the window only
/// re-runs `MarkdownTableLayout` instead of measuring every cell again.
@MainActor private final class MarkdownTableMeasure {
    private var table: MarkdownTable?
    private var size: CGFloat = 0
    private var widths: [CGFloat] = []

    func natural(_ table: MarkdownTable, size: CGFloat) -> [CGFloat] {
        guard table != self.table || size != self.size else { return widths }
        self.table = table
        self.size = size
        widths = table.columns.indices.map { column in
            table.rows.reduce(MarkdownInlineView.naturalWidth(table.header[column], size: size, weight: .semibold)) {
                max($0, MarkdownInlineView.naturalWidth($1[column], size: size, weight: .regular))
            }
        }
        return widths
    }
}

private struct MarkdownInlineView: View {
    let text: AttributedString
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    var alignment: NSTextAlignment = .natural
    @Environment(\.markdownSecondaryText) private var secondary
    @Environment(\.markdownSelectionID) private var selectionID

    /// The widest part on one line: a text's longest line, or an image's requested width (the
    /// image placeholder's width when it names none).
    static func naturalWidth(_ text: AttributedString, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        MarkdownInline.parts(text).reduce(0) { widest, part in
            switch part {
            case .text(let value):
                max(widest, MarkdownTextView.naturalWidth(MarkdownText.attributed(value, style: .init(size: size, weight: weight))))
            case .image(let reference):
                max(widest, reference.dimensions.width.map(CGFloat.init) ?? 360)
            }
        }
    }

    var body: some View {
        let parts = MarkdownInline.parts(text)
        // Nearly every block is one run of text: no stack around it, one view fewer per block.
        if parts.count == 1, case .text(let value) = parts[0] {
            label(value, part: 0)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    switch part {
                    case .text(let value): label(value, part: index)
                    case .image(let reference): MarkdownImageView(reference: reference)
                    }
                }
            }
        }
    }

    private func label(_ value: AttributedString, part: Int) -> some View {
        MarkdownTextView(text: MarkdownText.attributed(value,
            style: .init(size: size, weight: weight, secondary: secondary, alignment: alignment)))
            .environment(\.markdownSelectionID, selectionID.map { "\($0).\(part)" })
    }
}
