import XCTest
import AppKit
@testable import TinyEdit

@MainActor
final class WorkspaceTests: XCTestCase {
    private func window() async -> AppState {
        let state = Workspaces.shared.newWindow()
        await state.restoreTask?.value
        return state
    }

    private func dispose(_ state: AppState) async {
        for id in state.session.tabOrder { state.removeBuffer(id, rememberClosed: false, refill: false) }
        _ = await Workspaces.shared.close(state, asking: false)
    }

    func testFailedTransferKeepsSourceTextAndRecovery() async throws {
        let source = await window()
        let destination = await window()
        let id = try XCTUnwrap(source.session.selectedBufferID)
        source.stores[id]!.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "irreplaceable draft")
        await source.performFlush()
        await destination.performFlush()
        await destination.workspaceWrite?.value
        // A non-directory at the recovery root deterministically simulates an unwritable destination.
        try FileManager.default.removeItem(at: destination.root)
        try Data().write(to: destination.root)
        let moved = await Workspaces.shared.moveTab(id, to: destination)
        XCTAssertFalse(moved)
        XCTAssertEqual(source.stores[id]?.logicalString(), "irreplaceable draft")
        XCTAssertNil(destination.session.buffers[id])
        let restored = AppState(root: source.root, autoRestore: false)
        await restored.restore()
        XCTAssertEqual(restored.stores[id]?.logicalString(), "irreplaceable draft")
        await restored.shutDown()
        try FileManager.default.removeItem(at: destination.root)
        try FileManager.default.createDirectory(at: destination.root, withIntermediateDirectories: true)
        await dispose(source)
        await dispose(destination)
    }

    func testEditCompletingDuringTransferKeepsNewerSource() async throws {
        let source = await window()
        let destination = await window()
        let id = try XCTUnwrap(source.session.selectedBufferID)
        source.stores[id]!.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "before")
        // Hold adoption at its actor hop until a previously queued edit finishes in the source.
        destination.pendingRemovals[id] = Task { @MainActor in
            while destination.session.buffers[id] == nil { await Task.yield() }
            source.stores[id]!.textStorage.replaceCharacters(in: NSRange(location: 6, length: 0), with: " after")
        }
        let moved = await Workspaces.shared.moveTab(id, to: destination)
        XCTAssertFalse(moved)
        XCTAssertEqual(source.stores[id]?.logicalString(), "before after")
        XCTAssertNil(destination.session.buffers[id])
        XCTAssertFalse(source.transferring)
        XCTAssertTrue(source.host.textView.isEditable)
        await dispose(source)
        await dispose(destination)
    }

    func testConcurrentMovesHaveOnlyOneDestination() async throws {
        let source = await window(), a = await window(), b = await window()
        let id = try XCTUnwrap(source.session.selectedBufferID)
        source.stores[id]!.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "one owner")
        async let first = Workspaces.shared.moveTab(id, to: a)
        async let second = Workspaces.shared.moveTab(id, to: b)
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual([source, a, b].filter { $0.session.buffers[id] != nil }.count, 1)
        XCTAssertEqual([a, b].flatMap { $0.session.tabOrder }.filter { $0 == id }.count, 1)
        await dispose(source)
        await dispose(a)
        await dispose(b)
    }

    func testConcurrentOpenInTwoWindowsHasOneOwner() async throws {
        let a = await window(), b = await window()
        let file = a.root.appendingPathComponent("concurrent.txt")
        try String(repeating: "concurrent open\n", count: 10000).write(to: file, atomically: true, encoding: .utf8)
        async let first: Void = a.openURLsAsync([file])
        async let second: Void = b.openURLsAsync([file])
        _ = await (first, second)
        XCTAssertEqual([a, b].filter { $0.bufferID(for: file) != nil }.count, 1)
        await dispose(a)
        await dispose(b)
    }
}
