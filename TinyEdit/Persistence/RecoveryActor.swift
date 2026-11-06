import Foundation

struct FlushItem: Sendable {
    var id: UUID
    var generation: UInt64
    var logicalLF: String
}

struct FlushOutcome: Sendable {
    var ok: Bool
    /// Generations that are now durable on disk.
    var written: [UUID: UInt64]
    var diskFull: Bool
}

/// Serial owner of snapshot writes, snapshot deletes, and session.json replaces.
/// Every op carries a per-buffer generation (content) and a manifest sequence (manifest).
actor RecoveryActor {
    private let recovery: RecoveryStore
    private let sessions: SessionStore
    private var gateOpen = false
    private var latest: [UUID: UInt64] = [:]
    private var lastManifestSeq: UInt64 = 0

    init(root: URL) {
        recovery = RecoveryStore(root: root)
        sessions = SessionStore(root: root)
    }

    func setLaunchGateOpen(_ open: Bool) { gateOpen = open }

    func currentGenerations() -> [UUID: UInt64] { latest }

    /// Writes snapshots (dropping stale generations), then the manifest if it is newer than the last one.
    func flush(items: [FlushItem], manifest: SessionFile, seq: UInt64) -> FlushOutcome {
        guard gateOpen else { return FlushOutcome(ok: true, written: [:], diskFull: false) }
        var written: [UUID: UInt64] = [:]
        var ok = true
        var diskFull = false

        func note(_ error: Error) {
            ok = false
            let ns = error as NSError
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { diskFull = true }
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { diskFull = true }
            Log.recovery.error("recovery write failed: \(ns.domain, privacy: .public) \(ns.code)")
        }

        for item in items {
            if let known = latest[item.id], item.generation < known { continue } // stale: dropped before rename
            do {
                try recovery.writeSnapshot(id: item.id, logicalLF: item.logicalLF)
                latest[item.id] = max(latest[item.id] ?? 0, item.generation)
                written[item.id] = item.generation
            } catch { note(error) }
        }
        if ok, seq > lastManifestSeq {
            do {
                try sessions.save(manifest)
                lastManifestSeq = seq
            } catch { note(error) }
        }
        return FlushOutcome(ok: ok, written: written, diskFull: diskFull)
    }

    /// Discard or clean close: manifest (with tombstone) first, then delete the snapshot. No content write.
    func remove(id: UUID, manifest: SessionFile, seq: UInt64) -> FlushOutcome {
        guard gateOpen else { return FlushOutcome(ok: true, written: [:], diskFull: false) }
        latest[id] = .max // any content op still in flight for this id is now stale
        var ok = true
        if seq > lastManifestSeq {
            do { try sessions.save(manifest); lastManifestSeq = seq } catch {
                ok = false
                Log.recovery.error("manifest write failed on removal: \((error as NSError).code)")
            }
        }
        if ok {
            do { try recovery.deleteSnapshot(recoveryFile: "\(id.uuidString).snapshot") } catch {
                let ns = error as NSError
                if ns.code != NSFileNoSuchFileError && ns.code != NSFileReadNoSuchFileError {
                    Log.recovery.error("snapshot delete failed: \(ns.code)")
                }
            }
        }
        return FlushOutcome(ok: ok, written: [:], diskFull: false)
    }

    /// A buffer this window removed comes back (a tab moved out and in again, same id): its writes count again.
    func readmit(_ id: UUID) {
        if latest[id] == .max { latest[id] = nil }
    }

    /// Deletes a snapshot whose tombstone is already in a completed manifest.
    func deleteTombstoned(_ ids: [UUID]) {
        for id in ids { try? recovery.deleteSnapshot(recoveryFile: "\(id.uuidString).snapshot") }
    }
}
