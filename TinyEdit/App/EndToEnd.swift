#if DEBUG
import AppKit

/// An end-to-end run of the windows, sidebar and tab moves in the real app: `--e2e 1` builds a session (folder
/// windows, opened files, moved tabs, a closed window) and quits through the normal Quit path; `--e2e 2`, launched
/// afterwards, checks what came back. Everything lives in the container's temp folder (`TinyEdit-e2e`), never in
/// the real session. Results go to `report.txt` and window pictures to PNGs in `out/`. Debug builds only.
@MainActor
enum EndToEnd {
    static var phase: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--e2e"), args.indices.contains(i + 1) else { return nil }
        return Int(args[i + 1])
    }

    static let base = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEdit-e2e", isDirectory: true)
    static var root: URL { base.appendingPathComponent("root", isDirectory: true) }
    static var fixture: URL { base.appendingPathComponent("Project", isDirectory: true) }
    static var fixture2: URL { base.appendingPathComponent("Second", isDirectory: true) }
    static var out: URL { base.appendingPathComponent("out", isDirectory: true) }

    /// Before `AppState.shared` exists: phase 1 starts from nothing.
    static func prepare() {
        guard let phase else { return }
        let fm = FileManager.default
        if phase == 1 {
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            func write(_ path: String, _ text: String, in dir: URL = fixture) {
                let url = dir.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            write("README.md", "# Project\n\nA folder for the end-to-end run.\n")
            write("notes.txt", "notes\n")
            write(".gitignore", "build/\n")
            write(".git/HEAD", "ref: refs/heads/main\n")
            write("src/main.swift", "print(\"hello\")\n")
            write("src/util.swift", "func util() {}\n")
            write("todo.md", "- [ ] second folder\n", in: fixture2)
        }
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        lines.append((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    private static func note(_ what: String) { lines.append("      " + what) }

    private static func wait(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    static func run() {
        guard let phase else { return }
        Task {
            await settle(600)
            if phase == 1 { await phase1() } else { await phase2() }
            lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            let report = out.appendingPathComponent("report-\(phase).txt")
            try? lines.joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
            // From the run loop, as a menu's Quit is: a terminate inside this main-queue job would run Quit's
            // nested run loop inside it, and the main queue could not run the flush Quit waits for.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.1)
        }
    }

    // MARK: Phase 1

    private static func phase1() async {
        let ws = Workspaces.shared
        let main = ws.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window restored and on screen")
        check(ws.windows.isEmpty, "no other window at first launch")
        check(!main.sidebarVisible, "main window starts without the sidebar")
        snapshot(main.window, "1-main")

        // A folder from Finder: a window of its own.
        ws.openURLs([fixture])
        check(await wait { ws.windows.count == 1 && ws.windows[0].folders.count == 1 }, "opening a folder makes a new window holding it")
        guard let a = ws.windows.first else { return }
        let root = a.folders[0].path
        check(await wait { a.fileTree.listings[root] != nil }, "the folder is listed")
        let names = a.fileTree.listings[root]?.map(\.name) ?? []
        note("listed: \(names.joined(separator: ", "))")
        check(names == ["src", ".gitignore", "notes.txt", "README.md"], "folders first, Finder order, .git hidden")
        check(a.sidebarVisible && a.window?.isVisible == true, "the new window shows its sidebar")
        check(a.window?.title == "Project — " + String(localized: "Untitled"), "window title leads with the folder (\(a.window?.title ?? "nil"))")
        await settle()
        snapshot(a.window, "2-folder-window")

        // Clicks on the rows, as a mouse would.
        check(await click(row: "src", in: a), "click on the src row")
        check(await wait { a.fileTree.expanded.contains(root + "/src") && a.fileTree.listings[root + "/src"] != nil }, "src expands and is listed")
        await settle(200)
        check(await click(row: "main.swift", in: a), "click on the main.swift row")
        check(await wait { a.selectedBuffer?.title == "main.swift" }, "clicking a file opens it in this window")
        check(a.selectedFilePath == root + "/src/main.swift", "the open file's row is the selected one")
        check(a.session.orderedBuffers.map(\.title) == ["main.swift"], "the first file takes the empty Untitled tab's place")
        check(main.session.orderedBuffers.allSatisfy { $0.title != "main.swift" }, "the main window did not get it")
        await settle()
        snapshot(a.window, "3-file-open")

        // FSEvents: a file made outside the app shows up.
        try? "new\n".write(to: fixture.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        check(await wait(6) { a.fileTree.listings[root]?.contains { $0.name == "added.txt" } == true }, "a file created on disk appears in the tree")
        try? FileManager.default.removeItem(at: fixture.appendingPathComponent("added.txt"))
        check(await wait(6) { a.fileTree.listings[root]?.contains { $0.name == "added.txt" } == false }, "and goes away when deleted")

        // Finder sends a file inside the folder while the main window is key: it goes to the folder's window.
        main.showWindow()
        check(await wait { ws.target === main }, "main window is key again")
        ws.openURLs([fixture.appendingPathComponent("notes.txt")])
        check(await wait { a.session.orderedBuffers.contains { $0.title == "notes.txt" } }, "a file inside a window's folder opens in that window")
        check(!main.session.orderedBuffers.contains { $0.title == "notes.txt" }, "not in the main window")
        // Asked for in the main window explicitly, the tab moves there (one window per file).
        await main.openURLsAsync([fixture.appendingPathComponent("notes.txt")])
        check(main.session.orderedBuffers.contains { $0.title == "notes.txt" } && !a.session.orderedBuffers.contains { $0.title == "notes.txt" },
              "opening it from the main window moves the tab, never duplicates it")
        if let id = main.session.orderedBuffers.first(where: { $0.title == "notes.txt" })?.id { _ = await ws.moveTab(id, to: a) }
        check(a.session.orderedBuffers.contains { $0.title == "notes.txt" }, "moved back to the folder window")

        // Dragging a tab out to empty space: a new window under the pointer.
        guard let tabID = a.session.orderedBuffers.first(where: { $0.title == "main.swift" })?.id else { return check(false, "main.swift tab") }
        let empty = emptyScreenPoint()
        note("drop point \(Int(empty.x)),\(Int(empty.y))")
        let provider = TabDrag.begin(tabID)
        _ = provider
        ws.tabDragEnded(tabID, at: empty)
        check(await wait { ws.windows.count == 2 && ws.windows[1].session.tabOrder == [tabID] && a.session.buffers[tabID] == nil },
              "tab dropped outside every window becomes a new window")
        guard ws.windows.count == 2 else { return }
        let b = ws.windows[1]
        check(a.session.buffers[tabID] == nil, "and leaves the window it came from")
        check(b.session.tabOrder == [tabID], "the new window holds only that tab")
        check(b.fileURLs[tabID] != nil && b.monitors[tabID] != nil, "the moved tab keeps its file and watches it")
        if let frame = b.window?.frame, let visible = NSScreen.main?.visibleFrame {
            note("new window frame \(NSStringFromRect(frame))")
            check(visible.contains(NSPoint(x: frame.midX, y: frame.maxY - 10)), "the new window's title bar is on screen")
        }
        await settle()
        snapshot(b.window, "4-dragged-out")

        // Dragging it onto the main window: it joins, and the emptied folderless window closes.
        let bRoot = b.root
        main.showWindow()
        await settle(200)
        guard let mainFrame = main.window?.frame else { return }
        ws.tabDragEnded(tabID, at: NSPoint(x: mainFrame.midX, y: mainFrame.midY))
        check(await wait { main.session.buffers[tabID] != nil }, "tab dropped on another window moves there")
        check(await wait { ws.windows.count == 1 }, "the window it left, now empty and folderless, closes")
        check(!FileManager.default.fileExists(atPath: bRoot.path), "and its session folder is removed")
        // And back to the folder window through its tab bar's drop path.
        _ = TabDrag.begin(tabID)
        if let id = TabDrag.take() { _ = await ws.moveTab(id, to: a, before: a.session.tabOrder.first) }
        check(a.session.tabOrder.first == tabID, "dropped on a tab bar, it goes before the tab under it")

        // Settings are app-wide.
        let size = main.settings.fontSize
        a.zoom(by: 2)
        check(main.settings.fontSize == size + 2 && a.settings.fontSize == size + 2, "zoom in one window applies to every window")
        a.resetZoom()
        var restoreSize = main.settings
        restoreSize.fontSize = size
        main.updateSettings(restoreSize)

        // Sidebar toggle in the main window, and a folder dropped on it joins it.
        main.toggleSidebar()
        check(main.sidebarVisible, "the main window can show the sidebar too")
        main.dropOnSidebar([fixture2])
        check(await wait { main.folders.count == 1 }, "a folder dropped on the sidebar joins that window")
        await settle()
        snapshot(main.window, "5-main-sidebar")
        main.removeFolder(main.folders[0].id)
        main.toggleSidebar()
        check(main.folders.isEmpty && !main.sidebarVisible, "removed again")

        // Dock menu.
        // Through NSApp's delegate, as the Dock asks: SwiftUI's adaptor has to pass it on.
        let titles = { NSApp.delegate?.applicationDockMenu?(NSApp)?.items.map(\.title).filter { !$0.isEmpty } ?? [] }
        note("dock: \(titles())")
        check(titles() == [String(localized: "New Window"), String(localized: "New Tab"), String(localized: "Open Folder…")],
              "dock menu while the main window shows")
        main.hideWindow(main.window)
        check(titles().last == String(localized: "Show Main Window"), "dock menu offers the hidden main window")
        main.showWindow()

        // New Window, then a folder opened from it: the empty window takes it instead of making another.
        let c = ws.newWindow()
        check(await wait { c.launchGateOpen && c.session.tabOrder.count == 1 }, "New Window opens with one Untitled tab")
        await settle()
        snapshot(c.window, "6-new-window")
        ws.openFolder(fixture2, from: c)
        check(await wait { c.folders.count == 1 } && ws.windows.count == 2, "a folder opened from an empty window fills that window")

        // A window with unsaved text closes by moving it to the main window.
        let d = ws.newWindow()
        check(await wait { d.launchGateOpen }, "another new window")
        d.host.textView.window?.makeFirstResponder(d.host.textView)
        d.host.textView.insertText("draft from a closed window", replacementRange: NSRange(location: 0, length: 0))
        check(d.isDirtyNow(d.session.tabOrder[0]), "it has unsaved text")
        let dRoot = d.root
        check(await ws.close(d, asking: false), "closing it")
        check(main.session.orderedBuffers.contains { main.stores[$0.id]?.logicalString() == "draft from a closed window" },
              "its unsaved tab moved to the main window")
        check(!FileManager.default.fileExists(atPath: dRoot.path) && ws.windows.count == 2, "the window and its session are gone")

        // Leave a session for phase 2.
        a.fileTree.toggle(root + "/src")   // collapse
        a.fileTree.toggle(root + "/src")   // and expand again: saved expanded
        if let frame = a.window?.frame {
            a.window?.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 900, height: 600), display: true)
        }
        let expect: [String: Any] = [
            "aTabs": a.session.orderedBuffers.map(\.title),
            "aFrame": NSStringFromRect(a.window?.frame ?? .zero),
            "cFolder": c.folders.first?.name ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: expect) { try? data.write(to: out.appendingPathComponent("expect.json")) }
        note("quitting through Quit with \(ws.windows.count) extra windows")
    }

    // MARK: Phase 2

    private static func phase2() async {
        let ws = Workspaces.shared
        let main = ws.main
        let expect = (try? Data(contentsOf: out.appendingPathComponent("expect.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check(await wait { main.launchGateOpen }, "main window restored")
        check(await wait { ws.windows.count == 2 && ws.windows.allSatisfy(\.launchGateOpen) }, "both folder windows came back")
        for w in ws.windows {
            note("window \(w.root.lastPathComponent): folders \(w.folders.map(\.name)), tabs \(w.session.orderedBuffers.map(\.title)), " +
                 "file folders \(WorkspaceFile.read(in: w.root)?.folders.map { ($0.path as NSString).lastPathComponent } ?? [])")
        }
        guard ws.windows.count == 2 else { return }
        let a = ws.windows[0], c = ws.windows[1]
        check(a.folders.first?.name == "Project" && c.folders.first?.name == expect["cFolder"] as? String, "in creation order, with their folders")
        check(a.session.orderedBuffers.map(\.title) == (expect["aTabs"] as? [String] ?? []), "with their tabs in order (\(a.session.orderedBuffers.map(\.title)))")
        let root = a.folders.first?.path ?? ""
        check(await wait { a.fileTree.listings[root + "/src"] != nil }, "expanded folders are expanded and listed again")
        if let frame = a.window?.frame, let saved = expect["aFrame"] as? String {
            check(NSEqualRects(frame, NSRectFromString(saved)), "the window is where it was")
        }
        check(main.session.orderedBuffers.contains { main.stores[$0.id]?.logicalString() == "draft from a closed window" },
              "the text moved out of the closed window survived the restart")
        let mainTab = a.session.orderedBuffers.first { $0.title == "main.swift" }?.id
        check(mainTab.map { a.fileURLs[$0] != nil } ?? false, "a moved file tab still has its file after restart")
        await settle(600)
        snapshot(a.window, "7-restored")

        let cRoot = c.root
        check(await ws.close(c), "closing a clean window asks nothing")
        check(!FileManager.default.fileExists(atPath: cRoot.path) && ws.windows.count == 1, "it is gone")
        if let id = main.session.orderedBuffers.first(where: { main.stores[$0.id]?.logicalString() == "draft from a closed window" })?.id {
            main.removeBuffer(id)
        }
    }

    // MARK: Helpers

    /// What a click on a sidebar row does. Real clicks cannot be sent from here: an app started from this
    /// session never becomes active, and an inactive window takes a click only as the one that activates it.
    private static func click(row name: String, in state: AppState) async -> Bool {
        var row: FileTreeRow?
        for _ in 0..<20 {
            row = state.fileTree.rows(for: state.folders).first { $0.node.name == name }
            if row != nil { break }
            await settle(100)
        }
        guard let row else { note("no row \(name)"); return false }
        state.activateSidebarItem(row.node)
        return true
    }

    /// A point on the main screen outside every window of this app.
    private static func emptyScreenPoint() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let windows = NSApp.windows.filter(\.isVisible).map(\.frame)
        for point in [NSPoint(x: screen.maxX - 40, y: screen.minY + 40), NSPoint(x: screen.minX + 160, y: screen.minY + 40),
                      NSPoint(x: screen.maxX - 40, y: screen.maxY - 40)] where !windows.contains(where: { $0.contains(point) }) {
            return point
        }
        return NSPoint(x: screen.maxX - 4, y: screen.minY + 4)
    }

    private static func snapshot(_ window: NSWindow?, _ name: String) {
        guard let view = window?.contentView else { return }
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }
}
#endif
