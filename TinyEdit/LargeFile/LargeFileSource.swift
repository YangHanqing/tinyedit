import Foundation
import Darwin

/// Which file a large-file tab reads, and in what state: another inode means the file was replaced (saved by
/// another app, rotated), a smaller size that it was truncated, a larger one that it was appended to.
struct LargeFileFingerprint: Codable, Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int
    var modified: Double

    init(_ st: stat) {
        device = Int64(st.st_dev)
        inode = UInt64(st.st_ino)
        size = Int(st.st_size)
        modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    static func of(path: String) -> LargeFileFingerprint? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return LargeFileFingerprint(st)
    }

    func isSameFile(as other: LargeFileFingerprint) -> Bool { device == other.device && inode == other.inode }
}

/// Reads a file of any size with `pread` through one open descriptor, keeping at most `cacheBlocks` blocks
/// (16 MB) of it. Not `mmap`: a mapped file that another process truncates (a log rotated with `> app.log`)
/// crashes the reader with SIGBUS, while `pread` just returns fewer bytes. The descriptor keeps a replaced or
/// deleted file's bytes readable, so Save As still works after another app removed it.
final class LargeFileSource: @unchecked Sendable {
    static let blockSize = 256 * 1024
    static let cacheBlocks = 64

    private let fd: Int32
    private let lock = NSLock()
    private var blocks: [Int: Data] = [:]
    /// Least recently used first.
    private var order: [Int] = []
    /// Bumped by every drop: a block read before a drop is not stored after it (it may hold the old end of file).
    private var generation = 0

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileOpenError.couldNotOpenFile }
        self.fd = fd
    }

    deinit { close(fd) }

    /// For a file-system watcher; closed with the source.
    var descriptor: Int32 { fd }

    /// Where the open file is now, after a move or rename.
    var currentPath: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    var fingerprint: LargeFileFingerprint? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return LargeFileFingerprint(st)
    }

    var size: Int { fingerprint?.size ?? 0 }

    /// Straight from the file, past the cache: for scans, which would only push out what is on screen.
    func readDirect(offset: Int, count: Int) -> Data {
        guard count > 0, offset >= 0 else { return Data() }
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var done = 0
            while done < count {
                let r = pread(fd, base + done, count - done, off_t(offset + done))
                if r < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if r == 0 { break }
                done += r
            }
            return done
        }
        if n < count { data.removeSubrange(n..<count) }
        return data
    }

    /// Through the block cache: what is drawn is read again on every scroll step.
    func read(offset: Int, count: Int) -> Data {
        guard count > 0, offset >= 0 else { return Data() }
        if count > Self.blockSize * 4 { return readDirect(offset: offset, count: count) }
        var out = Data()
        out.reserveCapacity(count)
        var position = offset
        let end = offset + count
        while position < end {
            let index = position / Self.blockSize
            let block = cachedBlock(index)
            let from = position - index * Self.blockSize
            guard from < block.count else { break }   // end of file
            let take = min(block.count - from, end - position)
            out.append(block[block.startIndex + from ..< block.startIndex + from + take])
            position += take
            if block.count < Self.blockSize { break }
        }
        return out
    }

    private func cachedBlock(_ index: Int) -> Data {
        lock.lock()
        if let block = blocks[index] {
            if let i = order.firstIndex(of: index) { order.remove(at: i) }
            order.append(index)
            lock.unlock()
            return block
        }
        let readGeneration = generation
        lock.unlock()
        let block = readDirect(offset: index * Self.blockSize, count: Self.blockSize)
        lock.lock()
        defer { lock.unlock() }
        guard generation == readGeneration else { return block }
        blocks[index] = block
        order.removeAll { $0 == index }
        order.append(index)
        while order.count > Self.cacheBlocks { blocks[order.removeFirst()] = nil }
        return block
    }

    /// Frees the cache. Nothing is lost: blocks are read again when needed.
    func dropCache() {
        lock.lock()
        blocks.removeAll()
        order.removeAll()
        generation += 1
        lock.unlock()
    }

    /// After an append: the block that held the old end of the file is incomplete.
    func dropBlocks(from offset: Int) {
        let first = offset / Self.blockSize
        lock.lock()
        for key in blocks.keys where key >= first { blocks[key] = nil }
        order.removeAll { $0 >= first }
        generation += 1
        lock.unlock()
    }

    var cachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocks.values.reduce(0) { $0 + $1.count }
    }
}
