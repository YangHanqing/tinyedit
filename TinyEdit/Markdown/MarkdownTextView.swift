import AppKit
import SwiftUI

/// Inline semantics become AppKit attributes here, the one place they turn visual.
enum MarkdownText {
    struct Style: Equatable {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        var secondary = false
        var alignment: NSTextAlignment = .natural
    }

    @MainActor static func attributed(_ text: AttributedString, style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        let color = style.secondary ? Theme.textSecondary : Theme.textPrimary
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: style.size * 0.92, weight: style.weight)
            } else {
                let strong = intent.contains(.stronglyEmphasized) && style.weight.rawValue < NSFont.Weight.bold.rawValue
                font = .systemFont(ofSize: style.size, weight: strong ? .bold : style.weight)
            }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.code) { attributes[.backgroundColor] = Theme.textSecondary.withAlphaComponent(0.15) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    @MainActor static func plain(_ text: String, font: NSFont, secondary: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font,
            .foregroundColor: secondary ? Theme.textSecondary : Theme.textPrimary])
    }
}

/// Lightweight, selectable preview text. The page's shared selection spans these views, while
/// each label measures and draws with one TextKit 1 stack, without per-block NSTextViews.
struct MarkdownTextView: View {
    let text: NSAttributedString
    var wraps = true
    @Environment(\.markdownSelection) private var selection
    @Environment(\.markdownSelectionID) private var selectionID

    var body: some View {
        // SwiftUI does not ask a platform view for its baseline; list markers align to this one.
        let baseline = Self.firstBaseline(text)
        return Representable(text: text, wraps: wraps, selection: selection, selectionID: selectionID)
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }

    @MainActor private static let baselineLayout = NSLayoutManager()
    @MainActor private static let probe = MarkdownLabelView()

    /// The unwrapped width the view itself measures, for sizing table columns before any view exists.
    @MainActor static func naturalWidth(_ text: NSAttributedString) -> CGFloat {
        probe.setContent(text)
        return probe.fittingSize(width: nil).width
    }

    @MainActor static func firstBaseline(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return 0 }
        return baselineLayout.defaultBaselineOffset(for: font)
    }

    private struct Representable: NSViewRepresentable {
        let text: NSAttributedString
        let wraps: Bool
        let selection: MarkdownSelection?
        let selectionID: String?

        func makeNSView(context: Context) -> MarkdownLabelView { MarkdownLabelView() }

        func updateNSView(_ view: MarkdownLabelView, context: Context) {
            view.openURL = context.environment.openURL
            view.wraps = wraps
            view.setContent(text)
            view.bindSelection(selection, id: selectionID)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownLabelView, context: Context) -> CGSize? {
            nsView.fittingSize(width: wraps ? proposal.width.flatMap { $0.isFinite ? $0 : nil } : nil)
        }
    }
}

/// One small layout stack for both drawing and measurement. Selection is painted behind its
/// visible glyphs; mouse events go to the page so lazy rows share one continuous selection.
final class MarkdownLabelView: NSView {
    var openURL: OpenURLAction?
    var wraps = true { didSet { if wraps != oldValue { contentChanged() } } }

    private var text = NSAttributedString()
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    private var hasLinks = false
    /// SwiftUI probes a few widths over and over (the proposal, unbounded, the last one again).
    private var sizes: [CGFloat: CGSize] = [:]
    private weak var selection: MarkdownSelection?
    private(set) var selectionID: String?
    private var selectedRange = NSRange(location: 0, length: 0)

    /// Draw links in the theme's color; keep the URL under a private key for hit testing.
    private static let linkKey = NSAttributedString.Key("TinyEdit.MarkdownLink")
    private static let unbounded: CGFloat = -1

    init() {
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { selection?.register(self) } else { selection?.unregister(self) }
    }

    func bindSelection(_ selection: MarkdownSelection?, id: String?) {
        if self.selection !== selection || selectionID != id {
            self.selection?.unregister(self)
            self.selection = selection
            selectionID = id
        }
        selection?.register(self)
    }

    func setSelection(_ range: NSRange) {
        guard range != selectedRange else { return }
        selectedRange = range
        needsDisplay = true
    }

