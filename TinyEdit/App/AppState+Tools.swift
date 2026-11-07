import AppKit

extension AppState {
    // MARK: Command palette

    func togglePalette() {
        if paletteVisible { hidePalette() } else { showPalette() }
    }

    func hidePalette() {
        guard paletteVisible else { return }
        paletteVisible = false
        paletteCompareSource = nil
        paletteInsightsTask?.cancel()
        paletteInsightsTask = nil
        host.focus()
    }

    private func showPalette() {
        paletteOnSelection = host.textView.selectedRange().length > 0
        paletteInsights = nil
        paletteVisible = true
        analyzeForPalette()
    }

    /// Off the main thread, over the same text the tools would read (the selection, widened to whole
    /// lines for the line tools, or the whole tab), with the tab's language, the curl command around the
    /// caret and the user's language as context. Skipped above `ToolInsights.maxLength`.
    private func analyzeForPalette() {
        paletteInsightsTask?.cancel()
        guard let id = session.selectedBufferID, let store = stores[id] else { return }
        let ns = store.textStorage.mutableString
        let sel = host.textView.selectedRange()
        let target = sel.length > 0 && NSMaxRange(sel) <= ns.length ? sel : NSRange(location: 0, length: ns.length)
        let lineTarget = TextTransform.lineRange(covering: target, in: ns)
        guard lineTarget.length <= ToolInsights.maxLength else { return }
        let text = ns.substring(with: target)
        let lines = ns.substring(with: lineTarget)
        let generation = store.generation
        let preferences = TranslationPreferences.load()
        var context = PaletteContext(language: session.buffers[id]?.language ?? .plain, onSelection: sel.length > 0)
        context.nativeLanguage = TranslationLanguages.canonical(
            preferences.primary.isEmpty ? (TranslationLanguages.systemPreferences.first ?? "en") : preferences.primary)
        if sel.length == 0, let range = CurlCommand.commandRange(around: sel.location, in: ns) {
            context.curlAtCaret = ns.substring(with: range)
        }
        paletteInsightsTask = Task { [weak self] in
            let insights = await Task.detached(priority: .userInitiated) {
                ToolInsights.compute(text: text, lines: lines, context: context)
            }.value
            guard let self, !Task.isCancelled, self.paletteVisible, store.generation == generation else { return }
            self.paletteInsights = insights
        }
    }

    /// Disabled per `paletteInsights` once the analysis is in; until then (or above its size limit) all enabled.
    var paletteCommands: [PaletteCommand] {
        let commands = TextTool.allCases.map { tool in
            PaletteCommand(id: tool.id, title: tool.title, englishTitle: tool.englishTitle, keywords: tool.keywords,
                           category: tool.group.title, count: paletteInsights?.counts[tool]) { [weak self] in self?.run(tool) }
        } + [
            PaletteCommand(id: PaletteCommandID.translateSelection, title: String(localized: "Translate Selection…"), englishTitle: "Translate Selection", keywords: "translation language 翻译", category: String(localized: "Translation")) { [weak self] in self?.presentTranslation() },
            PaletteCommand(id: PaletteCommandID.translateDocument, title: String(localized: "Translate Document…"), englishTitle: "Translate Document", keywords: "translation language 翻译", category: String(localized: "Translation")) { [weak self] in self?.presentTranslation(wholeDocument: true) },
            PaletteCommand(id: "compareWith", title: String(localized: "Compare With…"), englishTitle: "Compare With", keywords: "diff difference compare 比较 对比 差异", category: String(localized: "Compare")) { [weak self] in self?.showComparePalette() },
            PaletteCommand(id: PaletteCommandID.sendCurl, title: String(localized: "Send curl Request"), englishTitle: "Send curl Request", keywords: "http request api run execute 发送 请求 接口", category: "HTTP") { [weak self] in self?.sendCurlAtCursor() }
        ]
        guard let disabled = paletteInsights?.disabled, !disabled.isEmpty else { return commands }
        return commands.map { command in
            var command = command
            command.enabled = !disabled.contains(command.id)
            return command
        }
    }

    /// Searched only, never listed for an empty query: one per open tab, which a hit selects.
    /// "tab" alone lists them all. The title is also searched in English and with its directory.
    var paletteTabCommands: [PaletteCommand] {
        let titles = TabMenuTitles.make(session.orderedBuffers)
        return session.orderedBuffers.map { buffer in
            let id = buffer.id
            return PaletteCommand(id: "tab." + id.uuidString, title: titles[id] ?? buffer.displayTitle,
                                  englishTitle: buffer.title, keywords: "tab 标签 " + (buffer.directoryPath ?? ""),
                                  category: String(localized: "Open Tabs")) { [weak self] in self?.selectTab(id) }
        }
    }

    /// Empty query: Suggested (up to three, when the analysis found something), then one section per group.
    var paletteSections: [PaletteSection] {
        PaletteSection.make(paletteCommands, suggested: paletteInsights?.suggested ?? [])
    }

