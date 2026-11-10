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

/// Preview text is drawn by a light TextKit 1 view (`MarkdownLabelView`) rather than SwiftUI `Text`
/// or one NSTextView per block: a text view costs about a millisecond to make and attach, and a fast
/// scroll makes dozens per frame. The block the user presses becomes a real read-only NSTextView for
/// as long as it holds the selection, so selecting and copying work the same in every block, table
/// cells and headings included, and a drag that starts on text is never taken as a window-background
/// drag. Wrapping text takes the full proposed width, so a drag may start anywhere on its row.
struct MarkdownTextView: View {
    let text: NSAttributedString
    var wraps = true

    var body: some View {
        // SwiftUI does not ask a platform view for its baseline; list markers align to this one.
        Representable(text: text, wraps: wraps)
            .alignmentGuide(.firstTextBaseline) { _ in Self.firstBaseline(text) }
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

        func makeNSView(context: Context) -> MarkdownLabelView { MarkdownLabelView() }

        func updateNSView(_ view: MarkdownLabelView, context: Context) {
            view.openURL = context.environment.openURL
            view.wraps = wraps
            view.setContent(text)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownLabelView, context: Context) -> CGSize? {
            nsView.fittingSize(width: wraps ? proposal.width.flatMap { $0.isFinite ? $0 : nil } : nil)
        }
    }
}

/// Draws one block's text with its own small layout stack and measures with the same one. It holds
/// no selection: a press installs `MarkdownSelectableTextView` over it (same text, same width, so
/// the same line breaks) and hands it the event; the text view goes away when it loses focus.
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
    private var selectable: MarkdownSelectableTextView?

    /// A layout manager outside a text view draws `.link` its own way, so links are drawn as a plain
    /// color here and kept under this key; the text view gets the original string.
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
        removeSelectable()
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
        guard selectable == nil, storage.length > 0 else { return }
        layoutForBounds()
        let glyphs = layout.glyphRange(forBoundingRect: dirtyRect, in: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    override func resetCursorRects() {
        guard selectable == nil else { return }
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

    override func mouseDown(with event: NSEvent) { installSelectable().mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { installSelectable().rightMouseDown(with: event) }

    private func installSelectable() -> MarkdownSelectableTextView {
        if let selectable { return selectable }
        let view = MarkdownSelectableTextView()
        view.wraps = wraps
        view.openURL = openURL
        view.setContent(text)
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.onResign = { [weak self, weak view] in
            // Not inside the responder change itself.
            DispatchQueue.main.async { if let self, let view, self.selectable === view { self.removeSelectable() } }
        }
        addSubview(view)
        selectable = view
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(view)
        return view
    }

    private func removeSelectable() {
        guard let view = selectable else { return }
        selectable = nil
        if window?.firstResponder === view { window?.makeFirstResponder(nil) }
        view.removeFromSuperview()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

/// The real text view of the one block that holds the selection (see `MarkdownLabelView`).
final class MarkdownSelectableTextView: NSTextView, NSTextViewDelegate {
    var openURL: OpenURLAction?
    var wraps = true
    var onResign: (() -> Void)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        // Set after init, which makes the container track the (zero) frame. The width is managed here.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        // The default maximum is the initial (zero) frame, which would clamp the container to it.
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isAutomaticLinkDetectionEnabled = false
        selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func setContent(_ text: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Lay out at the width the label drew at; a zero frame is only AppKit's initial one.
        guard newSize.width > 0, let container = textContainer else { return }
        let width = wraps ? newSize.width : .greatestFiniteMagnitude
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
    }

    /// One selection at a time: leaving a block clears what was selected in it.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            onResign?()
        }
        return resigned
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { openURL?(url) }
        return true
    }
}
