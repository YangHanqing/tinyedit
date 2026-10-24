import XCTest
import AppKit
@testable import TinyEdit

/// A document large enough that a full layout or a walk over one long CoreText line shows up as a hang.
@MainActor
final class LargeDocumentLayoutTests: XCTestCase {
    private var window: NSWindow!
    private let host = EditorTextHost()

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host.scrollView
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // activate() restores scroll asynchronously
        window.displayIfNeeded()
    }

    /// A 300 000-character line took about 7 s to unwrap through `scrollRangeToVisible` and AppKit's
    /// content-height estimate, both quadratic in the length of one CoreText line; 2 MB took minutes.
    func testUnwrappedLongLineIsBoundedAndQuick() {
        var settings = EditorSettings()
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 300_000 / 27)
        let store = BufferTextStore(id: UUID(), text: text, settings: settings)
        host.activate(store, settings: settings)
        settle()

        settings.wordWrap = false
        let start = Date()
        host.apply(settings: settings, stores: [store])
        settle()
        settings.fontSize += 1
        host.apply(settings: settings, stores: [store])
        settle()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertLessThanOrEqual(host.layoutManager.usageBoundsForTextContainer.width, EditorTextHost.unwrappedLineWidth)
        XCTAssertFalse(host.scrollView.horizontalScroller?.isHidden ?? true)
    }
}
