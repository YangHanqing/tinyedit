import XCTest
import AppKit
@testable import TinyEdit

/// One NSTextView, one content storage per buffer, swapped with `NSTextLayoutManager.replace(_:)`.
@MainActor
final class BufferSwapTests: XCTestCase {
    func testSwapKeepsTextSelectionAndUndoPerBuffer() {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        let a = BufferTextStore(id: UUID(), text: "", settings: settings)
        let b = BufferTextStore(id: UUID(), text: "", settings: settings)
        var editsA = 0, editsB = 0
        a.onCharactersEdited = { _ in editsA += 1 }
        b.onCharactersEdited = { _ in editsB += 1 }

        host.activate(a, settings: settings)
        host.textView.insertText("alpha", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(a.logicalString(), "alpha")
        XCTAssertEqual(editsA, 1)

        host.activate(b, settings: settings)
        XCTAssertEqual(host.textView.string, "")
        host.textView.insertText("beta", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(b.logicalString(), "beta")
        XCTAssertEqual(a.logicalString(), "alpha")
        XCTAssertEqual(editsB, 1)
        XCTAssertEqual(editsA, 1)

        host.activate(a, settings: settings)
        XCTAssertEqual(host.textView.string, "alpha")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertTrue(host.textView.undoManager === a.undoManager)
        XCTAssertTrue(a.undoManager.canUndo)
        a.undoManager.undo()
        XCTAssertEqual(a.logicalString(), "")
        XCTAssertEqual(b.logicalString(), "beta")
    }

    func testAttributeEditsDoNotBumpGenerationOrDirty() {
        let settings = EditorSettings()
        let s = BufferTextStore(id: UUID(), text: "hello", settings: settings)
        var fired = 0
        s.onCharactersEdited = { _ in fired += 1 }
        let g = s.generation
        var bigger = settings; bigger.fontSize = 20
        s.applyBaseAttributes(bigger)
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(s.generation, g)
        XCTAssertFalse(s.undoManager.canUndo)
    }

    func testProgrammaticReplaceDoesNotDirtyOrUndo() {
        let settings = EditorSettings()
        let s = BufferTextStore(id: UUID(), text: "old", settings: settings)
        var fired = 0
        s.onCharactersEdited = { _ in fired += 1 }
        s.replaceLogicalText("new", recordUndo: false, settings: settings)
        XCTAssertEqual(s.logicalString(), "new")
        XCTAssertEqual(fired, 0)
        XCTAssertFalse(s.undoManager.canUndo)
    }
}
