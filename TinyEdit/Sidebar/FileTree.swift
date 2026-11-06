import CoreServices
import Foundation
import Observation

/// One file or folder in the sidebar. Paths have symlinks resolved, like the folders they come from.
struct FileNode: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

/// A visible row: the expanded folders flattened, so the list stays lazy however deep the tree goes.
struct FileTreeRow: Identifiable, Equatable {
    let node: FileNode
    let depth: Int
    /// Set on a folder's top row.
    let rootID: UUID?
    let isExpanded: Bool
    var id: String { node.path }
}

/// The sidebar's folder listings. Folders are read when first expanded, off the main thread, and read again
/// when FSEvents reports a change in them. Only listings and the expanded set are observed.
@MainActor
@Observable
final class FileTreeModel {
    /// Folder path → its entries, folders first. Absent until the folder has been read.
    private(set) var listings: [String: [FileNode]] = [:]
    private(set) var expanded: Set<String> = []
    /// Folders that could not be read (permission, gone).
    private(set) var unreadable: Set<String> = []

    @ObservationIgnored var onRootChanged: (() -> Void)?
    @ObservationIgnored var onExpandedChanged: (() -> Void)?
    @ObservationIgnored private var loading: [String: UInt64] = [:]
    @ObservationIgnored private var loadToken: UInt64 = 0
    @ObservationIgnored private var watchers: [String: DirectoryWatcher] = [:]

    /// Never listed: version-control internals and Finder's own files.
    nonisolated static let hiddenNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd"]

    // MARK: Roots

    func restore(expanded paths: Set<String>, roots: [String]) {
        expanded = paths
        for root in roots { watch(root) }
        for path in paths where roots.contains(where: { Self.isInside(path, root: $0) }) { load(path) }
    }

    /// A new folder starts expanded.
    func addRoot(_ path: String) {
        watch(path)
        expanded.insert(path)
        load(path)
        onExpandedChanged?()
    }

    func removeRoot(_ path: String) {
        watchers[path]?.stop()
        watchers[path] = nil
        let inside = { (p: String) in Self.isInside(p, root: path) }
        for key in Array(listings.keys) where inside(key) { listings[key] = nil }
        for key in Array(loading.keys) where inside(key) { loading[key] = nil }
        expanded = expanded.filter { !inside($0) }
        unreadable = unreadable.filter { !inside($0) }
        onExpandedChanged?()
    }

    func moveRoot(_ old: String, to new: String) {
        let expandedPaths = expanded.filter { Self.isInside($0, root: old) }
            .map { new + $0.dropFirst(old.count) }
        removeRoot(old)
        watch(new)
        expanded.formUnion(expandedPaths)
        for path in expandedPaths { load(path) }
        onExpandedChanged?()
    }

    func markUnavailable(_ root: String) {
        watchers.removeValue(forKey: root)?.stop()
        for path in Array(listings.keys) where Self.isInside(path, root: root) { listings[path] = nil }
        for path in Array(loading.keys) where Self.isInside(path, root: root) { loading[path] = nil }
        unreadable.insert(root)
    }

    func stopWatching() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    // MARK: Expanding

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if listings[path] == nil { load(path) }
        }
        onExpandedChanged?()
    }

    /// Expands every folder between `root` and `path`, so the row for `path` can be shown.
    func reveal(_ path: String, root: String) {
        guard Self.isInside(path, root: root), path != root else { return }
        var changed = false
        var dir = (path as NSString).deletingLastPathComponent
        while Self.isInside(dir, root: root) {
            if !expanded.contains(dir) {
                expanded.insert(dir)
                changed = true
            }
            if listings[dir] == nil { load(dir) }
            if dir == root { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if changed { onExpandedChanged?() }
    }

    func rows(for folders: [WorkspaceFolder]) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for folder in folders {
            let node = FileNode(path: folder.path, name: folder.name, isDirectory: true)
            let open = expanded.contains(folder.path)
            rows.append(FileTreeRow(node: node, depth: 0, rootID: folder.id, isExpanded: open))
            if open { append(children: folder.path, depth: 1, into: &rows) }
        }
        return rows
    }

    private func append(children path: String, depth: Int, into rows: inout [FileTreeRow]) {
        for node in listings[path] ?? [] {
            let open = node.isDirectory && expanded.contains(node.path)
            rows.append(FileTreeRow(node: node, depth: depth, rootID: nil, isExpanded: open))
            if open { append(children: node.path, depth: depth + 1, into: &rows) }
        }
    }

    // MARK: Reading

    func load(_ path: String) {
        loadToken &+= 1
        let token = loadToken
        loading[path] = token
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try Self.list(path) } }.value
            guard let self, self.loading[path] == token else { return }
            self.loading[path] = nil
            switch result {
            case .success(let nodes):
                if self.listings[path] != nodes { self.listings[path] = nodes }
                if self.unreadable.contains(path) { self.unreadable.remove(path) }
                // Expanded subfolders that were read before are kept current too.
            case .failure:
                if self.listings[path] != nil { self.listings[path] = nil }
                if !self.unreadable.contains(path) { self.unreadable.insert(path) }
            }
        }
    }

    /// Folders first, then names in Finder's order.
    nonisolated static func list(_ path: String) throws -> [FileNode] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [])
        return entries.compactMap { entry -> FileNode? in
            let name = entry.lastPathComponent
            guard !hiddenNames.contains(name) else { return nil }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(path: (path as NSString).appendingPathComponent(name), name: name, isDirectory: isDir)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    nonisolated static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: Watching

    private func watch(_ root: String) {
        guard watchers[root] == nil else { return }
        watchers[root] = DirectoryWatcher(path: root) { [weak self] paths, rescan in
            self?.changed(paths, rescan: rescan)
            if rescan { self?.onRootChanged?() }
        }
    }

    /// Re-reads the changed folders that are on screen or were read before.
    private func changed(_ paths: [String], rescan: Bool) {
        var targets = Set<String>()
        for raw in paths {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if listings[path] != nil || expanded.contains(path) { targets.insert(path) }
            if rescan { targets.formUnion(listings.keys.filter { Self.isInside($0, root: path) }) }
        }
        for path in targets { load(path) }
    }
}

/// An FSEvents stream over one folder tree, delivered on the main queue.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String], Bool) -> Void

    init(path: String, handler: @escaping @MainActor ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            var rescan = false
            for i in 0..<count {
                let f = flags[i]
                if f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || f & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rescan = true }
            }
            MainActor.assumeIsolated { watcher.handler(list, rescan) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
