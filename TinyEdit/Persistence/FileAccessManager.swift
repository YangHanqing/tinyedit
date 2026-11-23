import Foundation

/// Security-scoped bookmarks and access counting. Identity of a file-backed buffer is its bookmark.
@MainActor
final class FileAccessManager {
    private var counts: [String: Int] = [:]
    /// Maps each started standardized URL path to the key recorded when `start` succeeded,
    /// so `stop` still balances the count if a symlink is deleted or retargeted while open.
    private var startedKeys: [String: [String]] = [:]

    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: [.pathKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                             relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    @discardableResult
    func start(_ url: URL) -> Bool {
        let key = Self.key(url)
        let ok = url.startAccessingSecurityScopedResource()
        if ok {
            counts[key, default: 0] += 1
            startedKeys[url.standardizedFileURL.path, default: []].append(key)
        }
        return ok
    }

    func stop(_ url: URL) {
        let rawPath = url.standardizedFileURL.path
        let key: String
        if var list = startedKeys[rawPath], !list.isEmpty {
            key = list.removeLast()
            startedKeys[rawPath] = list.isEmpty ? nil : list
        } else {
            key = Self.key(url)
        }
        guard let n = counts[key], n > 0 else { return }
        url.stopAccessingSecurityScopedResource()
        counts[key] = n == 1 ? nil : n - 1
    }

    func refreshIfStale(_ bookmark: inout Data, url: URL) throws {
        bookmark = try self.bookmark(for: url)
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