    // MARK: Text tools

    func run(_ tool: TextTool) {
        switch tool {
        case .formatJSON: runJSON(minify: false)
        case .minifyJSON: runJSON(minify: true)
        default: runTransform(tool)
        }
    }

    /// Transforms the selection, or the whole tab, with surrounding whitespace left in place. Line tools
    /// take the whole lines the selection touches instead.
    /// Computes off the main thread; applies only if the text did not change meanwhile.
    private func runTransform(_ tool: TextTool) {
        guard let id = session.selectedBufferID, let store = stores[id] else { return }
        let sel = host.textView.selectedRange()
        let text = store.logicalString()
        let gen = store.generation
        Task {
            typealias Outcome = (change: (String, NSRange)?, feedback: ToolFeedback?)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Outcome, TextToolError> in
                let ns = text as NSString
                var r = sel.length > 0 ? sel : NSRange(location: 0, length: ns.length)
                guard NSMaxRange(r) <= ns.length else { return .success((nil, nil)) }
                r = tool.isLineTool ? TextTransform.lineRange(covering: r, in: ns) : TextTransform.trimmedRange(r, in: ns)
                guard r.length > 0 else { return .success((nil, ToolFeedback.make(tool, input: "", output: ""))) }
                let input = ns.substring(with: r)
                do {
                    let out = try TextTransform.apply(tool, to: input)
                    return .success((out == input ? nil : (out, r), ToolFeedback.make(tool, input: input, output: out)))
                } catch let e as TextToolError {
                    return .failure(e)
                } catch {
                    return .failure(TextToolError(message: "\(tool.englishTitle) failed"))
                }
            }.value
            guard store.generation == gen, session.selectedBufferID == id else { return }
            switch result {
            case .success(let outcome):
                if let change = outcome.change { replace(change.1, with: change.0, select: sel.length > 0) }
                if let feedback = outcome.feedback { showFeedback(feedback, inSelection: sel.length > 0) }
            case .failure(let e): showToast(localizedToolError(e.message), error: true)
            }
        }
    }

    func showFeedback(_ feedback: ToolFeedback, inSelection: Bool) {
        let message = Self.message(for: feedback)
        showToast(inSelection ? String(localized: "\(message) (in selection)") : message)
    }

    static func message(for feedback: ToolFeedback) -> String {
        switch feedback {
        case .removedInvisible(0, _): return String(localized: "No invisible characters found")
        case .removedInvisible(let n, let kinds):
            let shown = kinds.prefix(3).map { k in
                let code = "U+" + String(format: "%04X", k.value)
                return k.count > 1 ? "\(code) ×\(k.count)" : code
            }
            let detail = shown.joined(separator: ", ") + (kinds.count > 3 ? ", …" : "")
            return String(localized: "Invisible characters removed: \(n)") + " (\(detail))"
        case .removedANSI(0): return String(localized: "No ANSI escape codes found")
        case .removedANSI(let n): return String(localized: "ANSI escape codes removed: \(n)")
        case .removedDuplicates(0): return String(localized: "No duplicate lines found")
        case .removedDuplicates(let n): return String(localized: "Duplicate lines removed: \(n)")
        case .removedBlank(0): return String(localized: "No blank lines found")
        case .removedBlank(let n): return String(localized: "Blank lines removed: \(n)")
        case .trimmed(0): return String(localized: "No trailing whitespace found")
        case .trimmed(let n): return String(localized: "Lines trimmed: \(n)")
        case .sorted(let n): return String(localized: "Lines sorted: \(n)")
        case .reversed(let n): return String(localized: "Lines reversed: \(n)")
        case .shuffled(let n): return String(localized: "Lines shuffled: \(n)")
        case .unchanged(.sortLinesAscending), .unchanged(.sortLinesDescending):
            return String(localized: "Lines are already sorted")
        case .unchanged(.formatJSON): return String(localized: "JSON is already formatted")
        case .unchanged(.minifyJSON): return String(localized: "JSON is already minified")
        case .unchanged: return String(localized: "No changes")
        }
    }

    /// Tool errors stay English until they are shown, so tests can match the thrown text.
    private func localizedToolError(_ message: String) -> String {
        switch message {
        case "Decoded Base64 is not UTF-8 text": return String(localized: "Decoded Base64 is not UTF-8 text")
        case "Invalid percent-encoding": return String(localized: "Invalid percent-encoding")
        case "Not a valid JSON string": return String(localized: "Not a valid JSON string")
        case "Invalid Base64": return String(localized: "Invalid Base64")
        case "Not a JWT": return String(localized: "Not a JWT")
        case "Not a Unix timestamp": return String(localized: "Not a Unix timestamp")
        default:
            let suffix = " failed"
            guard message.hasSuffix(suffix) else { return message }
            let name = String(message.dropLast(suffix.count))
            let localizedName = TextTool.allCases.first { $0.englishTitle == name }?.title ?? name
            return String(localized: "\(localizedName) failed")
        }
    }

    /// One undo group. Selecting the output lets the next tool chain on it (Base64 Decode, then Format JSON).
    /// Paste-decode Replace uses the same path so dirty, recovery, and highlight follow the edit.
    func replace(_ range: NSRange, with text: String, select: Bool) {
        let tv = host.textView
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        tv.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        if select { tv.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length)) }
    }

    // MARK: JSON

    func formatJSON(wholeTab: Bool = false) { runJSON(minify: false, wholeTab: wholeTab) }
    func minifyJSON() { runJSON(minify: true) }

    /// The selection, or the whole tab when nothing is selected or `wholeTab` is set.
    /// Computes off the main thread; applies only if the text did not change meanwhile.
    private func runJSON(minify: Bool, wholeTab: Bool = false) {
        guard let id = session.selectedBufferID, let store = stores[id] else { return }
        let sel = wholeTab ? NSRange(location: 0, length: 0) : host.textView.selectedRange()
        let text = store.logicalString()
        let gen = store.generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                minify ? JSONFormatter.minify(text: text, selection: sel.length > 0 ? sel : nil)
                       : JSONFormatter.format(text: text, selection: sel.length > 0 ? sel : nil)
            }.value
            guard store.generation == gen, session.selectedBufferID == id else { return }
            switch result {
            case .unchanged:
                showFeedback(.unchanged(minify ? .minifyJSON : .formatJSON), inSelection: sel.length > 0)
            case .formatted(let out, let range):
                // An unchanged result never reaches here, so no useless dirty transition.
                replace(range, with: out, select: sel.length > 0)
            case .invalid(let line, let column):
                if let line, let column {
                    showToast(String(localized: "Invalid JSON (line \(line), column \(column))"), error: true)
                } else {
                    showToast(String(localized: "Invalid JSON"), error: true)
                }
            }
        }
    }

    // MARK: Markdown preview

    func togglePreview() {
        guard let id = session.selectedBufferID, let b = session.buffers[id], b.language == .markdown else { return }
        let visible = !previewVisible  // read before the write: an optional-chain assignment evaluates it inside the access
        session.buffers[id]?.markdownPreviewVisible = visible
        schedulePreview(delay: .zero)
        flushImmediately()
    }

    var previewVisible: Bool {
        guard let b = selectedBuffer else { return false }
        return b.language == .markdown && (b.markdownPreviewVisible ?? settings.markdownPreviewByDefault)
    }

    /// The preview covers the whole editor slot, and the text view underneath must not take keys.
    var previewFull: Bool { previewVisible && settings.markdownPreviewLayout == .full }

    /// The title bar's expand button and View ▸ Preview Only: switches the layout every window's preview
    /// takes (a setting, so it is remembered) and shows this tab's preview if it was hidden.
    func togglePreviewLayout() {
        guard let id = session.selectedBufferID, session.buffers[id]?.language == .markdown else { return }
        var s = settings
        s.markdownPreviewLayout = previewFull ? .split : .full
        if !previewVisible {
            s.markdownPreviewLayout = .full
            session.buffers[id]?.markdownPreviewVisible = true
            schedulePreview(delay: .zero)
            flushImmediately()
        }
        updateSettings(s)
    }

    /// Find, Go to Line and the line commands act on the text, so they bring the editor back first.
    func leaveFullPreview() {
        guard previewFull else { return }
        togglePreview()
    }

    /// Keeps the hidden text view out of the key chain while the preview covers it; called on every change
    /// of `previewFull` (tab switch, toggle, layout, settings).
    func applyPreviewConcealment() {
        let full = previewFull
        guard host.textView.isConcealed != full else { return }
        host.textView.isConcealed = full
        if full {
            if window?.firstResponder === host.textView { window?.makeFirstResponder(nil) }
        } else if diff == nil && !paletteVisible {
            host.focus()
        }
    }

    /// 200 ms debounce, parsed off the main thread, dropped if the generation moved on.
    func schedulePreview(delay: Duration = .milliseconds(200)) {
        previewTask?.cancel()
        guard previewVisible, let id = session.selectedBufferID, let store = stores[id] else {
            if !previewBlocks.isEmpty { previewBlocks = [] }
            return
        }
        previewTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let gen = store.generation
            let text = store.logicalString()
            if text.utf8.count > HighlightPolicy.offLimit {
                self.previewBlocks = []
                self.previewMessage = String(localized: "Preview unavailable")
                return
            }
            let parsed: [MarkdownNode]? = await Task.detached(priority: .utility) { try? MarkdownDocument.parse(text) }.value
            guard !Task.isCancelled, store.generation == gen, self.session.selectedBufferID == id else { return }
            if let parsed {
                self.previewBlocks = parsed
                self.previewMessage = nil
            } else {
                self.previewBlocks = []
                self.previewMessage = String(localized: "Preview unavailable")
                Log.editor.error("markdown preview parse failed")
            }
        }
    }
}
