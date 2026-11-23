import Foundation

struct FlushItem: Sendable {
    var id: UUID
    var generation: UInt64
    var logicalLF: String
    /// Residency epoch of `id` in this window; incremented on remove/readmit so stale pre-transfer flushes drop.
    var epoch: UInt64 = 0
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
    private var epochs: [UUID: UInt64] = [:]
    private var lastManifestSeq: UInt64 = 0

    init(root: URL) {
        recovery = RecoveryStore(root: root)
        sessions = SessionStore(root: root)
    }

    func setLaunchGateOpen(_ open: Bool) { gateOpen = open }

    func currentGenerations() -> [UUID: UInt64] { latest }

    /// Writes snapshots (dropping stale epochs/generations), then the manifest if it is newer than the last one.
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
            let currentEpoch = epochs[item.id] ?? 0
            if item.epoch != currentEpoch { continue }
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

    /// Discard or clean close: flush any pending live snapshots first so the manifest never names a buffer
    /// without a snapshot, then write the manifest (with tombstone), then delete the removed snapshot.
    func remove(id: UUID, pendingItems: [FlushItem] = [], manifest: SessionFile, seq: UInt64) -> FlushOutcome {
        guard gateOpen else { return FlushOutcome(ok: true, written: [:], diskFull: false) }
        epochs[id, default: 0] &+= 1
        latest[id] = .max // any content op still in flight for this id is now stale
        var written: [UUID: UInt64] = [:]
        var ok = true
        var diskFull = false
        for item in pendingItems where item.id != id {
            let currentEpoch = epochs[item.id] ?? 0
            if item.epoch != currentEpoch { continue }
            if let known = latest[item.id], item.generation < known { continue }
            do {
                try recovery.writeSnapshot(id: item.id, logicalLF: item.logicalLF)
                latest[item.id] = max(latest[item.id] ?? 0, item.generation)
                written[item.id] = item.generation
            } catch {
                ok = false
                let ns = error as NSError
                if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { diskFull = true }
                if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { diskFull = true }
                Log.recovery.error("recovery write failed before removal: \(ns.domain, privacy: .public) \(ns.code)")
            }
        }
        if ok, seq > lastManifestSeq {
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
        return FlushOutcome(ok: ok, written: written, diskFull: diskFull)
    }

    /// A buffer this window removed comes back (a tab moved out and in again, same id): bump its epoch
    /// so no pre-transfer flush can outlive it, and return the new epoch for future flushes.
    @discardableResult
    func readmit(_ id: UUID) -> UInt64 {
        epochs[id, default: 0] &+= 1
        latest[id] = nil
        return epochs[id] ?? 0
    }

    /// Deletes a snapshot whose tombstone is already in a completed manifest.
    func deleteTombstoned(_ ids: [UUID]) {
        for id in ids { try? recovery.deleteSnapshot(recoveryFile: "\(id.uuidString).snapshot") }
    }
}
