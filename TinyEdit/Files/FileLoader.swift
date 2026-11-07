import Foundation

struct LoadedFile: Sendable {
    var logicalLF: String
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var logicalHash: String   // SHA-256 of logical LF UTF-8, no BOM
    var rawHash: String       // SHA-256 of the raw bytes on disk
    var byteSize: Int
    var modificationDate: Date?
    var posixPermissions: Int?
}

enum FileOpenError: Error, Equatable {
    case couldNotOpenFile
    case fileTooLarge(bytes: Int)
}

enum FileLoader {
    static let maxOpenBytes = 67_108_864

    enum Decoding: Sendable {
        /// Open: BOM, UTF-8, then GB18030.
        case detect
        /// Reload: the buffer's encoding if the bytes decode as it, otherwise detect. A GB18030 file
        /// whose bytes also happen to be valid UTF-8 stays GB18030.
        case prefer(TextEncoding)
        /// Reopen with Encoding: that encoding or fail.
        case force(TextEncoding)
    }

    /// Blocking: call off the main thread.
    static func load(from url: URL, decoding: Decoding = .detect) throws -> LoadedFile {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxOpenBytes { throw FileOpenError.fileTooLarge(bytes: size) }

        var data: Data?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            data = try? Data(contentsOf: u)
        }
        guard let data, coordError == nil else { throw FileOpenError.couldNotOpenFile }
        if data.count > maxOpenBytes { throw FileOpenError.fileTooLarge(bytes: data.count) }
        return try make(from: data, decoding: decoding,
                        modificationDate: attrs?[.modificationDate] as? Date,
                        permissions: (attrs?[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// The first `maxBytes` of a file too large to open, cut after its last whole line (or, for one long
    /// line, before an unfinished UTF-8 sequence), decoded as `load` would. Blocking: call off the main thread.
    static func loadHead(of url: URL, maxBytes: Int) throws -> LoadedFile {
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            guard let handle = try? FileHandle(forReadingFrom: u) else { return }
            defer { try? handle.close() }
            data = try? handle.read(upToCount: maxBytes)
        }
        guard let data, coordError == nil else { throw FileOpenError.couldNotOpenFile }
        // A GB18030 line can still end on a lone lead byte; earlier characters never shift when the end does.
        let cut = headCut(data)
        for drop in 0..<4 where cut - drop > 0 {
            if let loaded = try? make(from: data.prefix(cut - drop)) { return loaded }
        }
        throw FileOpenError.couldNotOpenFile
    }

    /// Where to cut a file's first bytes so they decode as the whole file would: after the last LF.
    /// In UTF-8 and GB18030 a 0x0A byte is always an LF; UTF-16 (BOM only) looks for the LF code unit.
    static func headCut(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        let n = bytes.count
        if n >= 2, (bytes[0], bytes[1]) == (0xFF, 0xFE) || (bytes[0], bytes[1]) == (0xFE, 0xFF) {
            let little = bytes[0] == 0xFF
            var i = (n & ~1) - 2
            while i >= 2 {
                if little ? (bytes[i] == 0x0A && bytes[i + 1] == 0) : (bytes[i] == 0 && bytes[i + 1] == 0x0A) { return i + 2 }
                i -= 2
            }
            return n & ~1
        }
        if let lf = bytes.lastIndex(of: 0x0A) { return lf + 1 }
        // One long line: drop a trailing UTF-8 sequence that may be unfinished (at most 4 bytes).
        var end = n
        while end > 0, n - end < 4, bytes[end - 1] >= 0x80 {
            end -= 1
            if bytes[end] >= 0xC0 { break }   // lead byte reached
        }
        return end
    }

    /// Pure decode step, split out so tests need no files.
    static func make(from data: Data, decoding: Decoding = .detect,
                     modificationDate: Date? = nil, permissions: Int? = nil) throws -> LoadedFile {
        let result: (text: String, encoding: TextEncoding)?
        switch decoding {
        case .detect: result = try? TextEncoding.decode(data)
        case .prefer(let e): result = (try? TextEncoding.decode(data, as: e)) ?? (try? TextEncoding.decode(data))
        case .force(let e): result = try? TextEncoding.decode(data, as: e)
        }
        guard let (decoded, encoding) = result else { throw FileOpenError.couldNotOpenFile }
        let ending = LineEnding.detect(decoded)
        let logical = LineEnding.normalizeToLF(decoded)
        return LoadedFile(logicalLF: logical, encoding: encoding, lineEnding: ending,
                          logicalHash: ContentHash.logicalHex(logical),
                          rawHash: ContentHash.sha256Hex(data),
                          byteSize: data.count, modificationDate: modificationDate, posixPermissions: permissions)
    }
}
