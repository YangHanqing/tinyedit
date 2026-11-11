import AppKit
import SwiftUI

/// Reading-order text and leaf ranges, independent of which lazy rows currently exist. Prepared
/// off-main once per document revision. The NSString is copied to an immutable value before it is
/// shared; neither it nor the range dictionary is ever mutated afterwards.
struct MarkdownSelectionDocument: @unchecked Sendable {
    let text: NSString
    let ranges: [String: NSRange]

    init(_ blocks: [MarkdownNode]) {
        let builder = Builder()
        builder.blocks(blocks, prefix: "")
        text = builder.text.copy() as! NSString
        ranges = builder.ranges
    }

    private final class Builder {
        let text = NSMutableString(capacity: 0)
        var ranges: [String: NSRange] = [:]

        func blocks(_ nodes: [MarkdownNode], prefix: String) {
            for (index, node) in nodes.enumerated() {
                if Task.isCancelled { return }
                if index > 0 { text.append("\n\n") }
                block(node, path: "\(prefix)\(index)")
            }
        }

        func leaf(_ value: String, id: String) {
            let start = text.length
            text.append(value)
            ranges[id] = NSRange(location: start, length: text.length - start)
        }

        func inline(_ value: AttributedString, path: String) {
            for (index, part) in MarkdownInline.parts(value).enumerated() {
                if index > 0 { text.append("\n") }
                switch part {
                case .text(let value): leaf(String(value.characters), id: "\(path).\(index)")
                case .image(let image): text.append(image.alt == "\u{fffc}" ? "" : image.alt)
                }
            }
        }

        func block(_ node: MarkdownNode, path: String) {
            switch node {
            case .paragraph(let value), .heading(_, let value): inline(value, path: path)
            case .codeBlock(_, let code), .html(let code): leaf(code, id: path)
            case .blockQuote(let nodes): blocks(nodes, prefix: path + ".")
            case .list(let list):
                for (index, item) in list.items.enumerated() {
                    if index > 0 { text.append("\n") }
                    if list.ordered { text.append("\(item.ordinal). ") }
                    else if item.task == nil { text.append("• ") }
                    if let done = item.task { text.append(done ? "[x] " : "[ ] ") }
                    blocks(item.blocks, prefix: "\(path).\(index).")
                }
            case .table(let table):
                for (row, cells) in ([table.header] + table.rows).enumerated() {
                    if row > 0 { text.append("\n") }
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { text.append("\t") }
                        inline(cell, path: "\(path).r\(row).c\(column)")
                    }
                }
            case .thematicBreak: break
            }
        }
    }
}

enum MarkdownSelectionGranularity { case character, word, paragraph }

extension EnvironmentValues {
    @Entry var markdownSelection: MarkdownSelection?
    @Entry var markdownSelectionID: String?
}

/// One selection per page. Dragging touches only attached labels, without observable state,
/// attributed-string changes, text-view creation, or any SwiftUI layout invalidation.
@MainActor final class MarkdownSelection {
    private struct Label { weak var view: MarkdownLabelView? }
    private var labels: [ObjectIdentifier: Label] = [:]
    private var blocks: [MarkdownNode] = []
    private var identity: AnyHashable?
    private var document: MarkdownSelectionDocument?
    private var indexing: Task<MarkdownSelectionDocument?, Never>?
    private var revision = 0
    private var navigationText: NSAttributedString?
    weak var responder: MarkdownSelectionView?
    private(set) var range = NSRange(location: 0, length: 0)
    private var anchor = NSRange(location: 0, length: 0)
    private var head = 0
    private var granularity: MarkdownSelectionGranularity = .character
    private var dragStart: NSPoint?
    private var dragPoint = NSPoint.zero
    private var dragged = false
    private var pendingLink: (() -> Void)?
    private weak var dragScroll: NSScrollView?
    private var scrollTimer: Timer?

