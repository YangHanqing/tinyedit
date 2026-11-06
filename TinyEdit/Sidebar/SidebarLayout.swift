import Foundation

/// How wide the sidebar may be in a window, and what a drag of its divider means. Pure, so it is tested
/// without a window.
enum SidebarLayout {
    /// The divider's drawn width; the only width it takes from the layout.
    static let dividerWidth = 1.0
    /// The strip that takes the drag, centered on the divider and lying over the views either side.
    static let handleWidth = 10.0
    /// A drag that would leave the sidebar narrower than this hides it, as Finder and Xcode do.
    static let collapseBelow = 80.0
    /// The narrowest the editor, and the Markdown preview beside it, may each get.
    static let paneMinWidth = 200.0

    /// The widest the sidebar can be while the editor keeps `editorMinWidth`. Never below the stored range's
    /// minimum unless the window itself is too narrow for both.
    static func maxWidth(windowWidth: Double, editorMinWidth: Double) -> Double {
        let room = windowWidth - editorMinWidth - dividerWidth
        return min(WorkspaceFile.sidebarWidthRange.upperBound, max(room, 0))
    }

    /// The width shown for a stored width. The stored one is kept as it is, so a window made wider again gets
    /// it back.
    static func shownWidth(stored: Double, windowWidth: Double, editorMinWidth: Double) -> Double {
        let limit = maxWidth(windowWidth: windowWidth, editorMinWidth: editorMinWidth)
        return min(stored.clamped(to: WorkspaceFile.sidebarWidthRange), limit)
    }

    enum Drag: Equatable {
        /// Show the sidebar at this width; `limited` is where it stopped (min or max) so the cursor can say so.
        case width(Double, limited: Limit?)
        case collapse
    }

    enum Limit: Equatable { case min, max }

    static func drag(proposed: Double, windowWidth: Double, editorMinWidth: Double) -> Drag {
        if proposed < collapseBelow { return .collapse }
        let lower = WorkspaceFile.sidebarWidthRange.lowerBound
        let upper = max(lower, maxWidth(windowWidth: windowWidth, editorMinWidth: editorMinWidth))
        if proposed <= lower { return .width(lower, limited: .min) }
        if proposed >= upper { return .width(upper, limited: .max) }
        return .width(proposed, limited: nil)
    }
}
