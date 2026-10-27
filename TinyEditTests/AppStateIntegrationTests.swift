import XCTest
import AppKit
@testable import TinyEdit

/// Drives real AppState instances against a temp root: recovery, restore, open, save, conflicts.
@MainActor
final class AppStateIntegrationTests: XCTestCase {
    var root: URL!
    var files: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEditIT-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        files = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func launch() async -> AppState {
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        return s
    }

    private func type(_ text: String, into s: AppState, at id: UUID? = nil) {
        let store = s.stores[id ?? s.session.selectedBufferID!]!
        store.textStorage.replaceCharacters(in: NSRange(location: store.length, length: 0), with: text)
    }

    func testFreshLaunchHasOneUntitledAndGateOpen() async {
        let s = await launch()
        XCTAssertTrue(s.launchGateOpen)
        XCTAssertEqual(s.session.orderedBuffers.map(\.title), ["Untitled"])
    }

    func testFiveUntitledTabsSurviveQuitAndRelaunch() async {
        let a = await launch()
        type("one", into: a)
        for i in 2...5 { a.newTab(); type("text \(i)", into: a) }
        let order = a.session.tabOrder
        let selected = a.session.selectedBufferID
        await a.performFlush()

        let b = await launch()
        XCTAssertEqual(b.session.tabOrder, order)
        XCTAssertEqual(b.session.selectedBufferID, selected)
        XCTAssertEqual(b.stores[order[0]]?.logicalString(), "one")
        XCTAssertEqual(b.stores[order[4]]?.logicalString(), "text 5")
        XCTAssertTrue(b.session.buffers[order[0]]!.dirty)
    }

    func testDirtyFileSurvivesRelaunchAndDiskIsUntouched() async throws {
        let f = files.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: f)
        let mtime = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as! Date

        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        XCTAssertEqual(a.session.buffers[id]?.title, "config.json")
        XCTAssertFalse(a.session.buffers[id]!.dirty)             // a non-empty opened file is clean
        type("\n// edit", into: a)
        XCTAssertTrue(a.session.buffers[id]!.dirty)              // dirty on the keystroke
        await a.performFlush()