    func setContent(_ text: NSAttributedString) {
        guard text !== self.text, !text.isEqual(to: self.text) else { return }
        self.text = text
        let drawn = NSMutableAttributedString(attributedString: text)
        hasLinks = false
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value else { return }
            hasLinks = true
            drawn.removeAttribute(.link, range: range)
            drawn.addAttributes([Self.linkKey: value, .foregroundColor: Theme.accent], range: range)
        }
        storage.setAttributedString(drawn)
        setAccessibilityValue(text.string)
        contentChanged()
    }

    private func contentChanged() {
        sizes.removeAll(keepingCapacity: true)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Width nil measures one unwrapped line per paragraph (code, the natural width of a table cell).
    func fittingSize(width: CGFloat?) -> CGSize {
        let key = width.map { max(1, $0) } ?? Self.unbounded
        if let size = sizes[key] { return size }
        let used = usedRect(width: width.map { max(1, $0) })
        let size = CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
        if sizes.count >= 8 { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = size
        return size
    }

    private func usedRect(width: CGFloat?) -> CGRect {
        let width = width ?? .greatestFiniteMagnitude
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container)
    }

    /// The layout at the width the view has now, whatever was measured last.
    private func layoutForBounds() {
        _ = usedRect(width: wraps ? max(1, bounds.width) : nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        needsDisplay = true
        if hasLinks { window?.invalidateCursorRects(for: self) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard storage.length > 0 else { return }
        layoutForBounds()
        let glyphs = layout.glyphRange(forBoundingRect: dirtyRect, in: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        if selectedRange.length > 0, NSMaxRange(selectedRange) <= storage.length {
            let selected = layout.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
            let visible = NSIntersectionRange(selected, glyphs)
            if visible.length > 0 {
                Theme.textSelection.setFill()
                layout.enumerateEnclosingRects(forGlyphRange: visible, withinSelectedGlyphRange: selected, in: container) { rect, _ in
                    rect.fill()
                }
            }
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
        guard hasLinks else { return }
        layoutForBounds()
        storage.enumerateAttribute(Self.linkKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    // MARK: Selection

    override func mouseDown(with event: NSEvent) {
        selection?.mouseDown(in: self, event: event)
    }
    override func mouseDragged(with event: NSEvent) { selection?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { selection?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) {
        if let selection { NSMenu.popUpContextMenu(selection.contextMenu(in: self, event: event), with: event, for: self) }
    }

    var verticalScrollView: NSScrollView? {
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
            parent = view.superview
        }
        return nil
    }

    func insertionIndex(at point: NSPoint) -> Int {
        guard storage.length > 0 else { return 0 }
        layoutForBounds()
        if point.y < 0 { return 0 }
        if point.y >= bounds.height { return storage.length }
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return storage.length }
        let composed = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
        return fraction > 0.5 ? NSMaxRange(composed) : composed.location
    }

    func selection(at index: Int, granularity: MarkdownSelectionGranularity) -> NSRange {
        guard storage.length > 0, granularity != .character else { return NSRange(location: index, length: 0) }
        let character = min(storage.length - 1, index)
        if granularity == .word { return storage.doubleClick(at: character) }
        return (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
    }

    func insertionPoint(at index: Int) -> (point: NSPoint, height: CGFloat) {
        layoutForBounds()
        guard storage.length > 0 else { return (.zero, 15) }
        let glyph = layout.glyphIndexForCharacter(at: min(index, storage.length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return (NSPoint(x: index == storage.length ? rect.maxX : rect.minX, y: line.midY), line.height)
    }

    func visualLine(at index: Int) -> NSRange {
        layoutForBounds()
        guard storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let glyph = layout.glyphIndexForCharacter(at: min(index, storage.length - 1))
        var glyphs = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        var range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if range.length > 0, (storage.string as NSString).character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return range
    }

    func link(at point: NSPoint) -> URL? {
        guard hasLinks, storage.length > 0 else { return nil }
        layoutForBounds()
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        let value = storage.attribute(Self.linkKey, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }
}
