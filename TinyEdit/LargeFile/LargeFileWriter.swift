import Foundation
import Darwin

enum LargeFileSaveError: Error, Equatable {
    case couldNotSave
    case notEnoughSpace(needed: Int)
    case externalChange
    /// The bytes an edit replaces are no longer in the file (rewritten in place): the edits cannot be applied.
    case editsNoLongerMatch
    case cancelled
}

/// A Replace All too large to hold as edits: applied while streaming the file to its new version.
struct LargeFileReplacement: Sendable {
    var query: LargeFileQuery
    var bytes: Data
}

/// Writes the new version of a large file: its bytes up to each edit, the edit's text, then on, in 4 MB pieces,
/// so saving a 2 GB file needs no more memory than a small one. The text goes to a temporary file first;
/// `install` then puts it in place of the file.
enum LargeFileWriter {
    static let chunk = 4 * 1_048_576
    static let tempPrefix = "tinyedit-large-"

    /// Where a save writes the new version first: the container's temporary folder.
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(tempPrefix)\(UUID().uuidString).tmp")
    }

    /// Temporary files of saves cut short by a quit or crash: each can be as large as the file it was saving.
    /// Only ones untouched for an hour, so another instance's running save keeps its file.
    static func removeLeftovers() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(tempPrefix) {
            let url = dir.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Room the save needs on the volume of `url`: the file plus what the edits add, with 64 MB to spare.
    static func checkSpace(_ bytes: Int, at url: URL) throws {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        let needed = bytes + 64 * 1_048_576
        if Int64(needed) > free { throw LargeFileSaveError.notEnoughSpace(needed: needed) }
    }

    /// Blocking. `size` is how much of the file to write (what was indexed); `lineBreak` joins an edit's lines.
    static func write(source: LargeFileSource, size: Int, edits: LargeFileEdits, encoding: TextEncoding,
                      lineBreak: String, replacement: LargeFileReplacement?, to tmp: URL,
                      isCancelled: () -> Bool, progress: (Double) -> Void) throws {
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LargeFileSaveError.couldNotSave }
        defer { close(fd) }

        func put(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var done = 0
                while done < raw.count {
                    let n = Darwin.write(fd, base + done, raw.count - done)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw errno == ENOSPC ? LargeFileSaveError.notEnoughSpace(needed: 0) : LargeFileSaveError.couldNotSave
                    }
                    done += n
                }
            }
        }

        /// Copies `from..<to` of the file, replacing matches when asked.
        func copy(_ from: Int, _ to: Int) throws {
            if let replacement { return try copyReplacing(from, to, replacement) }
            var position = from
            while position < to {
                if isCancelled() { throw LargeFileSaveError.cancelled }
                let data = source.readDirect(offset: position, count: min(chunk, to - position))
                if data.isEmpty { throw LargeFileSaveError.couldNotSave }   // the file shrank under us
                try put(data)
                position += data.count
                progress(Double(position) / Double(max(size, 1)))
            }
        }

        func copyReplacing(_ from: Int, _ to: Int, _ r: LargeFileReplacement) throws {
            let n = r.query.needle.count
            var position = from
            while position < to {
                if isCancelled() { throw LargeFileSaveError.cancelled }
                let want = min(chunk, to - position)
                let raw = source.readDirect(offset: position, count: min(want + n - 1, to - position))
                if raw.isEmpty { throw LargeFileSaveError.couldNotSave }
                var folded = raw
                let phase = r.query.isUTF16 ? position & 1 : 0
                if !r.query.caseSensitive {
                    folded.withUnsafeMutableBytes { LargeFileSearch.fold($0.bindMemory(to: UInt8.self), r.query.encoding, phase: phase) }
                }
                var written = 0
                var failure: Error?
                folded.withUnsafeBytes { p in
                    LargeFileSearch.scan(p.bindMemory(to: UInt8.self), r.query, phase: phase, limit: min(want, raw.count)) { at in
                        do {
                            try put(raw[raw.startIndex + written ..< raw.startIndex + at])
                            try put(r.bytes)
                        } catch {
                            failure = error
                            return false
                        }
                        written = at + n
                        return true
                    }
                }
                if let failure { throw failure }
                // A match that ran into the overlap was written whole; go on after it.
                let end = max(min(want, raw.count), written)
                if end > written { try put(raw[raw.startIndex + written ..< raw.startIndex + end]) }
                position += end
                progress(Double(position) / Double(max(size, 1)))
            }
        }

        var position = 0
        for e in edits.edits {
            // Never skip an edit: one past the end or overlapping another means the offsets are not this file's.
            guard e.start >= position, e.end <= size else { throw LargeFileSaveError.editsNoLongerMatch }
            try copy(position, e.start)
            if !e.lines.isEmpty {
                guard let text = LargeFileText.encode(e.lines.joined(separator: lineBreak), encoding) else {
                    throw LargeFileSaveError.couldNotSave
                }
                try put(text)
                try put(source.readDirect(offset: e.contentEnd, count: e.end - e.contentEnd))
            }
            position = e.end
        }
        try copy(position, size)
        guard fsync(fd) == 0 else { throw LargeFileSaveError.couldNotSave }
    }

    /// Puts `tmp` in place of `url` (or at it, for a new file) under file coordination. A file that is no longer
    /// `expected` (what was there when the save started; nil: nothing) is left alone, even when the user chose to
    /// overwrite: that choice was for the version they were told about, not for lines written during the save.
    /// Blocking.
    static func install(_ tmp: URL, at url: URL, expected: LargeFileFingerprint?,
                        presenter: NSFilePresenter?) throws -> LargeFileFingerprint {
        let fm = FileManager.default
        let previous = try? fm.attributesOfItem(atPath: url.path)
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dest in
            do {
                if fm.fileExists(atPath: dest.path) {
                    let now = LargeFileFingerprint.of(path: dest.path)
                    if now != expected { throw LargeFileSaveError.externalChange }
                    _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure is LargeFileSaveError ? failure : LargeFileSaveError.couldNotSave }
        if coordError != nil { throw LargeFileSaveError.couldNotSave }
        var attrs: [FileAttributeKey: Any] = [:]
        if let mode = previous?[.posixPermissions] { attrs[.posixPermissions] = mode }
        if let created = previous?[.creationDate] { attrs[.creationDate] = created }
        if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }
        guard let fingerprint = LargeFileFingerprint.of(path: url.path) else { throw LargeFileSaveError.couldNotSave }
        return fingerprint
    }
}
