import XCTest
@testable import TinyEdit

final class SidebarLayoutTests: XCTestCase {
    func testMaxWidthLeavesTheEditorItsMinimum() {
        XCTAssertEqual(SidebarLayout.maxWidth(windowWidth: 1400, editorMinWidth: 200), 480)
        XCTAssertEqual(SidebarLayout.maxWidth(windowWidth: 600, editorMinWidth: 200), 399)
        XCTAssertEqual(SidebarLayout.maxWidth(windowWidth: 600, editorMinWidth: 400), 199)
        XCTAssertEqual(SidebarLayout.maxWidth(windowWidth: 100, editorMinWidth: 200), 0)
    }

    func testShownWidthKeepsTheStoredOneForAWiderWindow() {
        XCTAssertEqual(SidebarLayout.shownWidth(stored: 400, windowWidth: 1400, editorMinWidth: 200), 400)
        XCTAssertEqual(SidebarLayout.shownWidth(stored: 400, windowWidth: 500, editorMinWidth: 200), 299)
        XCTAssertEqual(SidebarLayout.shownWidth(stored: 50, windowWidth: 1400, editorMinWidth: 200), 160)
        XCTAssertEqual(SidebarLayout.shownWidth(stored: 900, windowWidth: 1400, editorMinWidth: 200), 480)
    }

    func testDrag() {
        XCTAssertEqual(SidebarLayout.drag(proposed: 300, windowWidth: 1400, editorMinWidth: 200), .width(300, limited: nil))
        XCTAssertEqual(SidebarLayout.drag(proposed: 120, windowWidth: 1400, editorMinWidth: 200), .width(160, limited: .min))
        XCTAssertEqual(SidebarLayout.drag(proposed: 79, windowWidth: 1400, editorMinWidth: 200), .collapse)
        XCTAssertEqual(SidebarLayout.drag(proposed: 80, windowWidth: 1400, editorMinWidth: 200), .width(160, limited: .min))
        XCTAssertEqual(SidebarLayout.drag(proposed: 700, windowWidth: 1400, editorMinWidth: 200), .width(480, limited: .max))
        XCTAssertEqual(SidebarLayout.drag(proposed: 350, windowWidth: 600, editorMinWidth: 200), .width(350, limited: nil))
        XCTAssertEqual(SidebarLayout.drag(proposed: 450, windowWidth: 600, editorMinWidth: 200), .width(399, limited: .max))
        // A window too narrow for both still lets the sidebar have its minimum, and only narrower (collapse) is left.
        XCTAssertEqual(SidebarLayout.drag(proposed: 300, windowWidth: 300, editorMinWidth: 200), .width(160, limited: .max))
    }
}
