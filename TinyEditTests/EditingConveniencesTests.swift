import AppKit
import XCTest
@testable import TinyEdit

/// Smart Return, wrapping a selection and whole-line copy, driven through the real text view and its undo.
final class EditingConveniencesTests: XCTestCase {
    @MainActor
    func testReturnUsesTheBufferLanguage() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "if x {}", settings: settings)
        host.activate(store, settings: settings)
        host.textView.bufferLanguage = { .javascript }
        host.textView.setSelectedRange(NSRange(location: 6, length: 0))
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "if x {\n    \n}")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 11, length: 0))
        host.textView.undo(nil)
        XCTAssertEqual(store.logicalString(), "if x {}")
    }

    @MainActor
    func testWrapSelection() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "say hi now", settings: settings)
        host.activate(store, settings: settings)
        let tv = host.textView
        tv.setSelectedRange(NSRange(location: 4, length: 2))
        XCTAssertTrue(tv.wrapSelection(with: "\""))
        XCTAssertEqual(store.logicalString(), "say \"hi\" now")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertTrue(tv.wrapSelection(with: "("))
        XCTAssertEqual(store.logicalString(), "say \"(hi)\" now")
        XCTAssertFalse(tv.wrapSelection(with: "x"))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(tv.wrapSelection(with: "("), "no selection types the bracket")
        tv.undo(nil)   // both wraps ran in one event, so they share its undo group
        XCTAssertEqual(store.logicalString(), "say hi now")
    }

    @MainActor
    func testWholeLineCopyAndPaste() {
        let host = EditorTextHost()
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "one\ntwo", settings: settings)
        host.activate(store, settings: settings)
        let tv = host.textView
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(tv.copyWholeLine(to: pb))
        XCTAssertEqual(pb.string(forType: .string), "two\n", "the last line gets a newline")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(tv.pasteWholeLine(from: pb))
        XCTAssertEqual(store.logicalString(), "two\none\ntwo")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0), "the caret moves down with its line")
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertFalse(tv.pasteWholeLine(from: pb), "over a selection it pastes as text")
        pb.clearContents()
        pb.setString("plain\n", forType: .string)
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertFalse(tv.pasteWholeLine(from: pb), "only a whole-line copy pastes above")
    }
}
