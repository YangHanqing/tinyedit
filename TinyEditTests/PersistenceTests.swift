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

    func testTabOrderRepair() {
        var file = SessionFile(session: makeSession(titles: ["A", "B"]))
        let missing = file.tabOrder.removeLast()
        file.tabOrder.append(UUID())   // unknown id
        XCTAssertTrue(file.repairTabOrder())
        XCTAssertEqual(file.tabOrder.last, missing)
        XCTAssertEqual(file.tabOrder.count, 2)
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
}
