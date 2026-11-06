import Foundation

enum FileSaveError: Error, Equatable {
    case couldNotSaveFile
    case externalChange
}

struct SavedFileStats: Sendable {
    var rawHash: String
    var logicalHash: String
    var byteSize: Int
    var modificationDate: Date
    var posixPermissions: Int
    var executableBitPreserved: Bool
}

/// The only code that writes user files. Never `Data.write(to:)` on the user URL.
enum FileSaver {
    /// Blocking: call off the main thread.
    static func save(logicalLF: String,
                     to url: URL,
                     encoding: TextEncoding,
                     lineEnding: LineEnding,
                     acknowledgedDiskHash: String?,
                     overwriteConfirmed: Bool,
                     presenter: NSFilePresenter?) throws -> SavedFileStats {
        let fm = FileManager.default
        guard let payload = try? encoding.encode(LineEnding.apply(logicalLF, ending: lineEnding)) else {
            throw FileSaveError.couldNotSaveFile
        }
        let payloadHash = ContentHash.sha256Hex(payload)
        let logicalHash = ContentHash.logicalHex(logicalLF)

        // Previous mode and creation date, best effort. A miss never fails the save.
        let previous = try? fm.attributesOfItem(atPath: url.path)
        let previousMode = (previous?[.posixPermissions] as? NSNumber)?.intValue
        let previousCreation = previous?[.creationDate] as? Date

        // Temp lives in the app container: a file bookmark does not grant sibling create.
        let tmp = fm.temporaryDirectory.appendingPathComponent("tinyedit-save-\(UUID().uuidString).tmp")
        guard (try? payload.write(to: tmp)) != nil else { throw FileSaveError.couldNotSaveFile }
        if let fh = try? FileHandle(forWritingTo: tmp) {
            try? fh.synchronize()
            try? fh.close()
        }
        defer { try? fm.removeItem(at: tmp) }

        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing,
                                                               error: &coordError) { dest in
            do {
                // Authoritative check, inside the coordinator, immediately before bytes change.
                let exists = fm.fileExists(atPath: dest.path)
                var original: Data?
                if exists {
                    original = try? Data(contentsOf: dest)
                    let rawNow = ContentHash.sha256Hex(original ?? Data())
                    if rawNow == payloadHash {
                        return // identical bytes already in place; acknowledge only
                    }
                    if rawNow != acknowledgedDiskHash && !overwriteConfirmed {
                        throw FileSaveError.externalChange
                    }
                }
                try install(tmp: tmp, payload: payload, at: dest, original: exists ? .some(original) : nil)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if coordError != nil { throw FileSaveError.couldNotSaveFile }

        // Restore mode and creation date best effort.
        var attrs: [FileAttributeKey: Any] = [:]
        if let previousMode { attrs[.posixPermissions] = previousMode }
        if let previousCreation { attrs[.creationDate] = previousCreation }
        if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }

        guard let now = try? fm.attributesOfItem(atPath: url.path) else { throw FileSaveError.couldNotSaveFile }
        let mode = (now[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let hadExec = (previousMode ?? 0) & 0o111 != 0
        return SavedFileStats(rawHash: payloadHash, logicalHash: logicalHash, byteSize: payload.count,
                              modificationDate: (now[.modificationDate] as? Date) ?? Date(),
                              posixPermissions: mode,
                              executableBitPreserved: !hadExec || (mode & 0o111) != 0)
    }

    /// Replace via the container temp. If the sandbox grants the file but not its directory and the
    /// replace is refused, fall back to an in-place write, which keeps inode, mode, xattrs and ACLs.
    /// Atomicity across volumes is best effort: `replaceItemAt` may copy.
    /// `original` is nil when the file does not exist, `.some(nil)` when it exists but could not be read.
    private static func install(tmp: URL, payload: Data, at dest: URL, original: Data??) throws {
        let fm = FileManager.default
        do {
            if original != nil {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.copyItem(at: tmp, to: dest)
            }
            return
        } catch {
            Log.files.error("replace failed (\((error as NSError).domain, privacy: .public) \((error as NSError).code)); trying in-place write")
        }
        switch original {
        case nil:
            guard fm.createFile(atPath: dest.path, contents: nil) else { throw FileSaveError.couldNotSaveFile }
            do {
                try writeInPlace(payload, at: dest, original: Data())
            } catch {
                try? fm.removeItem(at: dest) // only the empty file this save created
                throw error
            }
        case .some(nil):
            // Without the old bytes a failed write could not be undone, so the file is left alone.
            throw FileSaveError.couldNotSaveFile
        case .some(let bytes?):
            try writeInPlace(payload, at: dest, original: bytes)
        }
    }

    /// Overwrites `dest` from offset 0 and only then truncates, so no block is freed before the new bytes are
    /// down. If any step fails (disk full, quota, I/O), `original` is written back the same way, which needs
    /// no more space than the file already holds, and the save fails with the file as it was.
    static func writeInPlace(_ payload: Data, at dest: URL, original: Data,
                             write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws {
        func put(_ data: Data) throws {
            let fh = try FileHandle(forWritingTo: dest)
            defer { try? fh.close() }
            try fh.seek(toOffset: 0)
            try write(fh, data)
            try fh.truncate(atOffset: UInt64(data.count))
            try fh.synchronize()
        }
        do {
            try put(payload)
        } catch {
            Log.files.error("in-place write failed; restoring the previous bytes")
            do { try put(original) } catch { Log.files.fault("could not restore the previous bytes") }
            throw FileSaveError.couldNotSaveFile
        }
    }
}
