#if DEBUG
import AppKit
import SwiftUI

/// An end-to-end run of the windows, sidebar and tab moves in the real app: `--e2e 1` builds a session (folder
/// windows, opened files, moved tabs, a closed window) and quits through the normal Quit path; `--e2e 2`, launched
/// afterwards, checks what came back. Everything lives in the container's temp folder (`TinyEdit-e2e`), never in
/// the real session. Results go to `report.txt` and window pictures to PNGs in `out/`. `--e2e 3` is a run of its
/// own for Compare With (tabs, unsaved text, files on disk, navigation, closing). `--e2e 4` saves a large file
/// passed by `open -a … file --args --e2e 4`, which the sandbox grants without its folder. Debug builds only.
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
        if phase == 3 || phase == 4 || phase == 5 || phase == 7 || phase == 8 {
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
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
        if phase == 6 { watchLaunch() }
        if phase == 8 { watchLargeFileOpen() }
        Task {
            await settle(600)
            switch phase {
            case 5: await phasePerfSetup()
            case 6: await phasePerf()
            case 7: await phaseMarkdownSelection()
            case 8: await phaseMinifiedJSON()
            case 1: await phase1()
            case 3: await phaseDiff()
            case 4: await phaseLargeSave()
            default: await phase2()
            }
            lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            let report = out.appendingPathComponent("report-\(phase).txt")
            try? lines.joined(separator: "\n").appending("\n").write(to: report, atomically: true, encoding: .utf8)
            // From the run loop, as a menu's Quit is: a terminate inside this main-queue job would run Quit's
            // nested run loop inside it, and the main queue could not run the flush Quit waits for.
            if !ProcessInfo.processInfo.arguments.contains("--preview-manual") {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.1)
            }
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

        // Markdown Side by Side: half and half by default, the divider's strip takes the mouse, and Reset
        // Window Size gives the standard size back.
        var sideBySide = main.settings
        sideBySide.markdownPreviewLayout = .split
        main.updateSettings(sideBySide)
        main.resetPreviewFraction()
        check(main.newTab(), "a tab for the preview")
        main.setLanguage(.markdown)
        main.togglePreview()
        check(await wait { main.previewVisible && !main.previewFull }, "the preview shows beside the editor")
        await settle()
        if let content = main.window?.contentView {
            func handles(_ view: NSView) -> [NSView] { (view is PreviewHandleView ? [view] : []) + view.subviews.flatMap(handles) }
            let found = handles(content)
            check(found.count == 1, "one preview divider (\(found.count))")
            if let handle = found.first {
                let mid = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: content)
                check(abs(mid.x - content.bounds.midX) <= 2, "the divider is in the middle (\(Int(mid.x)) of \(Int(content.bounds.width)))")
                for dx in [-4.0, 0, 4.0] {
                    let hit = content.hitTest(NSPoint(x: mid.x + dx, y: mid.y))
                    check(hit is PreviewHandleView, "preview divider strip takes the mouse at x\(dx > 0 ? "+" : "")\(dx)")
                }
            }
            snapshot(main.window, "1b-preview-split")
        }
        main.window?.setContentSize(NSSize(width: 700, height: 500))
        main.resetWindowSize()
        await settle(600)
        if let window = main.window, let visible = window.screen?.visibleFrame,
           visible.width > 1100, visible.height > 800 {
            let size = window.contentRect(forFrameRect: window.frame).size
            check(size == WindowSize.standard, "Reset Window Size gives the standard size (\(size))")
            check(abs(window.frame.midX - visible.midX) <= 1, "and centers the window")
        }
        main.togglePreview()
        if let id = main.session.selectedBufferID { _ = await main.closeTabAsync(id) }

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
        if let content = a.window?.contentView {
            // The divider's drag strip lies over both neighbours' edges and takes the mouse there.
            let x = SidebarLayout.shownWidth(stored: a.sidebarWidth, windowWidth: content.bounds.width,
                                             editorMinWidth: a.editorMinWidth)
            for dx in [-4.0, 0.5, 4.0] {
                for y in [content.bounds.maxY - 50, content.bounds.midY, content.bounds.minY + 12] {
                    let hit = content.hitTest(NSPoint(x: x + dx, y: y))
                    let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
                    check(name == "HandleView", "divider strip takes the mouse at x\(dx > 0 ? "+" : "")\(dx), y \(Int(y)) (\(name))")
                }
            }
        }

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

    // MARK: Phase 8: One 25 MB JSON line

    private static func watchLargeFileOpen() {
        Task {
            let main = Workspaces.shared.main
            var selected = false
            while true {
                if let doc = main.activeLargeFile {
                    if !selected {
                        note("process start to selected file tab: \(ms(sinceProcessStart()))")
                        selected = true
                    }
                    if doc.progress.complete {
                        note("process start to indexed file: \(ms(sinceProcessStart()))")
                        return
                    }
                }
                if sinceProcessStart() > 20 { return }
                await settle(2)
            }
        }
    }

    private static func phaseMinifiedJSON() async {
        let main = Workspaces.shared.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window up")
        let fromFinder = ProcessInfo.processInfo.arguments.contains("--finder-open")
        let url = base.appendingPathComponent("minified.json")
        let bytes = fromFinder ? 0 : await Task.detached(priority: .userInitiated) {
            // Mixed scripts, escapes, numbers and URLs, as in a server response. No physical line breaks.
            let item = #"{"id":1234567890123456789,"name":"中文 café 😀","url":"https://example.invalid/a?b=1","value":1.234e-10,"text":"line\nnext"}"#
            let count = 25 * 1_048_576 / (item.utf8.count + 1)
            let data = Data(("[" + Array(repeating: item, count: count).joined(separator: ",") + "]").utf8)
            try? data.write(to: url)
            return data.count
        }.value
        let start = CFAbsoluteTimeGetCurrent()
        if fromFinder {
            // Pass a file with `open -n -W -a …app file.json --args --e2e 8 --finder-open`.
            // This exercises Launch Services, the sandbox grant and AppDelegate's open-URL callback.
            check(await wait { main.activeLargeFile != nil }, "Finder open selects a large-file tab")
            note("Finder open, process age at check: \(ms(sinceProcessStart()))")
        } else {
            await main.openURLsAsync([url])
            note("open to selected tab: \(ms(CFAbsoluteTimeGetCurrent() - start)); \(bytes) bytes")
        }
        guard let doc = main.activeLargeFile else { return check(false, "automatic open uses the large-file view") }
        note("file bytes: \(doc.fileSize)")
        check(main.activeStore == nil, "no whole-document text store or TextKit layout")
        check(await wait { doc.progress.complete }, "index completes")
        if !fromFinder { note("open to indexed: \(ms(CFAbsoluteTimeGetCurrent() - start))") }
        check(doc.progress.lines == 1 && doc.baseRows > 1000, "one physical line is drawn in bounded pieces")
        await settle(100)
        var times: [Double] = []
        for i in 0..<200 {
            times.append(frame(main.window) {
                doc.topRow = Double(i) * doc.maxTopRow() / 199
                main.largeView.refresh()
            })
            // Keep handling input between frames: a synchronous 200-frame benchmark itself hangs the UI.
            await settle(1)
        }
        let sorted = times.sorted()
        note("200 scroll frames: median \(ms(sorted[100])), p95 \(ms(sorted[190])), max \(ms(sorted[199]))")
        if let first = doc.visibleRow(0)?.text, first.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
           let window = main.window {
            let view = main.largeView
            let cw = (" " as NSString).size(withAttributes: [.font: EditorConfiguration.font(size: main.settings.fontSize)]).width
            let gutter = CGFloat(max(String(doc.progress.lines).count, 3)) * cw + 20
            // Select text in the real view, including far beyond the first shaped slice. The exact
            // bytes returned by Copy/Edit must still be those under the pointer after scrolling.
            for column in [0, 1024, 10_000] {
                _ = frame(window) {
                    doc.topRow = 0
                    doc.xOffset = CGFloat(column) * cw
                    view.refresh()
                }
                func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                    let point = view.convert(NSPoint(x: gutter + 8 + x * cw, y: 8), to: nil)
                    return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1)!
                }
                view.mouseDown(with: event(.leftMouseDown, 3.25))
                view.mouseDragged(with: event(.leftMouseDragged, 15.25))
                view.mouseUp(with: event(.leftMouseUp, 15.25))
                check(doc.anchor == LargeFilePosition(row: 0, column: column + 3)
                      && doc.head == LargeFilePosition(row: 0, column: column + 15)
                      && doc.selectedText() == (first as NSString).substring(with: NSRange(location: column + 3, length: 12)),
                      "mouse selection returns the original text at horizontal column \(column)")
            }
        }
        if !fromFinder { snapshot(main.window, "minified-json") }
        check(!main.isDirtyNow(doc.id) && doc.edits.isEmpty, "opening and scrolling leave the file unedited")
    }

    // MARK: Phase 4: Saving a large file the sandbox grants alone

    /// Launched with a large file outside the container (`open -a … big.log --args --e2e 4`), so the sandbox
    /// grants that file and not its folder, as a Finder or `tinyedit` open does. Edits its first and last
    /// lines and saves; the file on disk must hold the edits and every other byte.
    private static func phaseLargeSave() async {
        let main = Workspaces.shared.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window up")
        guard await wait(20, { main.largeFiles.values.contains { $0.progress.complete } }),
              let (id, doc) = main.largeFiles.first(where: { $0.value.progress.complete }), let url = main.fileURLs[id] else {
            return check(false, "a large file was opened and read (pass one with open -a)")
        }
        note(url.path)
        let before = (try? Data(contentsOf: url)) ?? Data()
        check(!before.isEmpty, "the file is readable")
        let last = doc.baseRows - 1
        check(doc.replaceRows(0...0, with: "EDITED FIRST", actionName: "e2e"), "first row edited")
        check(doc.replaceRows(last...last, with: "EDITED LAST", actionName: "e2e"), "last row edited")
        let saved = await main.saveFlow(id)
        check(saved, "Save went through")
        let after = (try? Data(contentsOf: url)) ?? Data()
        let firstBreak = before.firstIndex(of: 0x0A) ?? before.endIndex
        // The last row is the empty one after the final line break: the edit's text follows it.
        let expected = Data("EDITED FIRST".utf8) + before[firstBreak..<before.endIndex] + Data("EDITED LAST".utf8)
        check(after == expected, "the saved file holds the edits and every other byte (\(after.count) of \(expected.count) bytes)")
        check(await wait(20) { doc.progress.complete && !doc.hasEdits }, "the tab reads the saved file again")
        check(main.session.buffers[id]?.dirty == false, "the tab is clean")
    }

    // MARK: Phases 5 and 6: how fast it feels

    /// `--e2e 5` leaves a session of 30 file tabs (small sources, three of 1 MB, two of 8 MB, a long Markdown
    /// file) and quits; `--e2e 6`, launched afterwards, is the cold launch that restores it, timed from the
    /// process start, followed by tab switches, a new tab and the Markdown preview. Numbers go to `report-6.txt`.
    private static var perfFiles: URL { base.appendingPathComponent("Perf", isDirectory: true) }

    private static func phasePerfSetup() async {
        let main = Workspaces.shared.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window up")
        let fm = FileManager.default
        try? fm.createDirectory(at: perfFiles, withIntermediateDirectories: true)
        func source(_ bytes: Int, _ i: Int) -> String {
            var text = ""
            var n = 0
            while text.utf8.count < bytes {
                text += "func value\(i)_\(n)(input: Int) -> String {\n    let doubled = input * 2 // 注释 \(n)\n    return \"result \\(doubled)\"\n}\n\n"
                n += 1
            }
            return text
        }
        var urls: [URL] = []
        for i in 0..<30 {
            let (name, bytes) = i < 24 ? ("small\(i).swift", 20_000) : i < 27 ? ("medium\(i).swift", 1_000_000) : i < 29 ? ("big\(i).swift", 8_000_000) : ("notes.md", 0)
            let url = perfFiles.appendingPathComponent(name)
            var text = source(bytes, i)
            if name == "notes.md" {
                text = "# Notes\n\n"
                for section in 1...12 {
                    text += "## Section \(section) 模块\n\n这是一段比较长的说明文字，包含 **加粗**、`code` 和 [链接](https://example.com)。The quick brown fox jumps over the lazy dog until the line wraps.\n\n"
                    for item in 1...8 { text += "- 第 \(item) 条 with `feature_\(item)` and more words\n" }
                    text += "\n| 名称 | 类型 | 说明 |\n| --- | --- | --- |\n"
                    for row in 1...6 { text += "| `option\(row)` | String | 第 \(row) 个选项的说明 with English |\n" }
                    text += "\n```swift\nfunc example\(section)() -> Int { \(section) }\n```\n\n"
                }
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        await main.openURLsAsync(urls)
        check(main.session.tabOrder.count >= 30, "30 files open (\(main.session.tabOrder.count) tabs)")
        if let first = main.session.tabOrder.first { main.selectTab(first) }
        await settle()
        await main.performFlush()
    }

    private static var launchMarks: [(String, Double)] = []

    /// Seconds since this process started (the kernel's start time, so the launch itself is counted).
    private static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func watchLaunch() {
        launchMarks.append(("applicationDidFinishLaunching", sinceProcessStart()))
        Task {
            let main = Workspaces.shared.main
            var pending: [(String, () -> Bool)] = [
                ("window on screen", { main.window?.isVisible == true }),
                ("text in the editor", { main.host.activeStore != nil && main.window?.isVisible == true }),
                ("ready for commands (launch gate)", { main.launchGateOpen }),
            ]
            while !pending.isEmpty {
                pending.removeAll { name, done in
                    guard done() else { return false }
                    launchMarks.append((name, sinceProcessStart()))
                    return true
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }

    /// The change, then everything it makes the window lay out and draw.
    private static func frame(_ window: NSWindow?, _ change: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        change()
        RunLoop.current.run(mode: .default, before: Date())
        CATransaction.flush()
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
        return CFAbsoluteTimeGetCurrent() - start
    }

    private static func phasePerf() async {
        let main = Workspaces.shared.main
        check(await wait(60) { main.launchGateOpen && main.window != nil }, "main window up")
        await settle(300)
        note("tabs restored: \(main.session.tabOrder.count)")
        for (name, time) in launchMarks { note("launch, \(name): \(ms(time))") }

        let order = main.session.tabOrder
        func title(_ id: UUID) -> String { main.session.buffers[id]?.title ?? "?" }
        var small: [Double] = []
        for round in 0..<2 {
            for id in order {
                let time = frame(main.window) { main.selectTab(id) }
                let name = title(id)
                if name.hasPrefix("small") { small.append(time) } else { note("switch to \(name) (\(round == 0 ? "first" : "again")): \(ms(time))") }
            }
        }
        let sorted = small.sorted()
        if !sorted.isEmpty { note("switch to a 20 KB tab: median \(ms(sorted[sorted.count / 2])), max \(ms(sorted[sorted.count - 1])) of \(sorted.count)") }

        // A keystroke in a small source file, until its colors are on screen.
        if let id = order.first(where: { title($0).hasPrefix("small") }), let store = main.stores[id] {
            _ = frame(main.window) { main.selectTab(id) }
            await settle(400)
            var keys: [Double] = [], colors: [Double] = []
            for _ in 0..<30 {
                let start = CFAbsoluteTimeGetCurrent()
                keys.append(frame(main.window) { main.host.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0)) })
                for _ in 0..<2000 where store.unhighlightedEdits != nil { try? await Task.sleep(for: .milliseconds(1)) }
                _ = frame(main.window) {}
                colors.append(CFAbsoluteTimeGetCurrent() - start)
                await settle(30)
            }
            keys.sort(); colors.sort()
            note("keystroke in a 20 KB tab, drawn: median \(ms(keys[keys.count / 2])), max \(ms(keys[keys.count - 1]))")
            note("keystroke to recolored: median \(ms(colors[colors.count / 2])), max \(ms(colors[colors.count - 1]))")
            main.host.textView.undoManager?.undo()
        }

        if ProcessInfo.processInfo.arguments.contains("--loop") {
            // For a profiler: nothing but tab switches for a while.
            let end = Date().addingTimeInterval(8)
            while Date() < end { for id in order where title(id).hasPrefix("small") { _ = frame(main.window) { main.selectTab(id) } } }
        }

        note("new tab: \(ms(frame(main.window) { main.newTabInWindow() }))")

        if let notes = order.first(where: { title($0) == "notes.md" }) {
            _ = frame(main.window) { main.selectTab(notes) }
            let start = CFAbsoluteTimeGetCurrent()
            main.togglePreview()
            let shown = await wait(10) { !main.previewBlocks.isEmpty }
            _ = frame(main.window) {}
            check(shown, "preview shown")
            note("Markdown preview, from the command to drawn: \(ms(CFAbsoluteTimeGetCurrent() - start))")
            main.togglePreview()
        }
    }

    // MARK: Phase 3: Compare With

    /// A real, long preview, with the same scrolling workload before and after selection changes.
    private static func phaseMarkdownSelection() async {
        let main = Workspaces.shared.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window up")
        var settings = main.settings
        settings.fontSize = 13
        settings.markdownPreviewLayout = .split
        settings.markdownPreviewByDefault = false
        main.updateSettings(settings)
        main.resetWindowSize()
        var source = "# Selection 选择 👩🏽‍💻\n\nFirst paragraph with **bold**, `inline code` and a [link](https://example.com). "
            + String(repeating: "Wrapping text 中文文字。 ", count: 12) + "\n\nSecond paragraph to select across.\n\n"
        let sections = ProcessInfo.processInfo.arguments.contains("--preview-stress") ? 5000 : 120
        for section in 0..<sections {
            source += "## Section \(section)\n\nParagraph \(section) with English and 中文, **bold** and `code`.\n\n"
            source += "- First item \(section)\n- Second item 👩🏽‍💻\n\n> Quoted paragraph\n>\n> Another quote\n\n"
            source += "| Name | Value |\n| --- | --- |\n| alpha | 中文 |\n| beta | 👩🏽‍💻 |\n\n```swift\nlet value = \(section)\nprint(value)\n```\n\n"
        }
        check(main.newTab(), "a tab for the selection run")
        await settle()
        main.host.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        main.setLanguage(.markdown)
        let generation = main.host.activeStore?.generation
        let start = CFAbsoluteTimeGetCurrent()
        if !main.previewVisible { main.togglePreview() }
        main.schedulePreview(delay: .zero)
        check(await wait(15) { !main.previewBlocks.isEmpty }, "long Markdown preview parsed")
        await settle(300)
        _ = frame(main.window) {}
        note("preview ready: \(ms(CFAbsoluteTimeGetCurrent() - start))")
        func descendants<T: NSView>(_ view: NSView?, _: T.Type) -> [T] {
            guard let view else { return [] }
            return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        guard let label = descendants(main.window?.contentView, MarkdownLabelView.self).first,
              let scroll = sequence(first: label.superview, next: { $0?.superview }).compactMap({ $0 as? NSScrollView }).first(where: \.hasVerticalScroller),
              let document = scroll.documentView else { return check(false, "preview scroll view found") }
        note("initial labels: \(descendants(main.window?.contentView, MarkdownLabelView.self).count)")
        var times: [Double] = []
        for round in 0..<2 {
            for step in 0..<100 {
                let y = CGFloat(round == 0 ? step : 99 - step) * 120
                times.append(frame(main.window) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, document.bounds.height - scroll.contentSize.height))))
                    scroll.reflectScrolledClipView(scroll.contentView)
                })
                await settle(5)
            }
        }
        times.sort()
        note("scroll 200 frames: median \(ms(times[times.count / 2])), p95 \(ms(times[times.count * 95 / 100])), total \(ms(times.reduce(0, +)))")
        check(main.host.activeStore?.generation == generation && main.host.activeStore?.logicalString() == source,
              "preview scrolling leaves the editor text and generation alone")
        if ProcessInfo.processInfo.arguments.contains("--preview-baseline") { return }

        guard let responder = descendants(main.window?.contentView, MarkdownSelectionView.self).first,
              let window = main.window else { return check(false, "preview selection responder found") }
        let selection = responder.selection
        func scrollTo(_ y: CGFloat) {
            _ = frame(window) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func findLabel(_ id: String) -> MarkdownLabelView? {
            descendants(window.contentView, MarkdownLabelView.self).first { $0.selectionID == id && !$0.bounds.intersection($0.visibleRect).isEmpty }
        }
        func event(_ type: NSEvent.EventType, _ view: MarkdownLabelView, _ index: Int,
                   count: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let point = view.convert(view.insertionPoint(at: index).point, to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                     clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func drag(_ a: MarkdownLabelView, _ start: Int, _ b: MarkdownLabelView, _ end: Int) {
            a.mouseDown(with: event(.leftMouseDown, a, start))
            a.mouseDragged(with: event(.leftMouseDragged, b, end))
            a.mouseUp(with: event(.leftMouseUp, b, end))
        }
        scrollTo(0)
        await settle(100)
        guard let first = findLabel("1.0"), let second = findLabel("2.0"), let heading = findLabel("0.0") else {
            return check(false, "the first paragraphs are visible")
        }
        let firstText = ("First paragraph with bold, inline code and a link. " + String(repeating: "Wrapping text 中文文字。 ", count: 12)).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSelectionStart = CFAbsoluteTimeGetCurrent()
        drag(first, 0, first, 125)
        note("first selection: \(ms(CFAbsoluteTimeGetCurrent() - firstSelectionStart))")
        check(selection.selectedText == (firstText as NSString).substring(to: 125), "drag across wrapped lines in one paragraph")
        drag(first, 0, second, 16)
        let across = firstText + "\n\nSecond paragraph"
        check(selection.selectedText == across, "drag across paragraphs preserves the paragraph break")
        drag(second, 16, first, 0)
        check(selection.selectedText == across, "backward drag across paragraphs")
        first.mouseDown(with: event(.leftMouseDown, first, 6, flags: .shift))
        first.mouseUp(with: event(.leftMouseUp, first, 6, flags: .shift))
        check(selection.selectedText == String(across.dropFirst(6)), "Shift-click extends from the original anchor")
        first.mouseDown(with: event(.leftMouseDown, first, 8, count: 2))
        first.mouseUp(with: event(.leftMouseUp, first, 8, count: 2))
        check(selection.selectedText == "paragraph", "double-click selects a word")
        first.mouseDown(with: event(.leftMouseDown, first, 8, count: 3))
        first.mouseUp(with: event(.leftMouseUp, first, 8, count: 3))
        check(selection.selectedText == firstText, "triple-click selects the paragraph")
        first.mouseDown(with: event(.leftMouseDown, first, 0))
        first.mouseUp(with: event(.leftMouseUp, first, 0))
        responder.doCommand(by: NSSelectorFromString("moveToEndOfLineAndModifySelection:"))
        let lineLength = selection.range.length
        check(lineLength > 0 && lineLength < 125, "keyboard line selection stops at the visual wrap")
        responder.doCommand(by: NSSelectorFromString("moveDownAndModifySelection:"))
        check(selection.range.length > lineLength, "Shift-Down extends to the next visual line")
        var opened: URL?
        let originalOpenURL = first.openURL
        first.openURL = OpenURLAction { url in opened = url; return .handled }
        let linkIndex = (firstText as NSString).range(of: "link").location + 1
        first.mouseDown(with: event(.leftMouseDown, first, linkIndex))
        first.mouseUp(with: event(.leftMouseUp, first, linkIndex))
        check(opened == URL(string: "https://example.com"), "a click still opens a link")
        opened = nil
        drag(first, linkIndex, second, 16)
        check(opened == nil && selection.range.length > 16, "a drag starting on a link selects without opening it")
        first.openURL = originalOpenURL
        let headingText = "Selection 选择 👩🏽‍💻"
        heading.mouseDown(with: event(.leftMouseDown, heading, (headingText as NSString).length))
        heading.mouseUp(with: event(.leftMouseUp, heading, (headingText as NSString).length))
        responder.doCommand(by: NSSelectorFromString("moveBackwardAndModifySelection:"))
        check(selection.selectedText == "👩🏽‍💻", "keyboard selection keeps a composed emoji intact")

        // Hold the original label while lazy scrolling replaces it, then finish in a table cell.
        first.mouseDown(with: event(.leftMouseDown, first, 0))
        var cell: MarkdownLabelView?
        for y in stride(from: 150, through: 1500, by: 150) {
            scrollTo(CGFloat(y))
            await settle(30)
            if let found = findLabel("7.r2.c1.0") { cell = found; break }
        }
        if let cell {
            first.mouseDragged(with: event(.leftMouseDragged, cell, ("👩🏽‍💻" as NSString).length))
            first.mouseUp(with: event(.leftMouseUp, cell, ("👩🏽‍💻" as NSString).length))
            let copied = selection.selectedText ?? ""
            check(copied.hasPrefix(firstText) && copied.contains("• First item 0\n• Second item 👩🏽‍💻")
                  && copied.contains("Quoted paragraph\n\nAnother quote") && copied.hasSuffix("Name\tValue\nalpha\t中文\nbeta\t👩🏽‍💻"),
                  "selection spans lazy rows, list items, quotes and table cells in reading order")
        } else { selection.endDrag(); check(false, "table cell scrolls into view") }
        check(window.firstResponder === responder, "selection keeps keyboard focus when its starting row scrolls away")
        responder.selectAll(nil)
        let all = selection.selectedText ?? ""
        check(all.hasPrefix(headingText) && all.contains("let value = \(sections - 1)\nprint(value)"), "Select All includes offscreen code and the last section")
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { original -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in original.types { if let data = original.data(forType: type) { item.setData(data, forType: type) } }
            return item
        }
        responder.copy(nil)
        check(board.string(forType: .string) == all, "Copy writes the entire selection without Markdown formatting syntax")
        board.clearContents()
        board.writeObjects(saved)
        check(descendants(window.contentView, NSTextView.self).count == 1, "selection creates no per-block text views")
        check(main.host.activeStore?.generation == generation && main.host.activeStore?.logicalString() == source,
              "selecting and copying leave the editor text and generation alone")
        // Keep dragging at the bottom edge: the stationary pointer must keep revealing more text.
        scrollTo(0)
        await settle(100)
        if let start = findLabel("1.0") {
            start.mouseDown(with: event(.leftMouseDown, start, 0))
            let rect = scroll.convert(scroll.bounds, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.minY - 8)
            let down = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            start.mouseDragged(with: down)
            let before = scroll.contentView.bounds.origin.y
            await settle(250)
            check(scroll.contentView.bounds.origin.y > before && selection.range.length > firstText.utf16.count,
                  "dragging at the bottom edge scrolls and extends the selection")
            start.mouseUp(with: down)
            let stopped = scroll.contentView.bounds.origin.y
            await settle(80)
            check(scroll.contentView.bounds.origin.y == stopped, "releasing the mouse stops autoscroll")
        }
        snapshot(main.window, "markdown-selection")

        // A fresh rendering invalidates the old ranges. Pictures split inline text into multiple
        // labels; a table containing a picture uses the other table renderer.
        let mixed = "# Mixed\n\nBefore ![picture](https://example.invalid/p.png) after.\n\n"
            + "| Image | Text |\n| --- | --- |\n| ![icon](https://example.invalid/i.png) | last |\n\n"
            + "1. [ ] todo\n2. [x] done\n\nEnd.\n"
        main.host.textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        main.host.textView.insertText(mixed, replacementRange: main.host.textView.selectedRange())
        main.schedulePreview(delay: .zero)
        check(await wait {
            if case .heading(_, let title) = main.previewBlocks.first { return String(title.characters) == "Mixed" }
            return false
        }, "preview updates after an edit")
        await settle(200)
        _ = frame(window) {}
        check(selection.range.length == 0, "a new preview clears the previous document's selection")
        scrollTo(0)
        await settle(100)
        if let before = findLabel("1.0"), let after = findLabel("1.2") {
            drag(before, 0, after, 7)
            let text = selection.selectedText ?? ""
            check(text.hasPrefix("Before") && text.contains("picture") && text.hasSuffix("after."), "selection crosses an inline image")
        } else { check(false, "text on both sides of an image is selectable") }
        responder.selectAll(nil)
        let fresh = selection.selectedText ?? ""
        check(fresh.hasPrefix("Mixed\n\nBefore") && fresh.contains("Image\tText\nicon\tlast")
              && fresh.contains("1. [ ] todo\n2. [x] done") && fresh.hasSuffix("End.") && !fresh.contains("Section"),
              "copy order includes image tables and tasks, without text from the previous rendering")
    }

    private static func phaseDiff() async {
        let main = Workspaces.shared.main
        check(await wait { main.launchGateOpen && main.window != nil }, "main window up")
        let dir = base.appendingPathComponent("Diff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let fileA = dir.appendingPathComponent("a.txt")
        try? original.write(to: fileA, atomically: true, encoding: .utf8)
        // The same text as GB18030 with CRLF, and a file of the same name in another folder.
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let crlf = dir.appendingPathComponent("crlf.txt")
        try? ("中文\n" + original).replacingOccurrences(of: "\n", with: "\r\n").data(using: gb)?.write(to: crlf)
        let other = dir.appendingPathComponent("sub", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sameName = other.appendingPathComponent("a.txt")
        try? original.replacingOccurrences(of: "line 20\n", with: "").write(to: sameName, atomically: true, encoding: .utf8)
        let diskHash = { ContentHash.sha256Hex((try? Data(contentsOf: fileA)) ?? Data()) }
        let hashBefore = diskHash()

        await main.openURLsAsync([fileA])
        guard let aID = main.session.orderedBuffers.first(where: { $0.title == "a.txt" })?.id, let aStore = main.stores[aID] else {
            return check(false, "a.txt opened")
        }
        // Unsaved edits in the file tab: line 5 changed, line 30 removed, a line added at the end.
        await settle()   // the text view takes the tab's text on SwiftUI's next update
        main.host.focus()
        func replace(_ find: String, with text: String) {
            let r = (aStore.logicalString() as NSString).range(of: find)
            main.host.textView.setSelectedRange(r)
            main.host.textView.insertText(text, replacementRange: r)
        }
        replace("line 5\n", with: "line five\n")
        replace("line 30\n", with: "")
        replace("line 40\n", with: "line 40\nline 41\n")
        main.host.textView.setSelectedRange(NSRange(location: 3, length: 4))
        let editedText = aStore.logicalString()
        let generation = aStore.generation
        check(main.isDirtyNow(aID), "a.txt has unsaved edits")

        // An Untitled tab holding the original text.
        main.newTab()
        guard let uID = main.session.selectedBufferID, uID != aID else { return check(false, "untitled tab") }
        await settle()
        main.host.textView.insertText(original, replacementRange: NSRange(location: 0, length: 0))
        main.selectTab(aID)
        await settle()
        main.host.textView.setSelectedRange(NSRange(location: 3, length: 4))

        check(!main.compareCandidates(for: aID).contains { $0.id == aID }, "a tab is never offered to compare with itself")
        main.compare(aID, with: .tab(aID))
        await settle(200)
        check(main.diff == nil, "comparing a tab with itself does nothing")

        // Tab with unsaved text against an Untitled tab.
        main.compare(aID, with: .tab(uID))
        check(await wait { main.diff?.result != nil }, "comparison of two tabs computed")
        guard let r = main.diff?.result else { return }
        note("rows: " + r.lines.map { "\($0.kind)\($0.oldNumber ?? 0)/\($0.newNumber ?? 0)" }.joined(separator: " "))
        check(r.changes.count == 3, "three changes (\(r.changes.count))")
        guard r.changes.count == 3 else { return }
        check(r.added == 2 && r.removed == 2, "+2 −2 from a.txt's edited text to the original (+\(r.added) −\(r.removed))")
        let first = r.lines[r.changes[0]]
        check(first.map(\.kind) == [.removed, .added] && first.first?.text == "line five" && first.last?.text == "line 5",
              "a modified line is a removed line then an added one")
        check(first.first?.changed == NSRange(location: 5, length: 4) && first.last?.changed == NSRange(location: 5, length: 1),
              "and the changed part of each is marked")
        check(r.lines.first?.kind == .context && r.lines.contains { $0.kind == .gap && $0.hidden > 0 }, "unchanged runs are folded with context kept")
        check(r.lines[r.changes[2]].map(\.text) == ["line 41"], "only-removed last change")
        check(main.diff?.old.title == "a.txt" && main.diff?.old.directory == nil, "header names the tab")
        await settle(500)
        snapshot(main.window, "diff-1-tabs")

        // Navigation wraps around.
        check(main.diff?.current == 0, "starts at the first change")
        main.stepDiff(1); main.stepDiff(1)
        check(main.diff?.current == 2, "Next moves on")
        main.stepDiff(1)
        check(main.diff?.current == 0, "Next wraps to the first")
        main.stepDiff(-1)
        check(main.diff?.current == 2, "Previous wraps to the last")
        await settle(300)
        snapshot(main.window, "diff-2-last-change")

        // Copy holds only the text, not line numbers or signs.
        if let tv = findDiffTextView(in: main.window?.contentView) {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            // Copy as the menu sends it; the user's clipboard text is put back afterwards.
            let board = NSPasteboard.general
            let saved = board.string(forType: .string)
            tv.copy(nil)
            let copied = board.string(forType: .string) ?? ""
            if let saved { board.clearContents(); board.setString(saved, forType: .string) }
            note("copied \(copied.prefix(60).debugDescription), responder \(String(describing: main.window?.firstResponder.map { type(of: $0) }))")
            check(copied.hasPrefix("line 1\nline 2\nline 3\nline 4\nline five\nline 5"), "copying the diff gives the lines themselves")
            check(main.window?.firstResponder === tv, "the diff takes the keyboard")
        } else {
            check(false, "diff text view on screen")
        }

        // Done: the editor is as it was.
        main.closeDiff()
        check(main.diff == nil, "Done closes it")
        check(aStore.logicalString() == editedText && aStore.generation == generation, "the tab's text was not touched")
        check(main.host.textView.selectedRange() == NSRange(location: 3, length: 4), "nor its selection")
        check(main.session.buffers[aID]?.dirty == true && main.isDirtyNow(aID), "and it is still unsaved")
        check(diskHash() == hashBefore, "the file on disk is unchanged")

        // Against the file on disk: the tab's unsaved edits are the differences.
        main.compare(aID, with: .file(fileA))
        check(await wait { main.diff?.result != nil }, "tab against its own file on disk")
        check(main.diff?.result?.changes.count == 3 && main.diff?.new.fromDisk == true, "shows the unsaved edits")
        check(main.session.orderedBuffers.filter { $0.title == "a.txt" }.count == 1, "no tab opened for the file")

        // Same name in another folder: directories are shown.
        main.compare(aID, with: .file(sameName))
        check(await wait { main.diff?.result != nil && main.diff?.fileURL == sameName }, "same-named file compared")
        check(main.diff?.old.directory != nil && main.diff?.new.directory != nil, "same names show their folders")

        // Edited while shown: marked out of date, Refresh compares again.
        main.compare(aID, with: .tab(uID))
        check(await wait { main.diff?.result != nil }, "compared again")
        aStore.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        check(main.diff?.stale == true, "an edit marks the comparison out of date")
        main.refreshDiff()
        check(await wait { main.diff?.result != nil && main.diff?.stale == false }, "Refresh compares the current text")
        aStore.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")

        // Selecting another tab leaves the comparison.
        main.selectTab(uID)
        check(main.diff == nil, "switching tabs closes the comparison")

        // Different encoding and line endings, same text: no differences once decoded.
        main.newTab()
        guard let gID = main.session.selectedBufferID else { return }
        await settle()
        main.host.textView.insertText("中文\n" + original, replacementRange: NSRange(location: 0, length: 0))
        main.compare(gID, with: .file(crlf))
        check(await wait { main.diff?.result != nil }, "GB18030 CRLF file compared")
        check(main.diff?.result?.isIdentical == true, "identical after decoding: No Differences")
        note("notes: \(main.diff?.notes ?? [])")
        check(main.diff?.notes.count == 2, "encoding and line ending differences are noted")
        await settle(300)
        snapshot(main.window, "diff-3-identical")

        // Empty against non-empty: everything added.
        main.newTab()
        guard let eID = main.session.selectedBufferID else { return }
        await settle()
        main.compare(eID, with: .tab(uID))
        check(await wait { main.diff?.result != nil }, "empty tab compared")
        note("empty: +\(main.diff?.result?.added ?? -1) −\(main.diff?.result?.removed ?? -1) changes \(main.diff?.result?.changes.count ?? -1), source text \(main.stores[eID]?.length ?? -1), u text \(main.stores[uID]?.length ?? -1)")
        check(main.diff?.sourceID == eID && main.diff?.result?.added == 40 && main.diff?.result?.removed == 0 && main.diff?.result?.changes.count == 1,
              "empty against 40 lines: one change, all added")
        // Closing the source tab closes the comparison.
        main.removeBuffer(eID)
        check(main.diff == nil, "closing the tab closes its comparison")

        // A missing file: a clear message, no comparison.
        main.selectTab(aID)
        await settle()
        main.compare(aID, with: .file(dir.appendingPathComponent("nope.txt")))
        check(await wait { main.toast != nil }, "a missing file says so")
        note("toast: \(main.toast?.text ?? "")")
        check(main.diff == nil, "and shows no comparison")

        // The command palette's second step.
        main.showComparePalette()
        check(await wait { main.paletteVisible && main.paletteCompareSource == aID }, "palette Compare With… lists targets")
        let targets = main.paletteCompareCommands.map(\.id)
        check(!targets.contains("compare." + aID.uuidString) && targets.contains("compare." + uID.uuidString) && targets.last == "compare.file",
              "other tabs and Choose File…, never the tab itself")
        await settle(300)
        snapshot(main.window, "diff-4-palette")
        main.paletteCompareCommands.first { $0.id == "compare." + uID.uuidString }?.action()
        check(await wait { main.diff?.result != nil } && !main.paletteVisible, "choosing a tab there compares")
        main.closeDiff()

        // Too much to align: one change. Too large: refused.
        let many = TextDiff.make(old: (0..<3000).map { "a\($0)" }.joined(separator: "\n"),
                                 new: (0..<3000).map { "b\($0)" }.joined(separator: "\n"))
        check(many?.aligned == false && many?.changes.count == 1, "past the edit limit the middle is one change")
        check(TextDiff.make(old: String(repeating: "x", count: TextDiff.sizeLimit + 1), new: "") == nil, "over 8 MB is refused")

        check(diskHash() == hashBefore, "a.txt on disk never changed")
        // Leave nothing for the next run's session.
        for id in main.session.tabOrder { main.removeBuffer(id, rememberClosed: false) }
    }

    private static func findDiffTextView(in view: NSView?) -> DiffTextView? {
        guard let view else { return nil }
        if let v = view as? DiffTextView { return v }
        for sub in view.subviews { if let v = findDiffTextView(in: sub) { return v } }
        return nil
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
