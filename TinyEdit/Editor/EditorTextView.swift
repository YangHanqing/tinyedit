import AppKit

final class EditorTextView: NSTextView {
    /// Per-buffer undo manager. AppKit must not swap in the window's manager.
    weak var bufferUndoManager: UndoManager?
    var tabWidth = 4
    /// Called when the view enters a window so the host can reapply the configuration.
    var onMovedToWindow: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?

    /// File drops, with the character index under the pointer. They open tabs, or read the text out of a
    /// picture; they never insert a path or the file's bytes as text.
    var onFileDrop: (([URL], Int) -> Void)?

    /// Bracket `paste` and the paste-as variants. Drops insert text without calling these.
    var onPasteBegin: (() -> Void)?
    var onPasteEnd: (() -> Void)?
    /// Asked first by every paste variant. True when it handled the pasteboard itself (file references,
    /// a picture without text), so AppKit does not read it.
    var onPasteboard: ((NSPasteboard) -> Bool)?

    private func fileURLs(from pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        if !urls.isEmpty {
            onFileDrop?(urls, characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
            return true
        }
        return super.performDragOperation(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes.filter { $0 != .fileURL }
    }

    override func paste(_ sender: Any?) {
        onPasteBegin?()
        defer { onPasteEnd?() }
        if onPasteboard?(.general) == true { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        onPasteBegin?()
        defer { onPasteEnd?() }
        if onPasteboard?(.general) == true { return }
        super.pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        onPasteBegin?()
        defer { onPasteEnd?() }
        if onPasteboard?(.general) == true { return }
        super.pasteAsRichText(sender)
    }

    /// Text a paste produced without AppKit reading the pasteboard (file paths, text read from a picture),
    /// inserted like a paste: CR folded, one undo step, the caret after it.
    func insertPasted(_ text: String, replacing range: NSRange) {
        let string = LineEnding.normalizeToLF(text)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        if shouldChangeText(in: range, replacementString: string) {
            replaceCharacters(in: range, with: string)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
        }
        undoManager?.endUndoGrouping()
        scrollRangeToVisible(selectedRange())
    }

    /// The buffer is LF-only. Paste and text drops fold CR / CRLF through a private copy of the
    /// pasteboard, so AppKit still does the insert (undo, smart insert, drop point) and the user's
    /// pasteboard is never rewritten. Without this, a CRLF save writes "\r\r\n".
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let s = pboard.string(forType: .string), s.utf16.contains(0x0D) else {
            return super.readSelection(from: pboard, type: type)
        }
        let folded = NSPasteboard.withUniqueName()
        defer { folded.releaseGlobally() }
        folded.clearContents()
        folded.setString(LineEnding.normalizeToLF(s), forType: .string)
        return super.readSelection(from: folded, type: .string)
    }

    /// Committed text (services, IME commit, programmatic inserts) is folded the same way. Marked text is not.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(Self.foldingCR(string), replacementRange: replacementRange)
    }

    static func foldingCR(_ value: Any) -> Any {
        switch value {
        case let s as String where s.utf16.contains(0x0D): LineEnding.normalizeToLF(s)
        case let a as NSAttributedString where a.string.utf16.contains(0x0D): LineEnding.normalizeToLF(a.string)
        default: value
        }
    }

    override var undoManager: UndoManager? {
        get { bufferUndoManager ?? super.undoManager }
        set { bufferUndoManager = newValue }
    }

    /// Edit ▸ Undo / Redo send these up the responder chain, and in the SwiftUI window nothing above the
    /// text view answers them, so without these ⌘Z and ⇧⌘Z would do nothing. The text view runs its own (buffer's) manager.
    @objc func undo(_ sender: Any?) {
        guard let manager = undoManager, manager.canUndo else { return NSSound.beep() }
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let manager = undoManager, manager.canRedo else { return NSSound.beep() }
        manager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return isEditable && undoManager?.canUndo == true
        case #selector(redo(_:)): return isEditable && undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    /// The active buffer's indent style, resolved when a key is pressed. Nil means spaces of `tabWidth`.
    var indentStyle: (() -> IndentStyle)?
    /// The active buffer's language, read on Return and on clicks: Markdown continues task items, and
    /// Markdown and Plain Text flip a task's box when it is clicked. Nil leaves task lists alone.
    var taskLanguage: (() -> EditorLanguage)?

    /// The marked values of a JSON tab, in document order, read in the overlay pass. Empty draws no marks.
    var jsonValueMarks: (() -> [JSONValueMark])?
    /// A click on a value's mark (Preview, link or time), with the value's range.
    var onJSONMarkClick: ((NSRange) -> Void)?

    /// Language and the inline-calculation setting, read when the caret moves. Nil leaves the ghost off.
    var inlineCalculationContext: (() -> InlineCalculator.Context?)?

    private let inlineHintView = InlineHintView()
    private var inlineProposal: InlineCalculator.Proposal?
    private var inlineHintVisible = false
    private var inlineAnchor: (lineStart: Int, contentEnd: Int)?
    private var inlineDismissal: InlineDismissal?
    private var pendingInlineEdit: (NSRange, Int)?

    private let whitespaceMarkView = WhitespaceMarkView()
    private var overlayUpdatePending = false

    /// Current line, indent guides and invisibles, from Settings.
    var decorationOptions = EditorDecorationOptions() {
        didSet { if decorationOptions != oldValue { setNeedsOverlays() } }
    }
    /// Receives what the clip view paints beneath the text; set by the host.
    var onDecorationsChanged: ((EditorDecorations) -> Void)?
    private var lastDecorations = EditorDecorations()

    private var editedText: NSString? { textContentStorage?.textStorage?.mutableString }

    /// Typed Tab accepts a visible calculation ghost; otherwise it follows the buffer's indent style.
    /// Over a selection that spans lines it indents those lines instead of replacing them.
    override func insertTab(_ sender: Any?) {
        if acceptInlineHint() { return }
        let style = indentStyle?() ?? .spaces(tabWidth)
        let sel = selectedRange()
        guard let text = editedText else { return insertText("\t", replacementRange: sel) }
        if !hasMarkedText(), selectedRanges.count == 1, IndentEditing.selectionSpansLines(in: text, selection: sel) {
            apply(IndentEditing.indentLines(in: text, selection: sel, style: style, tabWidth: tabWidth))
            return
        }
        insertText(IndentEditing.tab(in: text, selection: sel, style: style, tabWidth: tabWidth), replacementRange: sel)
    }

    /// Shift-Tab removes one indent level from every line the selection touches.
    override func insertBacktab(_ sender: Any?) {
        guard let text = editedText, !hasMarkedText(), selectedRanges.count == 1 else { return }
        let style = indentStyle?() ?? .spaces(tabWidth)
        apply(IndentEditing.outdentLines(in: text, selection: selectedRange(), style: style, tabWidth: tabWidth))
    }

    /// Backspace inside space indentation deletes back to the previous indent stop.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if let text = editedText, !hasMarkedText(), selectedRanges.count == 1, sel.length == 0,
           let range = IndentEditing.softTabDeletion(in: text, caret: sel.location, style: indentStyle?() ?? .spaces(tabWidth)) {
            setSelectedRange(range)
        }
        super.deleteBackward(sender)
    }

    // MARK: Line commands

    /// Runs a line edit over the selection as one undo step. Beeps when there is nothing to do.
    private func performLineEdit(_ make: (NSString, NSRange) -> IndentEditing.LineEdits?) {
        guard let text = editedText, !hasMarkedText(), let change = make(text, selectedRange()), !change.edits.isEmpty else {
            NSSound.beep()
            return
        }
        apply(change)
        scrollRangeToVisible(NSRange(location: selectedRange().location, length: 0))
    }

    func duplicateLines() { performLineEdit { LineEditing.duplicate(in: $0, selection: $1) } }
    func moveLinesUp() { performLineEdit { LineEditing.moveUp(in: $0, selection: $1) } }
    func moveLinesDown() { performLineEdit { LineEditing.moveDown(in: $0, selection: $1) } }
    func deleteLines() { performLineEdit { LineEditing.deleteLines(in: $0, selection: $1) } }
    func joinLines() { performLineEdit { LineEditing.joinLines(in: $0, selection: $1) } }

    func toggleComment(_ syntax: LineEditing.CommentSyntax) {
        performLineEdit { LineEditing.toggleComment(in: $0, selection: $1, syntax: syntax) }
    }

    func toggleTask() { performLineEdit { TaskList.toggle(in: $0, selection: $1) } }

    // MARK: Task boxes

    /// A plain click on a task's box ticks or unticks it as one undo step. The selection stays where it was.
    /// A plain click on a JSON value's mark previews the picture, opens the link or copies the time.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            if let mark = valueMark(at: point) {
                window?.makeFirstResponder(self)
                onJSONMarkClick?(mark.valueRange)
                return
            }
            if flipTask(at: point) {
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The clickable value mark under `point`, in view coordinates, as last drawn. A color swatch is not one.
    func valueMark(at point: NSPoint) -> EditorDecorations.ValueMark? {
        lastDecorations.valueMarks.first { $0.isClickable && $0.rect.contains(point) }
    }

    /// Flips the box under `point`, in view coordinates. False when there is none.
    func flipTask(at point: NSPoint) -> Bool {
        guard let item = taskItem(at: point) else { return false }
        apply(IndentEditing.LineEdits(edits: [TaskList.flip(item)], selection: selectedRange()))
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let mark = valueMark(at: point)
        if mark != nil || taskItem(at: point) != nil { NSCursor.pointingHand.set() }
        if mark?.valueRange != lastDecorations.valueMarks.first(where: \.hovered)?.valueRange { setNeedsOverlays() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if lastDecorations.valueMarks.contains(where: \.hovered) { setNeedsOverlays() }
    }

    /// The task whose box is under `point`, in view coordinates. Lays out only the box's line.
    func taskItem(at point: NSPoint) -> TaskList.Item? {
        guard let language = taskLanguage?(), TaskList.supports(language), isEditable, !hasMarkedText(),
              let text = editedText, text.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound, index <= text.length else { return nil }
        let full = text.lineRange(for: NSRange(location: index, length: 0))
        let line = NSRange(location: full.location, length: lineContentEnd(text, full) - full.location)
        // Cheap checks first: the fence scan runs only when the pointer is on a box.
        guard let box = TaskList.item(in: text, line: line)?.box,
              let rect = segmentRect(box), rect.insetBy(dx: -2, dy: 0).contains(point) else { return nil }
        return TaskList.clickableItem(in: text, line: line, language: language)
    }

    /// The union of `range`'s segment frames, in view coordinates.
    func segmentRect(_ range: NSRange) -> NSRect? {
        guard let lm = textLayoutManager, let tr = textContentStorage?.textRange(for: range) else { return nil }
        var rect: NSRect?
        lm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
            rect = rect.map { $0.union(frame) } ?? frame
            return true
        }
        let origin = textContainerOrigin
        return rect?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Edits made on Save (trailing whitespace, final newline), as one undo step that keeps the selection.
    func applyEdits(_ edits: [IndentEditing.Edit]) {
        guard !edits.isEmpty else { return }
        apply(IndentEditing.LineEdits(edits: edits, selection: IndentEditing.mapped(selectedRange(), through: edits)))
    }

    /// Line edits as one undo step, applied back to front so earlier ranges stay valid.
    private func apply(_ change: IndentEditing.LineEdits) {
        guard !change.edits.isEmpty else { return }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        for edit in change.edits.reversed() where shouldChangeText(in: edit.range, replacementString: edit.string) {
            replaceCharacters(in: edit.range, with: edit.string)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(change.selection)
    }

    /// Escape dismisses a visible ghost before the delegate's Escape (the cards over the editor) sees it.
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)), inlineHintVisible {
            dismissInlineHint()
            return
        }
        super.doCommand(by: selector)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        pendingInlineEdit = (affectedCharRange, (replacementString as NSString?)?.length ?? 0)
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if !ok { pendingInlineEdit = nil }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        if let edit = pendingInlineEdit {
            pendingInlineEdit = nil
            if var dismissal = inlineDismissal {
                if dismissal.apply(edit: edit.0, newLength: edit.1) { inlineDismissal = dismissal }
                else { inlineDismissal = nil }
            }
        }
        refreshInlineCalculation()
        setNeedsOverlays()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsOverlays()
    }