    func setDocument(_ blocks: [MarkdownNode], identity: AnyHashable?) {
        guard identity != self.identity || blocks != self.blocks else { return }
        endDrag()
        setRange(NSRange(location: 0, length: 0))
        self.blocks = blocks
        self.identity = identity
        document = nil
        navigationText = nil
        anchor = NSRange(location: 0, length: 0)
        head = 0
        revision += 1
        let revision = revision
        indexing?.cancel()
        let task = Task.detached(priority: .utility) { () -> MarkdownSelectionDocument? in
            guard !Task.isCancelled else { return nil }
            let value = MarkdownSelectionDocument(blocks)
            return Task.isCancelled ? nil : value
        }
        indexing = task
        Task { [weak self] in
            guard let value = await task.value, let self, self.revision == revision else { return }
            self.document = value
        }
    }

    deinit { indexing?.cancel() }

    private func prepare() -> MarkdownSelectionDocument {
        if let document { return document }
        // A click immediately after an update can beat preparation. Never use ranges from the old
        // revision; finish the current one here, cancelling its background copy.
        indexing?.cancel()
        let value = MarkdownSelectionDocument(blocks)
        document = value
        return value
    }

    var selectedText: String? {
        guard range.length > 0, let document, NSMaxRange(range) <= document.text.length else { return nil }
        return document.text.substring(with: range)
    }

    func register(_ view: MarkdownLabelView) {
        guard view.window != nil else { return }
        labels[ObjectIdentifier(view)] = Label(view: view)
        refresh(view)
    }

    func unregister(_ view: MarkdownLabelView) { labels.removeValue(forKey: ObjectIdentifier(view)) }

    private func refresh(_ view: MarkdownLabelView) {
        var local = NSRange(location: 0, length: 0)
        if range.length > 0, let id = view.selectionID, let leaf = document?.ranges[id] {
            let intersection = NSIntersectionRange(range, leaf)
            if intersection.length > 0 { local = NSRange(location: intersection.location - leaf.location, length: intersection.length) }
        }
        view.setSelection(local)
    }

    private func setRange(_ value: NSRange) {
        guard value != range else { return }
        range = value
        for label in labels.values { if let view = label.view { refresh(view) } }
    }

    private func leaf(_ view: MarkdownLabelView) -> NSRange? {
        guard let id = view.selectionID else { return nil }
        return prepare().ranges[id]
    }

    func mouseDown(in view: MarkdownLabelView, event: NSEvent) {
        guard let leaf = leaf(view) else { return }
        responder?.window?.makeFirstResponder(responder)
        let point = view.convert(event.locationInWindow, from: nil)
        let index = view.insertionIndex(at: point)
        granularity = event.clickCount >= 3 ? .paragraph : event.clickCount == 2 ? .word : .character
        if event.modifierFlags.contains(.shift) {
            anchor = NSRange(location: anchor.location, length: 0)
            head = leaf.location + index
            setRange(NSUnionRange(anchor, NSRange(location: head, length: 0)))
        } else {
            let local = view.selection(at: index, granularity: granularity)
            anchor = NSRange(location: leaf.location + local.location, length: local.length)
            head = NSMaxRange(anchor)
            setRange(anchor)
        }
        pendingLink = nil
        if granularity == .character, !event.modifierFlags.contains(.shift), let url = view.link(at: point) {
            pendingLink = { [weak view] in view?.openURL?(url) }
        }
        dragStart = event.locationInWindow
        dragPoint = event.locationInWindow
        dragged = false
        dragScroll = view.verticalScrollView
    }

