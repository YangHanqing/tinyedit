import AppKit
import Observation

struct EditorStatus: Equatable {
    var line: Int?
    var column = 1
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var indent = EditorSettings().preferredIndent
    /// What Automatic would give; equal to `indent` unless the status bar overrides it.
    var automaticIndent = EditorSettings().preferredIndent
    var indentOverridden = false
    var languageLabel = EditorLanguage.plain.statusLabel
    /// Done / total task items in the tab; nil when it has none.
    var tasks: TaskList.Counts?
}

@MainActor
@Observable
final class AppState {
    static let shared: AppState = {
        #if DEBUG
        ScreenshotProfile.prepareDefaults()
        if ScreenshotProfile.scene != nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEdit-screenshots-" + UUID().uuidString)
            return AppState(root: root, autoRestore: false)
        }
        #endif
        return AppState()
    }()

    // MARK: Observed by SwiftUI (metadata only; never document text, never per-keystroke state)
    var session = EditorSession()
    private(set) var settings = EditorSettings.load()
    var status = EditorStatus()
    /// Nil while nothing is selected. Written only when the counts change.
    var selectionStats: SelectionStats?
    /// The JSON member around the caret, for the status bar's copy buttons. Written only when it changes.
    var jsonCaret: JSONCaretInfo?
    var jsonContainerSize: JSONContainerSize?
    /// The decodes or picture a JSON value button brought up. Session-only.
    var jsonValueCard: JSONValueCard?
    var toast: ToastModel?
    var find = FindModel()
    var goToLineVisible = false
    var goToLineFocusToken = 0
    var translationInput: TranslationInput?
    var paletteVisible = false
    /// Set when the palette opens: what the tools would find in the text they would run on.
    var paletteInsights: ToolInsights?
    /// The palette was opened with text selected, so the tools run on the selection.
    var paletteOnSelection = false
    var launchGateOpen = false
    var bookmarkBroken: Set<UUID> = []
    var previewBlocks: [MarkdownNode] = []
    var previewMessage: String?
    var highlightReduced = false
    /// File ▸ Open Recent. Read at launch (not in init: it resolves bookmarks), then refreshed by
    /// `noteRecentDocument` and `clearRecentDocuments`.
    var recentURLs: [URL] = []

    // MARK: Not observed
    /// Retains every BufferTextStore until its buffer leaves the session.
    @ObservationIgnored var stores: [UUID: BufferTextStore] = [:]
    @ObservationIgnored let host = EditorTextHost()
    @ObservationIgnored let access = FileAccessManager()
    @ObservationIgnored let root: URL
    @ObservationIgnored let recoveryActor: RecoveryActor
    @ObservationIgnored var highlight: HighlightController!
    @ObservationIgnored var findMatches: FindMatchController!
    /// Where typing in the find field searches from: the selection when find opened, then each match moved to.
    @ObservationIgnored var findAnchor = 0
    @ObservationIgnored var fileURLs: [UUID: URL] = [:]
    @ObservationIgnored var monitors: [UUID: ExternalFileMonitor] = [:]
    @ObservationIgnored var savingIDs: Set<UUID> = []
    @ObservationIgnored var pendingURLs: [URL] = []
    @ObservationIgnored var writtenGeneration: [UUID: UInt64] = [:]
    @ObservationIgnored var manifestSeq: UInt64 = 0
    @ObservationIgnored var flushTask: Task<Void, Never>?
    @ObservationIgnored var dirtyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var languageDetectionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pasteTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pasteTokens: [UUID: UInt64] = [:]
    @ObservationIgnored var pasteDepth = 0
    @ObservationIgnored var generationBeforePaste: UInt64 = 0
    @ObservationIgnored var pasteFillsTab = false
    @ObservationIgnored var selectionBeforePaste: NSRange?
    @ObservationIgnored var lengthBeforePaste = 0
    @ObservationIgnored var imageTextJobs: [UUID: ImageTextJob] = [:]
    @ObservationIgnored var imageTextToken: UInt64 = 0
    @ObservationIgnored var curlJobs: [UUID: CurlJob] = [:]
    @ObservationIgnored var curlToken: UInt64 = 0
    /// The full text of a response shown on a tab's curl card.
    @ObservationIgnored var curlBodies: [UUID: String] = [:]
    /// The last command sent from a tab, for Send Again.
    @ObservationIgnored var curlCommands: [UUID: CurlCommand] = [:]
    /// Where that command was in the tab's text, for Replace.
    @ObservationIgnored var curlSources: [UUID: CurlSource] = [:]
    /// The editor window, set once it exists. Hidden by the red button, never closed.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var previewTask: Task<Void, Never>?
    @ObservationIgnored var selectionStatsTask: Task<Void, Never>?
    @ObservationIgnored var jsonCaretTask: Task<Void, Never>?
    /// Decoding or downloading the picture for `jsonValueCard`.
    @ObservationIgnored var jsonValueTask: Task<Void, Never>?
    @ObservationIgnored var paletteInsightsTask: Task<Void, Never>?
    @ObservationIgnored var selectionStatsBufferID: UUID?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var recoveryFailing = false
    @ObservationIgnored var terminationRefused = false
    @ObservationIgnored var recoveredCounter = 0

    init(root: URL = AppPaths.root, autoRestore: Bool = true) {
        self.root = root
        recoveryActor = RecoveryActor(root: root)
        highlight = HighlightController(host: host)
        highlight.onReducedChanged = { [weak self] v in
            self?.highlightReduced = v
            self?.refreshStatus()
        }
        highlight.onNote = { [weak self] in self?.showToast($0) }
        findMatches = FindMatchController(host: host)
        findMatches.onCountsChanged = { [weak self] count, current, capped in
            self?.setFindCounts(count, current, capped)
        }
        highlight.onRegionRepainted = { [weak self] store, region in self?.findMatches.restore(in: region, store: store) }
        host.onSelectionChange = { [weak self] store in self?.selectionChanged(store) }
        host.onFileDrop = { [weak self] urls, location in self?.dropFiles(urls, at: location) }
        host.onScroll = { [weak self] in self?.viewportChanged() }
        host.onEscape = { [weak self] in
            guard let self else { return false }
            return self.dismissJSONValueCardFromEscape() || self.cancelImageTextFromEscape() || self.dismissCurlFromEscape()
                || self.dismissPasteSuggestionFromEscape()
        }
        host.textView.indentStyle = { [weak self] in self?.activeIndentStyle ?? EditorSettings().preferredIndent }
        host.textView.taskLanguage = { [weak self] in self?.selectedBuffer?.language ?? .plain }
        host.textView.jsonValueMarks = { [weak self] in self?.visibleJSONMarks ?? [] }
        host.textView.onJSONMarkClick = { [weak self] in self?.activateJSONMark(at: $0) }
        host.textView.onPasteBegin = { [weak self] in self?.beginPasteRecognition() }
        host.textView.onPasteEnd = { [weak self] in self?.endPasteRecognition() }
        host.textView.onPasteboard = { [weak self] in self?.handlePasteboard($0) ?? false }
        host.textView.canPasteboard = { [weak self] in
            guard let self, self.activeStore != nil else { return false }
            return PastedImage.canPaste($0, recognizeImages: self.settings.recognizeTextInImages)
        }
        host.textView.inlineCalculationContext = { [weak self] in
            guard let self else { return nil }
            return InlineCalculator.Context(mode: self.settings.inlineCalculation,
                                            language: self.selectedBuffer?.language ?? .plain)
        }
        if autoRestore { Task { await self.restore() } }
    }

    // MARK: Accessors

    var selectedBuffer: EditorBuffer? { session.selectedBufferID.flatMap { session.buffers[$0] } }
    var activeStore: BufferTextStore? { session.selectedBufferID.flatMap { stores[$0] } }
    var allStores: [BufferTextStore] { Array(stores.values) }

    var banner: BannerModel? {
        guard let b = selectedBuffer else { return nil }
        let name = b.displayTitle
        if bookmarkBroken.contains(b.id) {
            return BannerModel(text: String(localized: "Bookmark failed"), actions: [BannerAction(title: String(localized: "Relocate…"), action: .relocate)])
        }
        switch b.conflict {
        case .none: return nil
        case .external:
            if b.externalChange?.kept == true { return nil }
            return BannerModel(text: String(localized: "\(name) changed on disk."), actions: [
                BannerAction(title: String(localized: "Reload From Disk"), action: .reloadFromDisk),
                BannerAction(title: String(localized: "Keep My Version"), action: .keepMyVersion),
                BannerAction(title: String(localized: "Save As…"), action: .saveAs),
            ])
        case .missing:
            return BannerModel(text: String(localized: "File is missing: \(name)."), actions: [BannerAction(title: String(localized: "Save As…"), action: .saveAs)])
        }
    }

    // MARK: Toast

    func showToast(_ text: String, error: Bool = false) {
        toastTask?.cancel()
        toast = ToastModel(text: text, isError: error)
        let id = toast?.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: error ? .seconds(6) : text.count > 32 ? .milliseconds(2500) : .milliseconds(1500))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    func dismissToast() { toast = nil }

    // MARK: Buffers and stores

    @discardableResult
    func makeStore(for buffer: EditorBuffer, text: String) -> BufferTextStore {
        let store = BufferTextStore(id: buffer.id, text: text, settings: settings)
        store.onCharactersEdited = { [weak self] s in self?.characterEdited(s) }
        store.onLineIndexUpdated = { [weak self, weak store] in
            self?.host.refreshRuler()
            if let store { self?.refreshStatus(for: store) }   // the indent guess may have changed
        }
        store.viewState.selection = NSRange(location: buffer.cursorLocation, length: buffer.selectionLength)
        store.scheduleLineIndex(delay: .zero)
        stores[buffer.id] = store
        return store
    }

    /// Below `EditorSession.maxTabs`. A restored session can be over it; it only blocks new tabs.
    var hasRoomForTab: Bool { session.tabOrder.count < EditorSession.maxTabs }

    static var tabLimitMessage: String {
        String(localized: "Tabs are limited to \(EditorSession.maxTabs). Close some to open more.")
    }

    /// Every path that adds a tab asks first; at the limit it says why nothing opened.
    func ensureRoomForTab() -> Bool {
        if hasRoomForTab { return true }
        showToast(Self.tabLimitMessage)
        return false
    }

    /// False when nothing was added: before the launch gate opens, or at the tab limit.
    @discardableResult
    func newTab() -> Bool {
        guard launchGateOpen, ensureRoomForTab() else { return false }
        let buffer = EditorBuffer(title: session.nextUntitledTitle())
        makeStore(for: buffer, text: "")
        session.buffers[buffer.id] = buffer
        session.tabOrder.append(buffer.id)
        host.captureViewState()
        session.selectedBufferID = buffer.id
        flushImmediately()
        return true
    }

    func selectTab(_ id: UUID) {
        guard session.buffers[id] != nil, session.selectedBufferID != id else { return }
        host.captureViewState()
        session.selectedBufferID = id
        scheduleFlush()
        activeBufferChanged()
    }

    /// ⌃Tab and ⌃⇧Tab: the next or previous tab, wrapping around.
    func selectAdjacentTab(_ step: Int) {
        let order = session.tabOrder
        guard order.count > 1, let id = session.selectedBufferID, let i = order.firstIndex(of: id) else { return }
        selectTab(order[((i + step) % order.count + order.count) % order.count])
    }

    /// ⌘1 to ⌘8 pick that tab when it exists; ⌘9 is always the last one.
    func selectTab(number: Int) {
        let order = session.tabOrder
        guard (1...9).contains(number), !order.isEmpty else { return }
        if number == 9 { selectTab(order[order.count - 1]) } else if number <= order.count { selectTab(order[number - 1]) }
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = session.tabOrder.firstIndex(of: id) else { return }
        session.tabOrder.remove(at: from)
        let to = session.tabOrder.firstIndex(of: target) ?? session.tabOrder.endIndex
        session.tabOrder.insert(id, at: to)
        flushImmediately()
    }

    /// Called whenever the visible buffer changes (tab switch, close, restore).
    func activeBufferChanged() {
        guard let b = selectedBuffer, let store = stores[b.id] else { return }
        Task { await checkSelectedFileForExternalChanges() }
        highlight.schedule(store: store, language: b.language, delay: .zero)
        scheduleLanguageDetection(b.id)
        schedulePreview(delay: .zero)
        refreshFindMatches(delay: .zero)
        refreshTaskCounts(b.id)
        setJSONCaret(nil)   // another tab's buttons never stay up while these are found
        refreshJSONCaret(store)
    }

    // MARK: Edit pipeline

    private func characterEdited(_ store: BufferTextStore) {
        let id = store.id
        // Dirty is set synchronously on the keystroke, but written to the observed session only on a transition.
        if session.buffers[id]?.dirty == false { session.buffers[id]?.dirty = true }
        scheduleLanguageDetection(id)
        scheduleDirtyCheck(id)
        scheduleFlush()
        if let lang = session.buffers[id]?.language, id == session.selectedBufferID {
            highlight.schedule(store: store, language: lang)
            schedulePreview()
            refreshFindMatches(delay: .milliseconds(150))
        }
        // Hide a paste-decode card on the first real edit. A paste itself is not one: recognition
        // runs when paste returns, and a keystroke that finds the card already hidden writes nothing.
        clearPasteSuggestionAfterEdit(id)
        clearJSONValueCardAfterEdit(id)
    }

    /// 300 ms after the last edit, hash off the main thread. May only clear `dirty`, and only if
    /// the generation it hashed is still current.
    func scheduleDirtyCheck(_ id: UUID) {
        dirtyTasks[id]?.cancel()
        dirtyTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let store = self.stores[id] else { return }
            self.refreshUntitledTitle(id, store: store)
            self.refreshTaskCounts(id)
            let gen = store.generation
            let text = store.logicalString()
            let saved = self.session.buffers[id]?.lastSavedContentHash
            let hash = await Task.detached(priority: .utility) { ContentHash.logicalHex(text) }.value
            guard store.generation == gen, self.session.buffers[id]?.dirty == true else { return }
            if !DirtyReducer.isDirty(currentLogicalHash: hash, lastSavedContentHash: saved) {
                self.session.buffers[id]?.dirty = false
            }
        }
    }

    /// Untitled tabs are named after the start of their text. Written only when the title changes.
    func refreshUntitledTitle(_ id: UUID, store: BufferTextStore) {
        guard let b = session.buffers[id], b.isUntitled, !b.titleIsCustom,
              !b.title.hasPrefix("Recovered ") || store.length > 0 else { return }
        let ns = store.textStorage.mutableString
        let prefix = ns.substring(with: NSRange(location: 0, length: min(ns.length, 400)))
        let title = EditorBuffer.derivedTitle(fromPrefix: prefix) ?? session.nextUntitledTitle()
        if title != b.title { session.buffers[id]?.title = title }
    }

    /// Renames an Untitled tab. A blank name goes back to naming the tab from its text.
    func renameTab(_ id: UUID, to name: String) {
        guard let b = session.buffers[id], b.isUntitled else { return }
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            guard b.titleIsCustom else { return }
            session.buffers[id]?.titleIsCustom = false
            if let store = stores[id] { refreshUntitledTitle(id, store: store) }
        } else {
            guard name != b.title || !b.titleIsCustom else { return }
            session.buffers[id]?.title = name
            session.buffers[id]?.titleIsCustom = true
        }
        flushImmediately()
    }

    /// Hashes the current text now. The close predicate never trusts the debounced flag.
    func isDirtyNow(_ id: UUID) -> Bool {
        guard let store = stores[id], let b = session.buffers[id] else { return false }
        return DirtyReducer.isDirty(currentLogicalHash: ContentHash.logicalHex(store.logicalString()),
                                    lastSavedContentHash: b.lastSavedContentHash)
    }

    // MARK: Status

    private func selectionChanged(_ store: BufferTextStore) {
        refreshStatus(for: store)
        refreshSelectionStats(store)
        refreshJSONCaret(store)
        if find.visible { findMatches.selectionChanged(store) }
    }

    /// Small selections are counted on the spot. Larger ones are counted off the main thread after a
    /// short pause, so dragging across a big file does not copy it on every mouse move; the previous
    /// counts stay up meanwhile.
    private func refreshSelectionStats(_ store: BufferTextStore) {
        guard store.id == session.selectedBufferID else { return }
        selectionStatsTask?.cancel()
        selectionStatsTask = nil
        let ns = store.textStorage.mutableString
        let ranges = host.textView.selectedRanges.map(\.rangeValue)
            .filter { $0.length > 0 && NSMaxRange($0) <= ns.length }
        let total = ranges.reduce(0) { $0 + $1.length }
        if selectionStatsBufferID != store.id {
            selectionStatsBufferID = store.id
            setSelectionStats(nil)   // another tab's counts never stay up while these are computed
        }
        if total == 0 {
            setSelectionStats(nil)
        } else if total <= SelectionStats.synchronousLimit {
            setSelectionStats(SelectionStats(ranges.map { ns.substring(with: $0) }))
        } else {
            let generation = store.generation
            selectionStatsTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, store.generation == generation else { return }
                let pieces = ranges.map { ns.substring(with: $0) }
                let stats = await Task.detached(priority: .utility) { SelectionStats(pieces) }.value
                guard !Task.isCancelled, store.generation == generation else { return }
                self.setSelectionStats(stats)
            }
        }
    }

    private func setSelectionStats(_ stats: SelectionStats?) {
        if stats != selectionStats { selectionStats = stats }
    }

    func refreshStatus(for store: BufferTextStore? = nil) {
        guard let store = store ?? activeStore, store.id == session.selectedBufferID,
              let buffer = session.buffers[store.id] else { return }
        let (line, column) = LineColumn.compute(in: store.textStorage.mutableString,
                                                location: store.viewState.selection.location,
                                                index: store.lineIndex.flatMap { $0.generation == store.generation ? $0 : nil })
        let reduced = highlightReduced && buffer.language != .plain
        let label = reduced ? String(localized: "Plain Text (reduced)") : buffer.language.statusLabel
        let automatic = automaticIndentStyle(store, language: buffer.language)
        let new = EditorStatus(line: line, column: column, encoding: buffer.encoding, lineEnding: buffer.lineEnding,
                               indent: store.indentOverride ?? automatic, automaticIndent: automatic,
                               indentOverridden: store.indentOverride != nil, languageLabel: label,
                               tasks: store.taskCounts.flatMap { $0.language == buffer.language ? $0.counts : nil })
        if new != status { status = new }
    }

    /// What Tab inserts in the visible buffer: the status-bar choice, else `IndentStyle.resolve`.
    var activeIndentStyle: IndentStyle {
        activeStore?.indentOverride ?? automaticIndentStyle(activeStore, language: selectedBuffer?.language ?? .plain)
    }

    private func automaticIndentStyle(_ store: BufferTextStore?, language: EditorLanguage) -> IndentStyle {
        IndentStyle.resolve(detected: settings.detectIndentation ? store?.detectedIndent : nil, language: language,
                            preferred: settings.preferredIndent)
    }

    /// Nil goes back to detection. Changes only what Tab inserts, never the existing text.
    func setIndentOverride(_ style: IndentStyle?) {
        guard let store = activeStore else { return }
        store.indentOverride = style
        refreshStatus(for: store)
    }

    private func viewportChanged() {
        // Windowed highlighting for 2-5 MB files refreshes on scroll.
        guard let b = selectedBuffer, let store = stores[b.id], store.length > HighlightPolicy.fullLimit / 2 else { return }
        highlight.schedule(store: store, language: b.language)
    }

    // MARK: Settings

    func updateSettings(_ new: EditorSettings) {
        let s = new.clamped()
        guard s != settings else { return }
        let appearanceChanged = s.appearance != settings.appearance
        let iconChanged = s.appIcon != settings.appIcon
        let languageSuggestionsChanged = s.suggestLanguageWhileTyping != settings.suggestLanguageWhileTyping
        let pasteSuggestionsChanged = s.suggestPasteDecodes != settings.suggestPasteDecodes
            || s.suggestPasteLanguage != settings.suggestPasteLanguage
            || s.suggestPasteCleanup != settings.suggestPasteCleanup
            || s.recognizeCurlCommands != settings.recognizeCurlCommands
        settings = s
        if languageSuggestionsChanged {
            for task in languageDetectionTasks.values { task.cancel() }
            languageDetectionTasks.removeAll()
            for id in session.tabOrder { session.buffers[id]?.languageSuggestion = nil }
            if s.suggestLanguageWhileTyping, let id = session.selectedBufferID { scheduleLanguageDetection(id) }
            scheduleFlush()
        }
        if pasteSuggestionsChanged {
            for task in pasteTasks.values { task.cancel() }
            pasteTasks.removeAll()
            for id in session.tabOrder {
                pasteTokens[id] = (pasteTokens[id] ?? 0) &+ 1
                session.buffers[id]?.pasteSuggestion = nil
            }
        }
        s.save()
        if appearanceChanged { s.appearance.apply() }
        if iconChanged { applyAppIcon() }
        if let b = selectedBuffer, let store = stores[b.id] {
            highlight.schedule(store: store, language: b.language, delay: .zero)
        }
        refreshStatus()
    }

    /// Dock icon while this process is running. The title bar reads the same asset directly.
    func applyAppIcon() {
        guard let image = NSImage(named: settings.appIcon.imageName) else { return }
        NSApp.applicationIconImage = image
    }

    func zoom(by delta: Double) {
        var s = settings
        s.fontSize += delta
        updateSettings(s)
    }

    func resetZoom() {
        var s = settings
        s.fontSize = EditorSettings.defaultFontSize
        updateSettings(s)
    }

    // MARK: Language

    func setLanguage(_ language: EditorLanguage) {
        guard let id = session.selectedBufferID, session.buffers[id] != nil else { return }
        languageDetectionTasks[id]?.cancel()
        session.buffers[id]?.languageDetectionSuppressed = true
        session.buffers[id]?.languageSuggestion = nil
        session.buffers[id]?.language = language
        if let store = stores[id] {
            highlight.schedule(store: store, language: language, delay: .zero)
        }
        if session.selectedBufferID == id { host.textView.refreshInlineCalculation() }
        schedulePreview(delay: .zero)
        refreshTaskCounts(id)
        refreshStatus()
        refreshJSONCaret()
        flushImmediately()
    }

    // MARK: Change markers

    func clearChangeMarkers() {
        guard let store = activeStore, !store.changeMarkers.isEmpty else { return }
        store.changeMarkers = []
        host.ruler?.needsDisplay = true
    }
}
