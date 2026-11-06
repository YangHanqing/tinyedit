import XCTest
@testable import TinyEdit

final class PersistenceTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeSession(titles: [String]) -> EditorSession {
        var s = EditorSession()
        for t in titles {
            var b = EditorBuffer(title: t)
            b.dirty = true
            b.fileBookmark = t == "notes.txt" ? Data([1, 2, 3]) : nil
            s.buffers[b.id] = b; s.tabOrder.append(b.id)
        }
        s.selectedBufferID = s.tabOrder.first
        return s
    }

    func testSessionRoundTrip() throws {
        let store = SessionStore(root: root)
        let session = makeSession(titles: ["Untitled", "notes.txt"])
        try store.save(SessionFile(session: session))
        guard case .loaded(let file) = store.load() else { return XCTFail("not loaded") }
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.tabOrder, session.tabOrder)
        XCTAssertEqual(file.buffers.map(\.title), ["Untitled", "notes.txt"])
        XCTAssertEqual(file.buffers[1].fileBookmark, Data([1, 2, 3]))
    }

    func testFreshInstallAndLoadDoesNotWrite() {
        let store = SessionStore(root: root)
        XCTAssertEqual(store.load(), .noSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL.path))
    }

    func testCorruptManifestIsUnreadableAndSnapshotsSurviveQuarantine() throws {
        let store = SessionStore(root: root), rec = RecoveryStore(root: root)
        let id = UUID()
        try rec.writeSnapshot(id: id, logicalLF: "keep me")
        try FileManager.default.createDirectory(at: store.sessionDirectory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.manifestURL)
        XCTAssertEqual(store.load(), .unreadable)
        try store.quarantineCorruptManifest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL.path))
        XCTAssertEqual(try rec.readSnapshot(recoveryFile: "\(id.uuidString).snapshot"), "keep me")
        XCTAssertEqual(rec.validSnapshotFiles().count, 1)
    }

    func testUnknownSchemaVersionIsUnreadable() throws {
        let store = SessionStore(root: root)
        var file = SessionFile(); file.schemaVersion = 2
        try FileManager.default.createDirectory(at: store.sessionDirectory, withIntermediateDirectories: true)
        try SessionStore.makeEncoder().encode(file).write(to: store.manifestURL)
        XCTAssertEqual(store.load(), .unreadable)
    }

    func testRecoveryFileNameValidation() {
        XCTAssertTrue(SessionStore.validateRecoveryFileName("\(UUID().uuidString).snapshot"))
        XCTAssertFalse(SessionStore.validateRecoveryFileName("../secret.snapshot"))
        XCTAssertFalse(SessionStore.validateRecoveryFileName("a/b.snapshot"))
        let rec = RecoveryStore(root: root)
        XCTAssertThrowsError(try rec.readSnapshot(recoveryFile: "../secret.snapshot"))
    }

    func testCapsOnClosedTabsAndTombstones() throws {
        let store = SessionStore(root: root)
        var file = SessionFile()
        file.tombstones = (0..<250).map { _ in UUID() }
        file.closedTabs = (0..<30).map { i in
            ClosedTabRecord(fileBookmark: Data([1]), fileDisplayName: "f\(i)", language: .plain, encoding: .utf8,
                            lineEnding: .lf, cursorLocation: 0, selectionLength: 0, scrollPosition: 0, closedAt: Date())
        }
        try store.save(file)
        guard case .loaded(let back) = store.load() else { return XCTFail() }
        XCTAssertEqual(back.tombstones.count, 200)
        XCTAssertEqual(back.closedTabs.count, 20)
    }

    func testTabOrderRepair() {
        var file = SessionFile(session: makeSession(titles: ["A", "B"]))
        let missing = file.tabOrder.removeLast()
        file.tabOrder.append(UUID())   // unknown id
        XCTAssertTrue(file.repairTabOrder())
        XCTAssertEqual(file.tabOrder.last, missing)
        XCTAssertEqual(file.tabOrder.count, 2)
    }

    func testInvalidEnumAdoptsAsRecoveredSignal() {
        var meta = BufferMetadata(EditorBuffer(title: "x"))
        meta.language = "klingon"
        XCTAssertNil(meta.makeBuffer())
    }

    /// Nil follows the default-preview setting; an explicit choice, off included, survives a round trip.
    /// A manifest written before the setting only knew `true` as a choice.
    func testMarkdownPreviewChoiceRoundTrips() {
        for choice in [nil, true, false] as [Bool?] {
            var b = EditorBuffer(title: "x")
            b.markdownPreviewVisible = choice
            XCTAssertEqual(BufferMetadata(b).makeBuffer()?.markdownPreviewVisible, choice)
        }
        var legacy = BufferMetadata(EditorBuffer(title: "x"))
        legacy.markdownPreviewChosen = nil
        legacy.markdownPreviewVisible = false
        XCTAssertNil(legacy.makeBuffer()?.markdownPreviewVisible)
        legacy.markdownPreviewVisible = true
        XCTAssertEqual(legacy.makeBuffer()?.markdownPreviewVisible, true)
    }

    func testNonUTF8SnapshotSkippedAndLeftOnDisk() throws {
        let rec = RecoveryStore(root: root)
        let good = UUID(), bad = UUID()
        try rec.writeSnapshot(id: good, logicalLF: "ok")
        try Data([0xC3, 0x28]).write(to: rec.buffersDirectory.appendingPathComponent("\(bad.uuidString).snapshot"))
        XCTAssertEqual(rec.validSnapshotFiles().map(\.lastPathComponent), ["\(good.uuidString).snapshot"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.buffersDirectory.appendingPathComponent("\(bad.uuidString).snapshot").path))
    }

    func testAtomicWriteReplacesAndLeavesNoTemp() throws {
        let dest = root.appendingPathComponent("f.txt")
        try AtomicFileWriter.write(Data("one".utf8), to: dest)
        try AtomicFileWriter.write(Data("two".utf8), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "two")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testUntitledNumbering() {
        var s = EditorSession()
        XCTAssertEqual(s.nextUntitledTitle(), "Untitled")
        for _ in 0..<2 { let b = EditorBuffer(title: s.nextUntitledTitle()); s.buffers[b.id] = b }
        XCTAssertEqual(s.nextUntitledTitle(), "Untitled 3")
        let two = s.buffers.values.first { $0.title == "Untitled 2" }!
        s.buffers[two.id] = nil
        XCTAssertEqual(s.nextUntitledTitle(), "Untitled 2")
    }
}
