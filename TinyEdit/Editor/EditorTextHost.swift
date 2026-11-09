import AppKit

/// Owns the one NSTextView / NSTextLayoutManager / NSTextContainer for the window.
/// Tab switch moves the layout manager to another buffer's content storage; inactive
/// tabs are not extra view trees and are never copied into SwiftUI state.
@MainActor
final class EditorTextHost: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let backgroundView = EditorBackgroundClipView()
    let textView: EditorTextView
    let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer
    private let placeholder = NSTextContentStorage()

    private(set) weak var activeStore: BufferTextStore?
    /// Bumped on every tab swap. The swap leaves the layout manager without rendering attributes.
    private(set) var contentSwaps = 0
    private var settings = EditorSettings()

    var onSelectionChange: ((BufferTextStore) -> Void)?
    var onFileDrop: (([URL], Int) -> Void)? {
        didSet { textView.onFileDrop = onFileDrop }
    }
    /// Escape in the text view. Return true when the command was consumed.
    var onEscape: (() -> Bool)?
    private(set) var ruler: LineNumberRuler?
    private var scrollObserver: NSObjectProtocol?
    /// Fires when the visible range changes (used for windowed highlighting of large files).
    var onScroll: (() -> Void)?

    override init() {
        placeholder.textStorage = NSTextStorage()
        placeholder.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        self.container = container
        textView = EditorTextView(frame: .zero, textContainer: container)
        super.init()

        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.onMovedToWindow = { [weak self] in
            guard let self else { return }
            EditorConfiguration.apply(self.settings, to: self.textView)
            self.textView.refreshInlineCalculation()
        }
        textView.onAppearanceChanged = { [weak self] in
            guard let self, let store = self.activeStore else { return }
            // Token colors are dynamic, but TextKit 2 caches drawn lines: re-lay out and redraw them.
            self.layoutManager.invalidateLayout(for: store.contentStorage.documentRange)
            self.redrawVisibleText()
            self.ruler?.needsDisplay = true
            self.textView.layoutInlineHint()
        }

        textView.onDecorationsChanged = { [weak self] in self?.backgroundView.decorations = $0 }
        scrollView.contentView = backgroundView
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true   // legacy (always-visible) scrollers appear only when the content overflows
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false   // never let the transparent title bar push the ruler or text under the tab row
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.clipsToBounds = true
        applyWrap(settings.wordWrap)

        let ruler = LineNumberRuler(scrollView: scrollView, host: self)
        self.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = settings.showLineNumbers

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.textView.setNeedsOverlays()
                self?.onScroll?()
            }
        }
    }

    // MARK: Tab swap

    func activate(_ store: BufferTextStore, settings: EditorSettings) {
        self.settings = settings
        guard activeStore !== store else { return }
        textView.clearInlineHint()
        if let old = activeStore { old.viewState = captureViewState() }

        layoutManager.replace(store.contentStorage)
        activeStore = store
        contentSwaps &+= 1
        // The swap alone does not resize the text view: it kept the previous buffer's size, and with it
        // scrollers for an empty tab, until something else laid out the text.
        textView.needsLayout = true
        textView.bufferUndoManager = store.undoManager
        EditorConfiguration.apply(settings, to: textView)
        applyWrap(settings.wordWrap)

        let length = store.length
        let sel = store.viewState.selection
        let loc = min(sel.location, length)
        textView.setSelectedRange(NSRange(location: loc, length: min(sel.length, length - loc)))
        let fraction = store.viewState.scrollFraction
        DispatchQueue.main.async { [weak self] in self?.restoreScroll(fraction) }
        onSelectionChange?(store)
        refreshRuler()
        textView.refreshInlineCalculation()
    }

    /// TextKit 2 draws each on-screen line into its own cached subview and does not redraw it when
    /// rendering attributes change (neither `needsDisplay` on the text view nor `invalidateLayout`
    /// reaches those subviews). Without this, new colors show only on lines redrawn for another reason.
    /// Lines scrolled in later get fresh views, so marking the current subtree is enough.
    func redrawVisibleText() {
        func mark(_ v: NSView) {
            v.needsDisplay = true
            v.subviews.forEach(mark)
        }
        mark(textView)
    }

    func refreshRuler() {
        ruler?.update(fontSize: settings.fontSize, lineCount: activeStore?.lineIndex?.lineCount ?? 1)
    }

    func apply(settings new: EditorSettings, stores: [BufferTextStore]) {
        guard new != settings else { return }
        let fontChanged = new.fontSize != settings.fontSize || new.tabWidth != settings.tabWidth
        let wrapChanged = new.wordWrap != settings.wordWrap
        // Not `scrollRangeToVisible`: its caret rect walks the caret line's CoreText offsets, which
        // blocked for minutes on a 2 MB single-line file. The top visible line stays put instead.
        let anchor = wrapChanged ? topVisibleOffset() : nil
        settings = new
        backgroundView.pattern = new.backgroundPattern
        if fontChanged { for s in stores { s.applyBaseAttributes(new) } }
        EditorConfiguration.apply(new, to: textView)
        applyWrap(new.wordWrap)
        if let anchor {
            // The first scroll lands on estimated heights; laying out that viewport makes them real.
            scroll(toOffset: anchor)
            textView.layoutSubtreeIfNeeded()
            scroll(toOffset: anchor)
        }
        scrollView.rulersVisible = new.showLineNumbers
        refreshRuler()
        textView.refreshInlineCalculation()
    }

    /// Takes focus instead of the text view when it returns true (a large-file tab is up).
    var focusOverride: (() -> Bool)?

    func focus() {
        if focusOverride?() == true { return }
        guard let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    /// Copy of live selection and scroll into the active store's view state.
    @discardableResult
    func captureViewState() -> BufferTextStore.ViewState {
        let state = BufferTextStore.ViewState(selection: textView.selectedRange(),
                                              scrollFraction: currentScrollFraction())
        activeStore?.viewState = state
        return state
    }

    // MARK: Layout

    /// Container width while word wrap is off: about 2,000 columns at the default size. Finite on purpose.
    /// AppKit's content-height estimate and caret rects walk a CoreText line's caret offsets from its
    /// start, so on one unbounded line their cost grows with the square of its length: a 2 MB single-line
    /// file blocked for minutes on every layout. Longer lines wrap at this width instead.
    static let unwrappedLineWidth: CGFloat = 16_000

    func applyWrap(_ wrap: Bool) {
        if wrap {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
            container.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scroll(toY: scrollView.contentView.bounds.origin.y)   // drop any offset left from unwrapped mode
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: Self.unwrappedLineWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
    }

    private func currentScrollFraction() -> Double {
        let visible = scrollView.contentView.bounds
        let docHeight = textView.frame.height
        return min(max(visible.origin.y / max(docHeight - visible.height, 1), 0), 1)
    }

    private func restoreScroll(_ fraction: Double) {
        textView.layoutSubtreeIfNeeded()   // the frame height below must be the new buffer's
        let visible = scrollView.contentView.bounds
        let maxY = max(textView.frame.height - visible.height, 0)
        scroll(toY: fraction * maxY)
    }

    /// UTF-16 offset of the first character on the top visible line, from layout that is already on screen.
    private func topVisibleOffset() -> Int? {
        guard let store = activeStore, store.length > 0 else { return nil }
        let cs = store.contentStorage
        let y = max(scrollView.contentView.bounds.minY - textView.textContainerOrigin.y, 0)
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return nil }
        let start = cs.offset(from: cs.documentRange.location, to: fragment.rangeInElement.location)
        let lineY = y - fragment.layoutFragmentFrame.minY
        let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > lineY }
        return start + (line?.characterRange.location ?? 0)
    }

    /// Puts the line holding `offset` at the top. Lays out only that paragraph; the heights above it stay
    /// estimates, so the result is exact only once the viewport there has been laid out.
    private func scroll(toOffset offset: Int) {
        guard let store = activeStore else { return }
        let cs = store.contentStorage
        guard let location = cs.location(cs.documentRange.location, offsetBy: min(offset, store.length)),
              let paragraph = layoutManager.textLayoutFragment(for: location) else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: paragraph.rangeInElement.location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let inFragment = offset - cs.offset(from: cs.documentRange.location, to: fragment.rangeInElement.location)
        let line = fragment.textLineFragments.last { $0.characterRange.location <= inFragment }
        scroll(toY: fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0) + textView.textContainerOrigin.y)
    }

    /// Brings the line holding `offset` to the upper third of the view, unless it is already well inside it.
    func reveal(offset: Int) {
        let clip = scrollView.contentView
        let before = clip.bounds
        scroll(toOffset: offset)
        let lineTop = clip.bounds.minY
        let third = before.height / 3
        if lineTop >= before.minY + 20, lineTop <= before.maxY - third {
            scroll(toY: before.minY)   // it was on screen: stay put
        } else {
            scroll(toY: max(lineTop - third, 0))
        }
    }

    /// Scrolls to `y` at the leftmost position. That is not x = 0: while line numbers show, the ruler
    /// insets the clip view and the leftmost origin is negative, so x = 0 slid the text under the ruler
    /// and left a horizontal offset that wrapped text could be scrolled by, with no scroller to show it.
    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin = NSPoint(x: -clip.contentInsets.left, y: y)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        return onEscape?() ?? false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let store = activeStore else { return }
        store.viewState.selection = textView.selectedRange()
        onSelectionChange?(store)
        textView.refreshInlineCalculation()
    }
}
