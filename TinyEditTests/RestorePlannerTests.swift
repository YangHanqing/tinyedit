import XCTest
@testable import TinyEdit

final class RestorePlannerTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func fixture(titles: [String]) throws -> (SessionStore, RecoveryStore, [EditorBuffer]) {
        let ss = SessionStore(root: root), rs = RecoveryStore(root: root)
        var session = EditorSession()
        var out: [EditorBuffer] = []
        for t in titles {
            let b = EditorBuffer(title: t)
            session.buffers[b.id] = b; session.tabOrder.append(b.id)
            try rs.writeSnapshot(id: b.id, logicalLF: "text of \(t)")
            out.append(b)
        }
        session.selectedBufferID = session.tabOrder.last
        try ss.save(SessionFile(session: session))
        return (ss, rs, out)
    }

    func testSnapshotBesideValidManifestIsAdoptedNotDeleted() throws {
        let (ss, rs, _) = try fixture(titles: ["A"])
        let stray = UUID()
        try rs.writeSnapshot(id: stray, logicalLF: "crashed before manifest")
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertNil(plan.entries.last?.metadata)
        XCTAssertEqual(plan.entries.last?.text, "crashed before manifest")
        XCTAssertTrue(plan.tombstonedFilesToDelete.isEmpty)
    }

    func testTombstonedSnapshotIsNotAdoptedAndMayBeDeleted() throws {
        let (ss, rs, _) = try fixture(titles: ["A"])
        let dead = UUID()
        try rs.writeSnapshot(id: dead, logicalLF: "discarded")
        guard case .loaded(var f) = ss.load() else { return XCTFail() }
        f.tombstones = [dead]
        try ss.save(f)
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.tombstonedFilesToDelete, [dead])
        XCTAssertTrue(FileManager.default.fileExists(atPath: rs.buffersDirectory.appendingPathComponent("\(dead.uuidString).snapshot").path))
    }

    func testCorruptManifestQuarantinedAndAllSnapshotsAdopted() throws {
        let (ss, rs, _) = try fixture(titles: ["A", "B"])
        try Data("{".utf8).write(to: ss.manifestURL)
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertTrue(plan.quarantinedManifest)
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertTrue(plan.entries.allSatisfy { $0.metadata == nil })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ss.sessionDirectory.path).filter { $0.contains("rejected") }.count, 1)
    }

    func testMissingSnapshotSkippedOthersKept() throws {
        let (ss, rs, bufs) = try fixture(titles: ["A", "B"])
        try rs.deleteSnapshot(recoveryFile: bufs[0].recoveryFile)
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertEqual(plan.entries.map(\.id), [bufs[1].id])
    }

    func testUnknownMetadataValuesAdoptSnapshotAsRecovered() throws {
        let (ss, rs, bufs) = try fixture(titles: ["A"])
        guard case .loaded(var f) = ss.load() else { return XCTFail() }
        f.buffers[0].language = "klingon"
        try ss.save(f)
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertNil(plan.entries[0].metadata)
        XCTAssertEqual(plan.entries[0].id, bufs[0].id)
    }

    func testHostileRecoveryFileNameDoesNotEscape() throws {
        let (ss, rs, bufs) = try fixture(titles: ["A"])
        guard case .loaded(var f) = ss.load() else { return XCTFail() }
        f.buffers[0].recoveryFile = "../../etc/passwd"
        try ss.save(f)
        let plan = RestorePlanner.plan(sessions: ss, recovery: rs)
        XCTAssertEqual(plan.entries.first?.text, "text of A")   // falls back to the same-id snapshot
        XCTAssertEqual(plan.entries.first?.id, bufs[0].id)
    }
}