    /// Always the inset: the text is left-to-right with no negative indents. AppKit's own getter lays out the
    /// whole document while the view resizes horizontally (word wrap off), and the ruler reads it on every draw.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutInlineHint()
        setNeedsOverlays()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // TextKit 2 inserts a view per line and would otherwise cover the ghost and the whitespace marks.
        guard subview !== inlineHintView, subview !== whitespaceMarkView else { return }
        if inlineHintVisible { addSubview(inlineHintView) }
        if whitespaceMarkView.superview === self { addSubview(whitespaceMarkView) }
    }

    /// Return keeps the current line's indentation, and continues a Markdown task list. Option-Return
    /// (`insertNewlineIgnoringFieldEditor`) does neither.
    override func insertNewline(_ sender: Any?) {
        guard let text = editedText else { return super.insertNewline(sender) }
        if let language = taskLanguage?(), TaskList.continuesOnReturn(language), !hasMarkedText(), selectedRanges.count == 1,
           let edit = TaskList.newline(in: text, selection: selectedRange()) {
            insertText(edit.string, replacementRange: edit.range)
            return
        }
        let edit = IndentEditing.newline(in: text, selection: selectedRange())
        insertText(edit.string, replacementRange: edit.range)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        inlineHintView.needsDisplay = true
        whitespaceMarkView.needsDisplay = true
        onAppearanceChanged?()
    }

    // MARK: Overlays: whitespace marks above the text, decorations beneath it

    /// Coalesces selection, edit, resize and scroll changes into one pass after layout has settled.
    func setNeedsOverlays() {
        guard !overlayUpdatePending else { return }
        overlayUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayUpdatePending = false
            self.updateOverlays()
        }
    }

    func updateOverlays() {
        let visible = visibleRect
        let decorations = window == nil ? EditorDecorations() : decorations(in: visible)
        if decorations != lastDecorations {
            lastDecorations = decorations
            onDecorationsChanged?(decorations)
        }
        let marks = window == nil ? [] : whitespaceMarks(in: visible, everywhere: decorationOptions.invisibles)
        guard !marks.isEmpty else {
            whitespaceMarkView.marks = []
            whitespaceMarkView.removeFromSuperview()
            return
        }
        whitespaceMarkView.drawingFont = font ?? EditorConfiguration.font(size: 13)
        if whitespaceMarkView.frame != visible {
            whitespaceMarkView.frame = visible
            whitespaceMarkView.needsDisplay = true
        }
        whitespaceMarkView.marks = marks
        if whitespaceMarkView.superview !== self { addSubview(whitespaceMarkView) }
    }

    var currentDecorations: EditorDecorations { lastDecorations }

    var visibleWhitespaceMarks: [WhitespaceMark] { whitespaceMarkView.superview === self ? whitespaceMarkView.marks : [] }

    // MARK: Inline calculation

    /// Drops the ghost and its dismissal. Called when the visible buffer changes.
    func clearInlineHint() {
        inlineProposal = nil
        inlineDismissal = nil
        inlineAnchor = nil
        pendingInlineEdit = nil
        hideInlineHint()
    }

    func refreshInlineCalculation() {
        guard let text = editedText, let context = inlineCalculationContext?() else {
            inlineProposal = nil
            hideInlineHint()
            return
        }
        if isComposing() {
            inlineProposal = nil
            hideInlineHint()
            return
        }
        let location = min(max(selectedRange().location, 0), text.length)
        guard InlineCalculator.isEligible(context, text: text, index: location) else {
            inlineProposal = nil
            hideInlineHint()
            return
        }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let contentEnd = lineContentEnd(text, line)
        // Far past `proposal`'s 200-character limit. Skips copying and counting a huge line on every caret move.
        guard contentEnd - line.location <= 10_000 else {
            inlineProposal = nil
            hideInlineHint()
            return
        }
        let content = text.substring(with: NSRange(location: line.location, length: contentEnd - line.location))
        let key = content.trimmingCharacters(in: .whitespaces)
        if let dismissal = inlineDismissal {
            if dismissal.start == line.location, dismissal.key == key {
                inlineProposal = nil
                hideInlineHint()
                return
            }
            if dismissal.start == line.location { inlineDismissal = nil }
        }
        guard let proposal = InlineCalculator.proposal(forLine: content) else {
            inlineProposal = nil
            hideInlineHint()
            return
        }
        inlineProposal = proposal
        inlineAnchor = (line.location, contentEnd)
        layoutInlineHint()
    }

    func layoutInlineHint() {
        guard let proposal = inlineProposal, let anchor = inlineAnchor, bounds.width > 1,
              let rect = endOfLineRect(anchor.contentEnd) else {
            hideInlineHint()
            return
        }
        let drawingFont = font ?? EditorConfiguration.font(size: 13)
        let ghost = NSAttributedString(string: proposal.ghost, attributes: [.font: drawingFont])
        let size = ghost.size()
        let width = ceil(size.width) + 1
        let height = max(rect.height, ceil(size.height))
        let x = rect.maxX
        if x < 0 || x + width > bounds.width - 2 {
            hideInlineHint()
            return
        }
        inlineHintView.drawingFont = drawingFont
        inlineHintView.string = proposal.ghost
        inlineHintView.frame = NSRect(x: x, y: rect.minY + (rect.height - height) / 2, width: width, height: height)
        inlineHintView.needsDisplay = true
        if inlineHintView.superview !== self {
            addSubview(inlineHintView)
        }
        inlineHintView.isHidden = false
        inlineHintVisible = true
    }

    private func acceptInlineHint() -> Bool {
        guard inlineHintVisible, !isComposing(), let text = editedText else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let line = text.lineRange(for: sel)
        let contentEnd = lineContentEnd(text, line)
        guard sel.location == contentEnd else { return false }
        let content = text.substring(with: NSRange(location: line.location, length: contentEnd - line.location))
        guard let proposal = InlineCalculator.proposal(forLine: content) else { return false }
        let replacement: (NSRange, String)
        switch proposal.edit {
        case .append(let string):
            replacement = (NSRange(location: contentEnd, length: 0), string)
        case .replace(let range, let string):
            let absolute = NSRange(location: line.location + range.location, length: range.length)
            guard absolute.location >= line.location, NSMaxRange(absolute) <= contentEnd else { return false }
            replacement = (absolute, string)
        }
        breakUndoCoalescing()
        insertText(replacement.1, replacementRange: replacement.0)
        return true
    }

    private func dismissInlineHint() {
        guard inlineHintVisible, let text = editedText, let anchor = inlineAnchor else { return }
        let content = text.substring(with: NSRange(location: anchor.lineStart, length: anchor.contentEnd - anchor.lineStart))
        inlineDismissal = InlineDismissal(start: anchor.lineStart,
                                          length: anchor.contentEnd - anchor.lineStart,
                                          key: content.trimmingCharacters(in: .whitespaces))
        inlineProposal = nil
        hideInlineHint()
    }

    private func hideInlineHint() {
        inlineHintVisible = false
        inlineHintView.isHidden = true
        inlineHintView.removeFromSuperview()
    }

    private func lineContentEnd(_ text: NSString, _ line: NSRange) -> Int {
        var end = NSMaxRange(line)
        if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        return end
    }

    /// Rectangle of the caret at `utf16`, in text-view coordinates. Lays out only the fragment that holds it.
    private func endOfLineRect(_ utf16: Int) -> NSRect? {
        guard let lm = textLayoutManager, let cs = textContentStorage, let text = editedText, text.length > 0 else { return nil }
        let doc = cs.documentRange.location
        let clamped = min(max(utf16, 0), text.length)
        guard let probeLoc = cs.location(doc, offsetBy: min(clamped, text.length - 1)) else { return nil }
        var fragment: NSTextLayoutFragment?
        lm.enumerateTextLayoutFragments(from: probeLoc, options: [.ensuresLayout]) { frag in
            fragment = frag
            return false
        }
        guard let fragment else { return nil }
        let fragStart = cs.offset(from: doc, to: fragment.rangeInElement.location)
        for line in fragment.textLineFragments {
            let absStart = fragStart + line.characterRange.location
            let absEnd = absStart + line.characterRange.length
            if clamped < absStart || clamped > absEnd { continue }
            // `locationForCharacter` takes an index into the paragraph (`line.attributedString`), not into
            // this line, and returns x from this line's start. A line-relative index lands wrong on wrapped lines.
            let point = line.locationForCharacter(at: clamped - fragStart)
            let origin = textContainerOrigin
            let x = origin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + point.x
            let y = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
            return NSRect(x: x, y: y, width: 0, height: line.typographicBounds.height)
        }
        return nil
    }

    /// A zero-length range at the caret is not composition. `markedRange()` reports that
    /// (`{caret, 0}`) when no input context is active, instead of `{NSNotFound, 0}`.
    private func isComposing() -> Bool {
        hasMarkedText()
    }
}

/// Escape dismissal for one line, moved through edits the way a single change marker is.
private struct InlineDismissal {
    var start: Int
    var length: Int
    var key: String

    mutating func apply(edit: NSRange, newLength: Int) -> Bool {
        let oldLen = edit.length
        let delta = newLength - oldLen
        let oldEnd = edit.location + oldLen
        let lineEnd = start + length
        if oldEnd < start || (oldEnd == start && oldLen > 0) {
            start += delta
            return start >= 0
        }
        if edit.location > lineEnd { return true }
        if edit.location < start || oldEnd > lineEnd { return false }
        length += delta
        return length >= 0
    }
}

/// Ghost text at the end of the cursor line. Not in the text storage, so it cannot be copied, undone, or saved.
private final class InlineHintView: NSView {
    var drawingFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var string = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: string, attributes: [
            .font: drawingFont,
            .foregroundColor: Theme.textTertiary,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: 0, y: max(0, (bounds.height - size.height) / 2)))
    }
}
