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

    func testExternalOpenRoutesByOwnershipAndKeepsExplicitOpensInTheirWindow() async throws {
        let ws = Workspaces.shared
        ws.start()
        await ws.main.restoreTask?.value
        let parent = await window(), nested = await window()
        let project = parent.root.appendingPathComponent("project")
        let child = project.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        parent.addFolder(project)
        nested.addFolder(child)
        let owned = project.appendingPathComponent("owned.txt")
        let deep = child.appendingPathComponent("deep.txt")
        let free = parent.root.appendingPathComponent("free.txt")
        let explicit = parent.root.appendingPathComponent("explicit.txt")
        for file in [owned, deep, free, explicit] {
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }

        // An explicit in-window open keeps a free file there, including on later external opens.
        await parent.openURLsAsync([explicit])
        let existing = try XCTUnwrap(parent.bufferID(for: explicit))
        parent.newTab()
        await ws.openURLsAsync([explicit])
        XCTAssertEqual(parent.session.selectedBufferID, existing)
        XCTAssertNil(ws.main.bufferID(for: explicit))

        nested.showWindow()
        ws.main.hideWindow(ws.main.window)
        // Ownership wins over the active window; unowned files go to the hidden main window.
        await ws.openURLsAsync([free, deep, owned])
        let freeID = try XCTUnwrap(ws.main.bufferID(for: free))
        XCTAssertEqual(ws.main.session.selectedBufferID, freeID)
        XCTAssertEqual(ws.main.activeStore?.logicalString(), "free.txt")
        XCTAssertTrue(ws.main.window?.isVisible == true)
        XCTAssertTrue(NSApp.orderedWindows.first { $0.isVisible && ws.state(for: $0) != nil } === ws.main.window)
        XCTAssertNotNil(nested.bufferID(for: deep))
        XCTAssertNotNil(parent.bufferID(for: owned))
        XCTAssertNil(parent.bufferID(for: free))
        XCTAssertNil(parent.bufferID(for: deep))

        // Reopening selects the same tab instead of adding another one.
        let count = ws.main.session.tabOrder.count
        await ws.openURLsAsync([free])
        XCTAssertEqual(ws.main.bufferID(for: free), freeID)
        XCTAssertEqual(ws.main.session.tabOrder.count, count)
        ws.main.removeBuffer(freeID, rememberClosed: false)

        let pipe = parent.root.appendingPathComponent("input.tinyedit-stdin")
        try "piped text".write(to: pipe, atomically: true, encoding: .utf8)
        nested.showWindow()
        await ws.openURLsAsync([pipe])
        XCTAssertEqual(ws.main.activeStore?.logicalString(), "piped text")
        let pipeID = try XCTUnwrap(ws.main.session.selectedBufferID)
        ws.main.removeBuffer(pipeID, rememberClosed: false)
        await dispose(nested)
        await dispose(parent)
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

    func testMovedRootKeepsExpansionAndDeletedRootKeepsDraft() async throws {
        let state = await window()
        let folder = state.root.appendingPathComponent("project")
        let child = folder.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        state.addFolder(folder)
        let id = try XCTUnwrap(state.folders.first?.id)
        state.fileTree.toggle(child.path)
        let moved = state.root.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: folder, to: moved)
        state.refreshFolderLocations()
        XCTAssertEqual(state.folders.first?.path, moved.path)
        XCTAssertTrue(state.fileTree.expanded.contains(moved.appendingPathComponent("deep").path))
        let tab = try XCTUnwrap(state.session.selectedBufferID)
        state.stores[tab]!.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "keep draft")
        try FileManager.default.removeItem(at: moved)
        state.refreshFolderLocations()
        XCTAssertTrue(state.folders.first?.unavailable == true)
        XCTAssertTrue(state.fileTree.unreadable.contains(moved.path))
        XCTAssertEqual(state.stores[tab]?.logicalString(), "keep draft")
        state.removeFolder(id)
        XCTAssertTrue(state.folderMonitors.isEmpty)
        await dispose(state)
    }

    func testRootWatcherFollowsRenameAndDeletion() async throws {
        let state = await window()
        let old = state.root.appendingPathComponent("watched")
        let new = state.root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        state.addFolder(old)
        try FileManager.default.moveItem(at: old, to: new)
        for _ in 0..<60 {
            if state.folders.first?.path == new.path { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(state.folders.first?.path, new.path)
        try FileManager.default.removeItem(at: new)
        for _ in 0..<60 {
            if state.folders.first?.unavailable == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(state.folders.first?.unavailable == true)
        await dispose(state)
    }

    func testCancelledNativeDragDoesNotDetachTab() async throws {
        let state = await window()
        let id = try XCTUnwrap(state.session.selectedBufferID)
        let count = Workspaces.shared.windows.count
        TabDrag.begin(id)
        TabDrag.end(at: NSPoint(x: -10000, y: -10000), cancelled: true)
        await Task.yield()
        XCTAssertNil(TabDrag.current)
        XCTAssertEqual(Workspaces.shared.windows.count, count)
        XCTAssertNotNil(state.session.buffers[id])
        await dispose(state)
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

@MainActor
final class SidebarDragTests: XCTestCase {
    func testDragCollapsesAndReopensKeepingTheWidth() async {
        let state = Workspaces.shared.newWindow()
        await state.restoreTask?.value
        state.sidebarVisible = true
        state.sidebarWidth = 300
        state.dragSidebar(to: 250, windowWidth: 1200)
        XCTAssertEqual(state.sidebarWidth, 250)
        state.dragSidebar(to: 40, windowWidth: 1200)
        XCTAssertFalse(state.sidebarVisible)
        state.dragSidebar(to: 200, windowWidth: 1200)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertEqual(state.sidebarWidth, 200)
        state.dragSidebar(to: 10, windowWidth: 1200)
        state.endSidebarDrag(startWidth: 300, wasVisible: true)
        XCTAssertFalse(state.sidebarVisible)
        XCTAssertEqual(state.sidebarWidth, 300, "a sidebar dragged shut opens again at its old width")
        state.resetSidebarWidth()
        XCTAssertEqual(state.sidebarWidth, WorkspaceFile.defaultSidebarWidth)
        for id in state.session.tabOrder { state.removeBuffer(id, rememberClosed: false, refill: false) }
        _ = await Workspaces.shared.close(state, asking: false)
    }
}
