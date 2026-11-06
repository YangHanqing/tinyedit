import AppKit

enum LineCommand {
    case duplicate, moveUp, moveDown, delete, join, toggleComment, toggleTask
}

extension AppState {
    // MARK: Line commands

    /// Edit ▸ Line, Toggle Comment and Toggle Task act on the editor. ⌥↑ / ⌥↓ typed into another text field (find,
    /// go to line) keep their usual meaning there instead.
    func runLineCommand(_ command: LineCommand) {
        let tv = host.textView
        if let field = window?.firstResponder as? NSTextView, field !== tv {
            switch command {
            case .moveUp: field.moveToBeginningOfParagraph(nil); return
            case .moveDown: field.moveToEndOfParagraph(nil); return
            default: break
            }
        }
        guard activeStore != nil else { return }
        switch command {
        case .duplicate: tv.duplicateLines()
        case .moveUp: tv.moveLinesUp()
        case .moveDown: tv.moveLinesDown()
        case .delete: tv.deleteLines()
        case .join: tv.joinLines()
        case .toggleComment:
            let language = selectedBuffer?.language ?? .plain
            guard let syntax = LineEditing.commentSyntax(for: language) else {
                showToast(String(localized: "\(language.statusLabel) has no comment syntax"))
                return
            }
            tv.toggleComment(syntax)
        case .toggleTask:
            let language = selectedBuffer?.language ?? .plain
            guard TaskList.supports(language) else {
                showToast(String(localized: "Tasks work in Markdown and Plain Text"))
                return
            }
            tv.toggleTask()
        }
    }

    // MARK: Go to line

    /// Moves the caret to the partner of the bracket next to it, or to the enclosing pair's opener.
    func goToMatchingBracket() {
        guard activeStore != nil else { return }
        host.textView.goToMatchingBracket()
    }

    func showGoToLine() {
        if find.visible { hideFind() }
        goToLineVisible = true
        goToLineFocusToken += 1
    }

    func hideGoToLine() {
        goToLineVisible = false
        host.focus()
    }

    /// Lines in the active buffer, from the line index when it is current.
    var activeLineCount: Int {
        guard let store = activeStore else { return 1 }
        if let index = store.lineIndex, index.generation == store.generation { return index.lineCount }
        return store.textStorage.mutableString.components(separatedBy: "\n").count
    }

    /// Moves the caret to "line" or "line:column" (1-based, clamped) and brings it to the upper third of
    /// the view. False when the input is not a line number.
    @discardableResult
    func goToLine(_ input: String) -> Bool {
        guard let target = LineEditing.parseLineTarget(input), let store = activeStore else { return false }
        let caret = caretOffset(line: target.line, column: target.column, in: store)
        host.textView.setSelectedRange(NSRange(location: caret, length: 0))
        host.reveal(offset: caret)
        return true
    }

    /// The offset of `line` and `column` (1-based, clamped to the text and to the line) in the store's text.
    func caretOffset(line: Int, column: Int?, in store: BufferTextStore) -> Int {
        let ns = store.textStorage.mutableString
        var start = 0
        if let index = store.lineIndex, index.generation == store.generation {
            start = index.starts[min(line, index.lineCount) - 1]
        } else {
            var current = 1
            while current < line, start < ns.length {
                let next = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                if next == start || (next == ns.length && ns.character(at: next - 1) != 0x0A) { break }
                start = next
                current += 1
            }
        }
        let full = ns.lineRange(for: NSRange(location: start, length: 0))
        var end = NSMaxRange(full)
        if end > full.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        return min(start + (column ?? 1) - 1, end)
    }

    // MARK: Task counts

    /// Counts the tab's task items off the main thread for the status bar, unless the count is already for
    /// this generation and language. Called from the dirty-check pause, tab changes, reloads and language changes.
    func refreshTaskCounts(_ id: UUID) {
        guard let store = stores[id], let language = session.buffers[id]?.language else { return }
        let generation = store.generation
        if let counted = store.taskCounts, counted.generation == generation, counted.language == language { return }
        guard TaskList.supports(language) else {
            store.taskCounts = (nil, generation, language)
            refreshStatus(for: store)
            return
        }
        let text = store.logicalString()
        Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { TaskList.counts(in: text, language: language) }.value
            guard let self, self.stores[id] === store, store.generation == generation,
                  self.session.buffers[id]?.language == language else { return }
            store.taskCounts = (counts, generation, language)
            self.refreshStatus(for: store)
        }
    }

    // MARK: Save cleanup

    /// Before a save reads the text: trims trailing whitespace and adds the final newline, as Settings say.
    /// On screen this is one undo step; a tab in the background is edited directly and loses its undo history,
    /// which its old ranges would no longer fit.
    func applySaveCleanup(_ store: BufferTextStore, language: EditorLanguage) {
        let trim = settings.trimTrailingWhitespaceOnSave && language != .markdown && language != .diff
        guard trim || settings.ensureFinalNewline else { return }
        let edits = LineEditing.saveCleanup(in: store.textStorage.mutableString, trimTrailingWhitespace: trim,
                                            ensureFinalNewline: settings.ensureFinalNewline)
        guard !edits.isEmpty else { return }
        if host.activeStore === store {
            host.textView.applyEdits(edits)
        } else {
            let attrs = EditorConfiguration.baseAttributes(fontSize: settings.fontSize, tabWidth: settings.tabWidth)
            store.textStorage.beginEditing()
            for edit in edits.reversed() {
                store.textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.string, attributes: attrs))
            }
            store.textStorage.endEditing()
            store.undoManager.removeAllActions()
        }
    }
}
