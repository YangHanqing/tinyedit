import Foundation

struct EditorSession: Equatable, Sendable {
    static let maxClosedTabs = 20
    static let maxTombstones = 200
    /// New tabs stop here; restore never drops a buffer to stay under it.
    static let maxTabs = 100

    var selectedBufferID: UUID?
    var tabOrder: [UUID] = []
    var buffers: [UUID: EditorBuffer] = [:]
    var closedTabs: [ClosedTabRecord] = []   // index 0 is most recent
    var tombstones: [UUID] = []

    var orderedBuffers: [EditorBuffer] { tabOrder.compactMap { buffers[$0] } }

    /// Pinned tabs first, each group in its own order. Run after anything that reorders or adds a pinned tab.
    mutating func keepPinnedFirst() {
        let pinned = tabOrder.filter { buffers[$0]?.isPinned == true }
        guard !pinned.isEmpty else { return }
        let order = pinned + tabOrder.filter { buffers[$0]?.isPinned != true }
        if order != tabOrder { tabOrder = order }
    }

    /// Smallest positive integer not used by another Untitled title.
    /// English on purpose: the session stores it, and `EditorBuffer.displayTitle` translates it.
    func nextUntitledTitle() -> String {
        let used = Set(buffers.values.filter(\.isUntitled).map(\.title))
        if !used.contains("Untitled") { return "Untitled" }
        var n = 2
        while used.contains("Untitled \(n)") { n += 1 }
        return "Untitled \(n)"
    }
}
