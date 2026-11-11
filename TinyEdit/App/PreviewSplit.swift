import AppKit
import SwiftUI

/// How the editor slot is shared between the editor and the Markdown preview beside it. The preview's share
/// is one global value (default half), changed by dragging the divider and kept across launches.
enum PreviewSplit {
    static let storageKey = "tinyedit.previewFraction"
    static let defaultFraction = 0.5

    static func load(from defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: storageKey)
        return value > 0 && value < 1 ? value : defaultFraction
    }

    static func save(_ fraction: Double, to defaults: UserDefaults = .standard) {
        defaults.set(fraction, forKey: storageKey)
    }

    static func reset(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: storageKey) }

    /// The editor's width in a slot `width` wide, leaving each pane `SidebarLayout.paneMinWidth` when there is room.
    static func editorWidth(slot width: Double, fraction: Double) -> Double {
        let room = max(0, width - SidebarLayout.dividerWidth)
        let minimum = min(SidebarLayout.paneMinWidth, room / 2)
        return (room * (1 - fraction)).clamped(to: minimum...(room - minimum)).rounded()
    }

    /// The preview's share for an editor dragged to `editorWidth`.
    static func fraction(editorWidth: Double, slot width: Double) -> Double {
        let room = max(1, width - SidebarLayout.dividerWidth)
        let minimum = min(SidebarLayout.paneMinWidth, room / 2)
        return 1 - editorWidth.clamped(to: minimum...(room - minimum)) / room
    }
}

extension AppState {
    /// A double-click on the preview's divider, and Window ▸ Reset Window Size.
    func resetPreviewFraction() {
        previewFraction = PreviewSplit.defaultFraction
        PreviewSplit.reset()
    }
}

/// The 1 pt line between the editor and the preview, with a 10 pt AppKit drag strip over it (see `SidebarDivider`
/// for why AppKit). Dragging moves it live; the share is saved when the drag ends.
struct PreviewDivider: View {
    @Environment(AppState.self) private var appState
    let slotWidth: Double

    var body: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(width: SidebarLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                PreviewResizeHandle(appState: appState, slotWidth: slotWidth)
                    .frame(width: SidebarLayout.handleWidth)
                    .accessibilityHidden(true)
            }
    }
}

private struct PreviewResizeHandle: NSViewRepresentable {
    let appState: AppState
    let slotWidth: Double

    func makeNSView(context: Context) -> PreviewHandleView { PreviewHandleView() }

    func updateNSView(_ view: PreviewHandleView, context: Context) {
        view.appState = appState
        view.slotWidth = slotWidth
    }
}

final class PreviewHandleView: NSView {
    weak var appState: AppState?
    var slotWidth = 0.0

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.resizeCursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { Self.resizeCursor.set() }

    override func mouseDown(with event: NSEvent) {
        guard let window, let appState else { return }
        if event.clickCount == 2 {
            appState.resetPreviewFraction()
            return
        }
        let startX = Double(event.locationInWindow.x)
        let startEditor = PreviewSplit.editorWidth(slot: slotWidth, fraction: appState.previewFraction)
        window.disableCursorRects()
        Self.resizeCursor.set()
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { [weak self] event, stop in
            guard let self, let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let proposed = startEditor + Double(event.locationInWindow.x) - startX
            appState.previewFraction = PreviewSplit.fraction(editorWidth: proposed, slot: slotWidth)
        }
        window.enableCursorRects()
        window.resetCursorRects()
        PreviewSplit.save(appState.previewFraction)
    }

    private static var resizeCursor: NSCursor {
        if #available(macOS 15, *) { .columnResize } else { .resizeLeftRight }
    }
}
