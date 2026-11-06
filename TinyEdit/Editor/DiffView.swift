import AppKit
import SwiftUI

/// Compare With: the unified diff shown over the editor slot. Read-only; Done or Escape closes it and the
/// editor underneath is exactly as it was.
struct DiffView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let diff = appState.diff {
            VStack(spacing: 0) {
                DiffHeader(diff: diff)
                ThemeDivider()
                content(diff)
            }
            .background(Color.editorBackground)
            .background {
                Button("") { appState.closeDiff() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func content(_ diff: DiffSession) -> some View {
        if let result = diff.result {
            if result.isIdentical || result.changes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.success)
                    Text("No Differences")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(result.isIdentical ? String(localized: "The two texts are identical.") : diff.notes.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                    if result.isIdentical, !diff.notes.isEmpty {
                        Text(diff.notes.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextRepresentable(diffID: diff.id, result: result, current: diff.current,
                                      scrollToken: diff.scrollToken, fontSize: appState.settings.fontSize,
                                      onClose: { appState.closeDiff() }, onStep: { appState.stepDiff($0) })
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Comparing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DiffHeader: View {
    @Environment(AppState.self) private var appState
    let diff: DiffSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accent)
            side(diff.old, sign: "−", color: .changeDeleted)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            side(diff.new, sign: "+", color: .changeAdded)
            if let note = diff.notes.first, diff.result?.changes.isEmpty == false {
                Text(note)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .toolTip(diff.notes.joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            if diff.stale {
                Text("Edited since comparing")
                    .foregroundStyle(Color.warning)
                    .lineLimit(1)
                    .fixedSize()
                CardButton("Refresh", help: String(localized: "Compare the current text again"), prominent: false) {
                    appState.refreshDiff()
                }
            }
            if let result = diff.result, !result.changes.isEmpty {
                summary(result)
                IconButton(systemName: "arrow.up", help: String(localized: "Previous Change") + "  ⌥⌘↑") { appState.stepDiff(-1) }
                IconButton(systemName: "arrow.down", help: String(localized: "Next Change") + "  ⌥⌘↓") { appState.stepDiff(1) }
            }
            CardButton("Done", help: String(localized: "Close the comparison (Esc)"), prominent: true) { appState.closeDiff() }
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(Color.chromeBackground)
    }

    private func side(_ side: DiffSide, sign: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: sign)
                .font(.system(size: 12, weight: .bold).monospaced())
                .foregroundStyle(color)
            Text(verbatim: side.title)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let dir = side.directory {
                Text(verbatim: TitlePathFormatting.abbreviate(directory: dir, home: TitlePathFormatting.userHome))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if side.fromDisk {
                Text("On Disk")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.tabHoverBackground, in: Capsule())
                    .fixedSize()
            }
        }
        .toolTip(side.directory.map { ($0 as NSString).appendingPathComponent(side.title) } ?? side.title)
    }

    private func summary(_ result: UnifiedDiff) -> some View {
        HStack(spacing: 6) {
            Text(String(localized: "Change \(diff.current + 1) of \(result.changes.count)"))
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
            Text(verbatim: "+\(result.added)")
                .foregroundStyle(Color.changeAdded)
                .monospacedDigit()
            Text(verbatim: "−\(result.removed)")
                .foregroundStyle(Color.changeDeleted)
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Text

private struct DiffTextRepresentable: NSViewRepresentable {
    let diffID: UUID
    let result: UnifiedDiff
    let current: Int
    let scrollToken: Int
    let fontSize: Double
    let onClose: () -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        let text = DiffTextView()
        text.autoresizingMask = [.width]
        scroll.documentView = text
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? DiffTextView else { return }
        text.onClose = onClose
        text.onStep = onStep
        let rebuilt = text.show(diffID: diffID, result: result, fontSize: fontSize)
        text.current = result.changes.indices.contains(current) ? current : 0
        if rebuilt || text.scrolledToken != scrollToken {
            text.scrolledToken = scrollToken
            DispatchQueue.main.async { text.scrollToCurrentChange() }
        }
        text.needsDisplay = true
    }
}

/// A read-only TextKit 1 text view of the diff rows. Row backgrounds, line numbers and +/− signs are drawn in
/// `drawBackground`, outside the text, so a copy holds only the lines themselves.
final class DiffTextView: NSTextView {
    var onClose: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    var current = 0
    var scrolledToken = -1

    private var shownID: UUID?
    private var shownFontSize = 0.0
    private(set) var rows: [DiffLine] = []
    private var changes: [Range<Int>] = []
    /// UTF-16 offset where each row starts.
    private var rowStarts: [Int] = []
    private var gutterWidth: CGFloat = 0
    private var columnWidth: CGFloat = 0
    private var rowFont = EditorConfiguration.font(size: EditorSettings.defaultFontSize)

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = true
        backgroundColor = Theme.editorBackground
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 0, height: 8)
        selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        setAccessibilityLabel(String(localized: "Differences"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var textContainerOrigin: NSPoint { NSPoint(x: gutterWidth, y: textContainerInset.height) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(newSize.width - gutterWidth - 12, 40)
        if let container = textContainer, abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    /// Fills the view with a diff. False when it already shows this one at this size.
    @discardableResult
    func show(diffID: UUID, result: UnifiedDiff, fontSize: Double) -> Bool {
        guard shownID != diffID || shownFontSize != fontSize else { return false }
        shownID = diffID
        shownFontSize = fontSize
        rows = result.lines
        changes = result.changes
        rowFont = EditorConfiguration.font(size: fontSize)

        let digits = max(String(rows.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }).count, 2)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: rowFont]).width
        columnWidth = CGFloat(digits) * digitWidth + 10
        gutterWidth = 2 * columnWidth + digitWidth + 16

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let base: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: Theme.textPrimary, .paragraphStyle: paragraph]
        let gapAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(fontSize - 2, 9)),
                                                            .foregroundColor: Theme.textTertiary, .paragraphStyle: paragraph]
        let out = NSMutableAttributedString()
        rowStarts = []
        rowStarts.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            rowStarts.append(out.length)
            if row.kind == .gap {
                out.append(NSAttributedString(string: String(localized: "⋯ \(row.hidden) unchanged lines"), attributes: gapAttributes))
            } else {
                let start = out.length
                out.append(NSAttributedString(string: row.text, attributes: base))
                if let changed = row.changed {
                    let color = row.kind == .added ? Theme.diffAddedHighlight : Theme.diffRemovedHighlight
                    out.addAttribute(.backgroundColor, value: color,
                                     range: NSRange(location: start + changed.location, length: changed.length))
                }
            }
            if i < rows.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        textStorage?.setAttributedString(out)
        setSelectedRange(NSRange(location: 0, length: 0))
        setFrameSize(frame.size)
        return true
    }

    func scrollToCurrentChange() {
        guard changes.indices.contains(current), let layout = layoutManager, let clip = enclosingScrollView?.contentView else { return }
        let rowIndex = changes[current].lowerBound
        let charRange = NSRange(location: rowStarts[rowIndex], length: 0)
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(rowStarts[rowIndex] + 1, textStorage?.length ?? 0)))
        let glyphs = layout.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let rect = layout.lineFragmentRect(forGlyphAt: min(glyphs.location, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
        // A few context rows stay above the change.
        let y = max(rect.minY + textContainerOrigin.y - 3 * rowFont.boundingRectForFont.height, 0)
        let maxY = max(frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    private func row(at charIndex: Int) -> Int {
        var lo = 0, hi = rowStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowStarts[mid] <= charIndex { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !rows.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let currentRows = changes.indices.contains(current) ? changes[current] : 0..<0
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: Theme.gutterText]

        layout.enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, glyphRange, _ in
            let charIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            let r = row(at: charIndex)
            let line = rows[r]
            let band = NSRect(x: 0, y: fragment.minY + origin.y, width: bounds.width, height: fragment.height)
            switch line.kind {
            case .added: Theme.diffAddedBackground.setFill(); band.fill()
            case .removed: Theme.diffRemovedBackground.setFill(); band.fill()
            case .gap: Theme.chromeBackground.setFill(); band.fill()
            case .context: break
            }
            if currentRows.contains(r) {
                Theme.accent.setFill()
                NSRect(x: 0, y: band.minY, width: 3, height: band.height).fill()
            }
            guard charIndex == rowStarts[r], line.kind != .gap else { return }
            func draw(_ s: String, rightEdge: CGFloat, color: NSColor? = nil) {
                var attributes = numberAttributes
                if let color { attributes[.foregroundColor] = color }
                let size = (s as NSString).size(withAttributes: attributes)
                (s as NSString).draw(at: NSPoint(x: rightEdge - size.width, y: band.minY + (fragment.height - size.height) / 2),
                                     withAttributes: attributes)
            }
            if let n = line.oldNumber { draw(String(n), rightEdge: columnWidth) }
            if let n = line.newNumber { draw(String(n), rightEdge: 2 * columnWidth) }
            switch line.kind {
            case .added: draw("+", rightEdge: gutterWidth - 6, color: Theme.changeAdded)
            case .removed: draw("−", rightEdge: gutterWidth - 6, color: Theme.changeDeleted)
            default: break
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.command, .option]), let key = event.specialKey {
            if key == .downArrow { return onStep(1) }
            if key == .upArrow { return onStep(-1) }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onClose() }
}
