import Foundation

struct BufferMetadata: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var titleIsCustom: Bool?         // absent in manifests written before tab renaming
    var isPinned: Bool?              // absent before pinned tabs
    var fileBookmark: Data?
    var fileDisplayName: String?
    var directoryPath: String?       // absent in manifests written before the title-bar path
    var saveDirectory: String?       // absent before Finder's New Text File
    var recoveryFile: String
    var language: String
    var languageSuggestion: EditorLanguage?
    var languageDetectionSuppressed: Bool?
    var encoding: String
    var lineEnding: String
    var dirty: Bool
    var cursorLocation: Int
    var selectionLength: Int
    var scrollPosition: Double
    var markdownPreviewVisible: Bool
    var markdownPreviewChosen: Bool?  // absent before the default-preview setting; then only `true` was a choice
    var lastSavedContentHash: String?
    var diskContentHash: String?
    var diskModificationDate: Date?
    var diskFileSize: Int?
    var conflict: String
    /// A large-file tab. Its `language` is written as `largeFile`, which builds before 0.7 do not know: they adopt
    /// the snapshot (edits as JSON) as "Recovered N" instead of putting it over the file on a Save.
    var largeFile: LargeFileMeta?

    static let largeFileLanguage = "largeFile"

    init(_ b: EditorBuffer) {
        id = b.id
        title = b.title
        titleIsCustom = b.titleIsCustom
        isPinned = b.isPinned ? true : nil
        fileBookmark = b.fileBookmark
        fileDisplayName = b.fileDisplayName
        directoryPath = b.directoryPath
        saveDirectory = b.saveDirectory
        recoveryFile = b.recoveryFile
        language = b.largeFile != nil ? Self.largeFileLanguage : b.language.rawValue
        largeFile = b.largeFile
        languageSuggestion = b.languageSuggestion
        languageDetectionSuppressed = b.languageDetectionSuppressed
        encoding = b.encoding.rawValue
        lineEnding = b.lineEnding.rawValue
        dirty = b.dirty
        cursorLocation = b.cursorLocation
        selectionLength = b.selectionLength
        scrollPosition = b.scrollPosition
        markdownPreviewVisible = b.markdownPreviewVisible ?? false
        markdownPreviewChosen = b.markdownPreviewVisible != nil
        lastSavedContentHash = b.lastSavedContentHash
        diskContentHash = b.diskContentHash
        diskModificationDate = b.diskModificationDate
        diskFileSize = b.diskFileSize
        conflict = b.conflict.rawValue
    }

    /// Nil when any enum string is unknown. The caller then adopts the snapshot as `Recovered N`
    /// instead of dropping the bytes.
    func makeBuffer() -> EditorBuffer? {
        guard let language = largeFile != nil && language == Self.largeFileLanguage ? .plain : EditorLanguage(rawValue: language),
              let encoding = TextEncoding(rawValue: encoding),
              let lineEnding = LineEnding(rawValue: lineEnding),
              let conflict = ConflictState(rawValue: conflict) else { return nil }
        var b = EditorBuffer(id: id, title: title)
        b.titleIsCustom = titleIsCustom ?? false
        b.isPinned = isPinned ?? false
        b.fileBookmark = fileBookmark
        b.fileDisplayName = fileDisplayName
        b.directoryPath = directoryPath
        b.saveDirectory = saveDirectory
        b.language = language
        b.languageSuggestion = languageSuggestion
        b.languageDetectionSuppressed = languageDetectionSuppressed ?? (language != .plain)
        b.encoding = encoding
        b.lineEnding = lineEnding
        b.dirty = dirty
        b.cursorLocation = cursorLocation
        b.selectionLength = selectionLength
        b.scrollPosition = scrollPosition
        b.markdownPreviewVisible = markdownPreviewChosen == true || markdownPreviewVisible ? markdownPreviewVisible : nil
        b.lastSavedContentHash = lastSavedContentHash
        b.diskContentHash = diskContentHash
        b.diskModificationDate = diskModificationDate
        b.diskFileSize = diskFileSize
        b.conflict = conflict
        b.largeFile = largeFile
        return b
    }
}

struct SessionFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = SessionFile.currentSchemaVersion
    var selectedBufferID: UUID?
    var tabOrder: [UUID] = []
    var buffers: [BufferMetadata] = []
    var closedTabs: [ClosedTabRecord] = []
    var tombstones: [UUID] = []

    init(session: EditorSession) {
        selectedBufferID = session.selectedBufferID
        tabOrder = session.tabOrder
        buffers = session.orderedBuffers.map(BufferMetadata.init)
        closedTabs = Array(session.closedTabs.prefix(EditorSession.maxClosedTabs))
        tombstones = Array(session.tombstones.suffix(EditorSession.maxTombstones))
    }

    init() {}

    /// Drops unknown ids from `tabOrder` and appends buffers it misses. Returns true if it changed anything.
    mutating func repairTabOrder() -> Bool {
        let known = Set(buffers.map(\.id))
        var seen = Set<UUID>()
        var repaired = tabOrder.filter { known.contains($0) && seen.insert($0).inserted }
        for b in buffers where !seen.contains(b.id) { repaired.append(b.id) }
        let changed = repaired != tabOrder
        tabOrder = repaired
        if let sel = selectedBufferID, !known.contains(sel) { selectedBufferID = repaired.first }
        return changed
    }
}