    func mouseDragged(_ event: NSEvent) {
        guard let start = dragStart else { return }
        dragPoint = event.locationInWindow
        guard dragged || hypot(dragPoint.x - start.x, dragPoint.y - start.y) >= 3 else { return }
        dragged = true
        pendingLink = nil
        extendDrag(at: dragPoint)
        if scrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscroll() }
            }
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
    }

    func mouseUp(_ event: NSEvent) {
        if dragged { extendDrag(at: event.locationInWindow) }
        let open = pendingLink
        endDrag()
        open?()
    }

    func endDrag() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        dragStart = nil
        dragScroll = nil
        pendingLink = nil
    }

    private func target(at point: NSPoint) -> MarkdownLabelView? {
        var best: MarkdownLabelView?
        var distance = CGFloat.greatestFiniteMagnitude
        for label in labels.values {
            guard let view = label.view, view.window != nil, !view.bounds.intersection(view.visibleRect).isEmpty else { continue }
            // Unclipped NSViews can report a visibleRect larger than their own bounds. Hit testing
            // the whole reported rectangle would make every label cover the scroll viewport.
            let rect = view.convert(view.bounds.intersection(view.visibleRect), to: nil)
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            // Reading is vertical; within a table row, horizontal distance chooses the cell.
            let d = dy * dy * 100 + dx * dx
            if d < distance { best = view; distance = d }
        }
        return best
    }

    private func extendDrag(at point: NSPoint) {
        guard let view = target(at: point), let leaf = leaf(view) else { return }
        let index = view.insertionIndex(at: view.convert(point, from: nil))
        let local = view.selection(at: index, granularity: granularity)
        let next = NSRange(location: leaf.location + local.location, length: local.length)
        head = next.location < anchor.location ? next.location : NSMaxRange(next)
        setRange(NSUnionRange(anchor, next))
    }

    private func autoscroll() {
        guard let scroll = dragScroll, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let point = clip.convert(dragPoint, from: nil)
        let edge: CGFloat = 18
        let outside = point.y < clip.bounds.minY + edge ? point.y - clip.bounds.minY - edge
            : point.y > clip.bounds.maxY - edge ? point.y - clip.bounds.maxY + edge : 0
        guard outside != 0 else { return }
        var origin = clip.bounds.origin
        origin.y = min(max(doc.bounds.minY, origin.y + min(36, max(-36, outside * 0.3))),
                       max(doc.bounds.minY, doc.bounds.maxY - clip.bounds.height))
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        scroll.layoutSubtreeIfNeeded()
        extendDrag(at: dragPoint)
    }

    func selectAll() {
        let document = prepare()
        anchor = NSRange(location: 0, length: 0)
        head = document.text.length
        setRange(NSRange(location: 0, length: head))
    }

    func contextMenu(in view: MarkdownLabelView, event: NSEvent) -> NSMenu {
        if let leaf = leaf(view) {
            let index = view.insertionIndex(at: view.convert(event.locationInWindow, from: nil))
            if range.length == 0 || !NSLocationInRange(leaf.location + index, range) {
                let local = view.selection(at: index, granularity: .word)
                anchor = NSRange(location: leaf.location + local.location, length: local.length)
                head = NSMaxRange(anchor)
                setRange(anchor)
            }
        }
        responder?.window?.makeFirstResponder(responder)
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: String(localized: "Copy"), action: #selector(MarkdownSelectionView.copy(_:)), keyEquivalent: "")
        copy.target = responder
        let all = menu.addItem(withTitle: String(localized: "Select All"), action: #selector(MarkdownSelectionView.selectAll(_:)), keyEquivalent: "")
        all.target = responder
        return menu
    }

    /// AppKit's key bindings still drive selection. The text is read-only; no command edits it.
    func command(_ selector: Selector) -> Bool {
        let name = NSStringFromSelector(selector)
        let modifying = name.contains("AndModifySelection")
        let base = name.replacingOccurrences(of: "AndModifySelection", with: "")
        let document = prepare()
        var next = head
        let backward = base.contains("Left") || base.contains("Backward") || base.contains("Beginning") || base == "moveUp:"
        switch base {
        case "moveLeft:", "moveBackward:", "moveRight:", "moveForward:":
            if !modifying && range.length > 0 { next = backward ? range.location : NSMaxRange(range) }
            else if backward, head > 0 { next = document.text.rangeOfComposedCharacterSequence(at: head - 1).location }
            else if !backward, head < document.text.length { next = NSMaxRange(document.text.rangeOfComposedCharacterSequence(at: head)) }
        case "moveWordLeft:", "moveWordBackward:", "moveWordRight:", "moveWordForward:":
            if navigationText == nil { navigationText = NSAttributedString(string: document.text as String) }
            next = navigationText?.nextWord(from: head, forward: !backward) ?? head
        case "moveToBeginningOfDocument:": next = 0
        case "moveToEndOfDocument:": next = document.text.length
        case "moveToBeginningOfLine:", "moveToEndOfLine:":
            if let (view, leaf) = headLabel() {
                let line = view.visualLine(at: head - leaf.location)
                next = leaf.location + (backward ? line.location : NSMaxRange(line))
            }
        case "moveToBeginningOfParagraph:":
            next = document.text.lineRange(for: NSRange(location: head, length: 0)).location
        case "moveToEndOfParagraph:":
            let line = document.text.lineRange(for: NSRange(location: head, length: 0))
            next = NSMaxRange(line)
            if next > line.location, document.text.character(at: next - 1) == 10 { next -= 1 }
        case "moveUp:", "moveDown:":
            next = verticalDestination(forward: !backward) ?? head
        default: return false
        }
        head = min(document.text.length, max(0, next))
        if !modifying { anchor = NSRange(location: head, length: 0) }
        else { anchor = NSRange(location: anchor.location, length: 0) }
        setRange(NSUnionRange(anchor, NSRange(location: head, length: 0)))
        return true
    }

    private func headLabel() -> (MarkdownLabelView, NSRange)? {
        guard let document else { return nil }
        for label in labels.values {
            guard let view = label.view, let id = view.selectionID, let leaf = document.ranges[id],
                  head >= leaf.location, head <= NSMaxRange(leaf), !view.bounds.intersection(view.visibleRect).isEmpty else { continue }
            return (view, leaf)
        }
        return nil
    }

    private func verticalDestination(forward: Bool) -> Int? {
        guard let (view, leaf) = headLabel() else { return nil }
        let local = view.insertionPoint(at: head - leaf.location)
        let point = view.convert(NSPoint(x: local.point.x, y: local.point.y + (forward ? local.height : -local.height)), to: nil)
        guard let target = target(at: point), let next = self.leaf(target) else { return nil }
        return next.location + target.insertionIndex(at: target.convert(point, from: nil))
    }
}

