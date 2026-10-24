import XCTest
import AppKit
@testable import TinyEdit

/// Drives the app's own window: what is tested here lives in how SwiftUI and AppKit route updates and keys.
@MainActor
final class EditorSlotTests: XCTestCase {
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testLeavingATabWithPreviewShowsTheNewTabsText() async throws {
        let state = AppState.shared
        for _ in 0..<100 where !state.launchGateOpen { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(state.launchGateOpen)
        XCTAssertTrue(state.openTranslationTab("alpha"))
        let plain = try XCTUnwrap(state.session.selectedBufferID)
        XCTAssertTrue(state.openTranslationTab("# Title"))
        let markdown = try XCTUnwrap(state.session.selectedBufferID)
        defer { state.removeBuffer(plain); state.removeBuffer(markdown) }
        state.setLanguage(.markdown)
        state.togglePreview()
        spin(0.3)
        XCTAssertTrue(state.previewVisible)

        for _ in 0..<3 {
            state.selectTab(plain)
            spin(0.3)
            XCTAssertTrue(state.host.layoutManager.textContentManager === state.stores[plain]?.contentStorage)
            XCTAssertEqual(state.host.textView.string, "alpha")
            state.selectTab(markdown)
            spin(0.3)
            XCTAssertEqual(state.host.textView.string, "# Title")
        }
    }

    /// Edit ▸ Undo / Redo send `undo:` / `redo:` to the first responder. The window answers them with its
    /// own manager, not the buffer's, so ⌘Z does nothing unless the text view answers first. Tests have no key
    /// window, so this walks the responder chain from the first responder, as the menu does.
    func testUndoAndRedoActionsReachTheBuffersManager() async throws {
        let state = AppState.shared
        for _ in 0..<100 where !state.launchGateOpen { try await Task.sleep(for: .milliseconds(50)) }
        let window = try XCTUnwrap(state.window)
        XCTAssertTrue(state.openTranslationTab(""))
        let id = try XCTUnwrap(state.session.selectedBufferID)
        defer { state.removeBuffer(id) }
        spin(0.3)
        let textView = state.host.textView
        window.makeFirstResponder(textView)
        let undo = NSMenuItem(title: "Undo", action: #selector(EditorTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(EditorTextView.redo(_:)), keyEquivalent: "Z")

        textView.insertText("hello", replacementRange: textView.selectedRange())
        spin(0.1)
        XCTAssertTrue(textView.validateUserInterfaceItem(undo))
        let responder = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(responder.tryToPerform(#selector(EditorTextView.undo(_:)), with: undo))
        XCTAssertEqual(textView.string, "")
        XCTAssertTrue(textView.validateUserInterfaceItem(redo))
        XCTAssertTrue(responder.tryToPerform(#selector(EditorTextView.redo(_:)), with: redo))
        XCTAssertEqual(textView.string, "hello")
    }
}
