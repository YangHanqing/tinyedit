import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only this app understands the payload. AppKit owns the drag lifecycle, including its final screen
/// position; no global mouse-button polling or delayed guesses about the end of a SwiftUI drag.
@MainActor
enum TabDrag {
    static let type = UTType(exportedAs: "cn.hqyang.tinyedit.tab")
    private(set) static var current: UUID?
    private static var taken = false

    @discardableResult
    static func begin(_ id: UUID) -> NSItemProvider {
        current = id
        taken = false
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    static func take() -> UUID? {
        guard let id = current else { return nil }
        taken = true
        return id
    }

    static func end(at point: NSPoint, cancelled: Bool) {
        let id = current
        current = nil
        if let id, !taken, !cancelled { Workspaces.shared.tabDragEnded(id, at: point) }
    }
}

/// Observe a tab's events without intercepting its click, close button, rename field or context menu.
struct TabDragSource: NSViewRepresentable {
    let id: UUID
    let title: String
    let enabled: Bool

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ view: SourceView, context: Context) {
        view.id = id
        view.tabTitle = title
        view.enabled = enabled
    }

    final class SourceView: NSView, NSDraggingSource {
        var id = UUID()
        var tabTitle = ""
        var enabled = true
        private var monitor: Any?
        private var start: NSPoint?
        private var dragging = false
        private var cancelled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if dragging {
                if event.type == .keyDown, event.keyCode == 53 { cancelled = true }
                return event
            }
            guard enabled, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                // Leave the trailing close button to SwiftUI.
                start = visibleRect.insetBy(dx: 0, dy: 2).contains(point) && point.x < bounds.maxX - 24 ? event.locationInWindow : nil
            case .leftMouseUp:
                start = nil
            case .leftMouseDragged:
                guard let start, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 5 else { break }
                self.start = nil
                dragging = true
                cancelled = false
                TabDrag.begin(id)
                let item = NSPasteboardItem()
                item.setString(id.uuidString, forType: NSPasteboard.PasteboardType(TabDrag.type.identifier))
                let drag = NSDraggingItem(pasteboardWriter: item)
                let image = NSImage(size: bounds.size, flipped: false) { rect in
                    NSColor.controlBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    (self.tabTitle as NSString).draw(in: rect.insetBy(dx: 10, dy: 6), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
                    ])
                    return true
                }
                drag.setDraggingFrame(bounds, contents: image)
                let session = beginDraggingSession(with: [drag], event: event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = false
                return nil
            default: break
            }
            return event
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let escaped = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode == 53 } ?? false
            dragging = false
            TabDrag.end(at: screenPoint, cancelled: cancelled || escaped)
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
