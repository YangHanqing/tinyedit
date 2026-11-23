import AppKit

/// Text, undo, and per-keystroke state for one buffer. Lives as long as the buffer, including
/// while the tab is inactive and the window is hidden. Not observable by SwiftUI on purpose.
@MainActor
final class BufferTextStore: NSObject, NSTextStorageDelegate {
    struct ViewState: Equatable {
        var selection = NSRange(location: 0, length: 0)
        var scrollFraction = 0.0
    }

    let id: UUID
    let contentStorage = NSTextContentStorage()
    let textStorage: NSTextStorage
    let undoManager = UndoManager()
    private(set) var generation: UInt64 = 0
    var viewState = ViewState()
    /// Fires synchronously for every character edit (not attribute-only edits).
    var onCharactersEdited: ((BufferTextStore) -> Void)?
    var onEditRange: ((BufferTextStore, NSRange, Int) -> Void)?
    /// Bumped on every character edit; stale highlight results are dropped by comparing it.
    private(set) var highlightToken: UInt64 = 0
    /// Every character edit since the last highlight was applied, in current offsets; nil when there was none.
    private(set) var unhighlightedEdits: NSRange?
    private(set) var lineIndex: LineIndex?
    /// The text's own indent style, refreshed with the line index. Nil when nothing is indented.
    private(set) var detectedIndent: IndentStyle?
    /// Chosen from the status bar; wins over detection and the language. Session-only.
    var indentOverride: IndentStyle?
    var onLineIndexUpdated: (() -> Void)?
    /// Lines that differ from the text the last disk reload replaced. Moved through every edit.
    var changeMarkers: [ChangeMarker] = []
    /// Task items for the status bar, with the generation and language they were counted for. Session-only.
    var taskCounts: (counts: TaskList.Counts?, generation: UInt64, language: EditorLanguage)?
    /// Marked values of a JSON tab (pictures, links, colors, times), for the editor's marks after their lines,
    /// with the generation they were found for.
    var jsonMarks: (values: [JSONValueMark], generation: UInt64)?
    private var lineIndexTask: Task<Void, Never>?

    private var notifyEdits = true

    init(id: UUID, text: String, settings: EditorSettings) {
        self.id = id
        let attrs = EditorConfiguration.baseAttributes(fontSize: settings.fontSize, tabWidth: settings.tabWidth)
        textStorage = NSTextStorage(string: text, attributes: attrs)
        super.init()
        contentStorage.textStorage = textStorage
        textStorage.delegate = self
    }

    var length: Int { textStorage.length }

    /// Called when the buffer is closed or discarded: any in-flight work for older generations is stale.
    func invalidate() {
        generation &+= 1
        highlightToken &+= 1
        lineIndexTask?.cancel()
        onCharactersEdited = nil
        onLineIndexUpdated = nil
    }

    func bumpHighlightToken() { highlightToken &+= 1 }

    func highlightApplied() { unhighlightedEdits = nil }

    /// Rebuilds the line index and indent guess off the main thread, 50 ms after the last request.
    func scheduleLineIndex(delay: Duration = .milliseconds(50)) {
        lineIndexTask?.cancel()
        lineIndexTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let gen = generation
            let text = logicalString()
            let (index, indent) = await Task.detached(priority: .utility) {
                (LineIndex.build(text, generation: gen), IndentDetector.detect(text))
            }.value
            guard !Task.isCancelled, gen == generation else { return }
            lineIndex = index
            detectedIndent = indent
            onLineIndexUpdated?()
        }
    }

    /// A copy of the logical (LF) text for recovery, save, and hashing.
    func logicalString() -> String { textStorage.string }

    /// Programmatic replacement (reload, restore). Not an undoable user edit and not a dirtying edit.
    func replaceLogicalText(_ text: String, recordUndo: Bool, settings: EditorSettings) {
        let attrs = EditorConfiguration.baseAttributes(fontSize: settings.fontSize, tabWidth: settings.tabWidth)
        notifyEdits = false
        if !recordUndo { undoManager.disableUndoRegistration() }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: text, attributes: attrs))
        if !recordUndo {
            undoManager.enableUndoRegistration()
            undoManager.removeAllActions()
        }
        notifyEdits = true
        generation &+= 1
        highlightToken &+= 1
        changeMarkers = []
        scheduleLineIndex(delay: .zero)
    }

    /// Base font / tab stops only. Attribute edits do not bump generation or mark dirty.
    func applyBaseAttributes(_ settings: EditorSettings) {
        let attrs = EditorConfiguration.baseAttributes(fontSize: settings.fontSize, tabWidth: settings.tabWidth)
        let range = NSRange(location: 0, length: textStorage.length)
        undoManager.disableUndoRegistration()
        textStorage.beginEditing()
        textStorage.addAttributes(attrs, range: range)
        textStorage.endEditing()
        undoManager.enableUndoRegistration()
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage,
                                 didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange,
                                 changeInLength delta: Int) {
        guard TextEditClassifier.affectsDirtyAndRecovery(editedMask) else { return }
        MainActor.assumeIsolated {
            unhighlightedEdits = HighlightDiff.covering(unhighlightedEdits, edited: editedRange, delta: delta)
            onEditRange?(self, editedRange, delta)
            guard notifyEdits else { return }
            generation &+= 1
            highlightToken &+= 1
            if !changeMarkers.isEmpty {
                changeMarkers = ChangeMarker.adjusting(changeMarkers, editedRange: editedRange, delta: delta)
            }
            scheduleLineIndex()
            onCharactersEdited?(self)
        }
    }
}

enum TextEditClassifier {
    /// True only when characters changed. Highlight and font changes are attribute-only.
    static func affectsDirtyAndRecovery(_ mask: NSTextStorageEditActions) -> Bool {
        mask.contains(.editedCharacters)
    }
}