        let b = await launch()
        XCTAssertEqual(b.stores[id]?.logicalString(), "{}\n// edit")
        XCTAssertTrue(b.session.buffers[id]!.dirty)
        XCTAssertEqual(b.session.buffers[id]?.conflict, ConflictState.none)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "{}")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as! Date, mtime)
    }

    func testInvalidUTF8IsRejectedWithoutBuffer() async throws {
        let f = files.appendingPathComponent("bin.dat")
        try Data([0xC3, 0x28, 0xFF]).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        XCTAssertEqual(s.session.tabOrder.count, 1)
        XCTAssertEqual(s.toast?.text, String(localized: "Could not open file"))
    }

    func testSaveWritesBytesPreservesCRLFAndClearsDirty() async throws {
        let f = files.appendingPathComponent("w.txt")
        try Data("a\r\nb\r\n".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        XCTAssertEqual(s.session.buffers[id]?.lineEnding, .crlf)
        XCTAssertEqual(s.stores[id]?.logicalString(), "a\nb\n")
        type("c\n", into: s)
        let out = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        XCTAssertEqual(out, .saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("a\r\nb\r\nc\r\n".utf8))
        XCTAssertFalse(s.session.buffers[id]!.dirty)
    }

    func testGBKFileOpensAndConvertsToUTF8OnlyWhenAsked() async throws {
        let f = files.appendingPathComponent("gbk.txt")
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        let bytes = try XCTUnwrap("第一行\r\n第二行\r\n".data(using: gbk))
        try bytes.write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        XCTAssertEqual(s.session.buffers[id]?.encoding, .gb18030)
        XCTAssertEqual(s.stores[id]?.logicalString(), "第一行\n第二行\n")

        let saved = await s.saveWithAsync(id, encoding: .utf8, lineEnding: .lf)
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("第一行\n第二行\n".utf8))
        XCTAssertEqual(s.status.encoding, .utf8)
        XCTAssertFalse(s.session.buffers[id]!.dirty)
    }

    func testExecutableBitSurvivesSaveOrWarns() async throws {
        let f = files.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        type("echo hi\n", into: s)
        _ = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        let mode = (try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertNotEqual(mode & 0o111, 0)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "#!/bin/sh\necho hi\n")
    }

    func testExternalChangeOnCleanBufferWaitsForUserToReload() async throws {
        let f = files.appendingPathComponent("c.txt")
        try Data("one".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        try Data("two".utf8).write(to: f)
        let ack = s.session.buffers[id]?.diskContentHash
        await s.handleExternalChange(id)
        XCTAssertEqual(s.stores[id]?.logicalString(), "one")
        XCTAssertEqual(s.session.buffers[id]?.diskContentHash, ack)
        XCTAssertEqual(s.session.buffers[id]?.conflict, .external)
        XCTAssertNotNil(s.banner)
        await s.reloadFromDisk(id)
        XCTAssertEqual(s.stores[id]?.logicalString(), "two")
        XCTAssertFalse(s.session.buffers[id]!.dirty)
        XCTAssertEqual(s.session.buffers[id]?.conflict, ConflictState.none)
    }

    func testExternalChangeOnDirtyBufferNeverOverwritesEvenAcrossRelaunch() async throws {
        let f = files.appendingPathComponent("d.txt")
        try Data("base".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        let ack = a.session.buffers[id]!.diskContentHash
        type("+mine", into: a)
        try Data("H2".utf8).write(to: f)                         // another program edits the file
        await a.handleExternalChange(id)
        XCTAssertEqual(a.session.buffers[id]?.conflict, .external)
        XCTAssertEqual(a.stores[id]?.logicalString(), "base+mine")  // text untouched
        XCTAssertEqual(a.session.buffers[id]?.diskContentHash, ack) // baseline not advanced
        await a.performFlush()

        // Quit and relaunch: the warning survives and the stored hash is still the old acknowledgement.
        let b = await launch()
        XCTAssertEqual(b.session.buffers[id]?.conflict, .external)
        XCTAssertEqual(b.session.buffers[id]?.diskContentHash, ack)
        XCTAssertEqual(b.stores[id]?.logicalString(), "base+mine")

        // Save without confirmation must refuse and leave H2 on disk (this is what Cancel relies on).
        let out = await b.performSave(id: id, url: f, overwrite: false, presenter: nil)
        XCTAssertEqual(out, .conflict)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "H2")
        XCTAssertEqual(b.session.buffers[id]?.diskContentHash, ack)
    }

    func testCleanBufferWhoseFileChangedWhileClosedPromptsOnLaunch() async throws {
        let f = files.appendingPathComponent("e.txt")
        try Data("old".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        await a.performFlush()
        try Data("new".utf8).write(to: f)
        let b = await launch()
        XCTAssertEqual(b.stores[id]?.logicalString(), "old")
        XCTAssertEqual(b.session.buffers[id]?.conflict, .external)
        XCTAssertNotNil(b.banner)
    }

    func testDeletedFileOnLaunchBecomesMissingAndKeepsText() async throws {
        let f = files.appendingPathComponent("gone.txt")
        try Data("keep".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        type("!", into: a)
        await a.performFlush()
        try FileManager.default.removeItem(at: f)
        let b = await launch()
        XCTAssertEqual(b.session.buffers[id]?.conflict, .missing)
        XCTAssertEqual(b.stores[id]?.logicalString(), "keep!")
    }

    func testDiscardedTabDoesNotComeBack() async {
        let a = await launch()
        type("secret", into: a)
        let id = a.session.selectedBufferID!
        await a.performFlush()
        a.removeBuffer(id)                      // Discard
        try? await Task.sleep(for: .milliseconds(300))
        let snap = root.appendingPathComponent("Buffers/\(id.uuidString).snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snap.path))
        let b = await launch()
        XCTAssertNil(b.session.buffers[id])
        XCTAssertFalse(b.stores.values.contains { $0.logicalString() == "secret" })
    }

    func testCorruptManifestStillRecoversSnapshots() async throws {
        let a = await launch()
        type("precious", into: a)
        let id = a.session.selectedBufferID!
        await a.performFlush()
        try Data("garbage".utf8).write(to: root.appendingPathComponent("Session/session.json"))
        let b = await launch()
        XCTAssertTrue(b.stores.values.contains { $0.logicalString() == "precious" })
        XCTAssertTrue(b.session.orderedBuffers.contains { $0.title.hasPrefix("Recovered") })
        _ = id
    }

    func testNothingWrittenBeforeGateOpens() async {
        let s = AppState(root: root, autoRestore: false)
        s.flushImmediately()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Session/session.json").path))
    }

    /// Save trims trailing whitespace and adds the final newline, in the buffer (one undo step) and on disk.
    func testSaveCleansUpTrailingWhitespaceAndFinalNewline() async throws {
        let url = files.appendingPathComponent("clean.swift")
        try "let a = 1\n".write(to: url, atomically: true, encoding: .utf8)
        let s = await launch()
        let previousSettings = s.settings
        defer { previousSettings.save() }
        var cleanupSettings = previousSettings
        cleanupSettings.trimTrailingWhitespaceOnSave = true
        cleanupSettings.ensureFinalNewline = true
        s.updateSettings(cleanupSettings)
        await s.openURLsAsync([url])
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.insertText("let b = 2   \nlet c = 3", replacementRange: NSRange(location: 10, length: 0))
        closeEventUndoGroup(s)
        let saved = await s.saveFlow(s.session.selectedBufferID!)
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let a = 1\nlet b = 2\nlet c = 3\n")
        XCTAssertEqual(s.activeStore?.logicalString(), "let a = 1\nlet b = 2\nlet c = 3\n")
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "let a = 1\nlet b = 2   \nlet c = 3")
    }

    /// Ends the undo group AppKit opened for this "event"; separate key presses would each get their own.
    private func closeEventUndoGroup(_ s: AppState) {
        guard let um = s.activeStore?.undoManager else { return }
        while um.groupingLevel > 0 { um.endUndoGrouping() }
    }

    func testSuccessfulFlushClearsAnEarlierQuitRefusal() async {
        let s = await launch()
        s.terminationRefused = true      // an earlier Quit timed out or failed
        type("x", into: s)
        await s.performFlush()
        XCTAssertFalse(s.terminationRefused)   // the next Quit flushes instead of offering a lossy exit
    }

    func testPastedCRLFSavesAsCRLFWithoutDoubledBreaks() async throws {
        let f = files.appendingPathComponent("win.txt")
        try Data("a\r\nb\r\n".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        s.host.activate(s.stores[id]!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: s.stores[id]!.length, length: 0))
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("c\r\nd\r\n", forType: .string)
        XCTAssertTrue(s.host.textView.readSelection(from: pb, type: .string))
        let outcome = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("a\r\nb\r\nc\r\nd\r\n".utf8))
    }

    /// `n` snapshots with no manifest: the next launch adopts each one as a Recovered tab.
    private func writeOrphanSnapshots(_ n: Int) throws {
        let dir = root.appendingPathComponent("Buffers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<n { try Data("tab \(i)".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).snapshot")) }
    }

    /// Restore never drops a buffer to stay under the limit; the limit only stops new tabs.
    func testRestoreIsNotCappedByTheTabLimit() async throws {
        try writeOrphanSnapshots(EditorSession.maxTabs + 1)
        let s = await launch()
        XCTAssertEqual(s.session.tabOrder.count, EditorSession.maxTabs + 1)
        XCTAssertFalse(s.newTab())
        await s.performFlush()
    }
}

/// Typing latency on the main thread: the keystroke path must stay O(1) on a large document.
@MainActor
final class TypingLatencyTests: XCTestCase {
    func testKeystrokePathIsCheapOnA3MBDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TL-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        let store = s.activeStore!
        let line = "let value = \"some text here\" // 0123456789\n"
        store.replaceLogicalText(String(repeating: line, count: 70_000), recordUndo: false, settings: s.settings)   // ~3 MB
        s.host.activate(store, settings: s.settings)
        s.setLanguage(.python)
        try await Task.sleep(for: .milliseconds(100))

        let n = 200
        let start = ContinuousClock.now
        for i in 0..<n {
            s.host.textView.insertText("x", replacementRange: NSRange(location: 1000 + i, length: 0))
        }
        let perKey = (ContinuousClock.now - start) / n
        print("per-keystroke main-thread cost on 3 MB doc: \(perKey)")
        XCTAssertLessThan(perKey, .milliseconds(8))
    }
}