/// Persistent responder: the label where a drag began can scroll out of the lazy stack. Keeping
/// focus here makes Copy and Select All continue to work even after that label has gone away.
struct MarkdownSelectionHost: NSViewRepresentable {
    let selection: MarkdownSelection
    let blocks: [MarkdownNode]
    let identity: AnyHashable?

    func makeNSView(context: Context) -> MarkdownSelectionView { MarkdownSelectionView(selection: selection) }
    func updateNSView(_ view: MarkdownSelectionView, context: Context) { selection.setDocument(blocks, identity: identity) }
    static func dismantleNSView(_ view: MarkdownSelectionView, coordinator: ()) { view.selection.endDrag() }
}

final class MarkdownSelectionView: NSView, NSUserInterfaceValidations {
    let selection: MarkdownSelection

    init(selection: MarkdownSelection) {
        self.selection = selection
        super.init(frame: .zero)
        selection.responder = self
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        if !selection.command(selector) { super.doCommand(by: selector) }
    }
    override func resignFirstResponder() -> Bool {
        selection.endDrag()
        return super.resignFirstResponder()
    }
    @objc func copy(_ sender: Any?) {
        guard let text = selection.selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    override func selectAll(_ sender: Any?) { selection.selectAll() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action != #selector(copy(_:)) || selection.range.length > 0
    }
}
