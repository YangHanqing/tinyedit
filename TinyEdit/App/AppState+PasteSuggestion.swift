import AppKit

extension AppState {
    /// Set for the duration of `paste` / `pasteAsPlainText` / `pasteAsRichText`. A drop is not a paste.
    /// Any paste is checked for escape codes and invisible characters, and a one-line paste for decodes.
    /// Language and Format JSON are offered only for a paste that leaves the tab holding nothing but the
    /// pasted text: into an empty (or whitespace-only) tab, or over a selection that covers all of the text.
    func beginPasteRecognition() {
        pasteDepth += 1
        guard pasteDepth == 1 else { return }
        generationBeforePaste = activeStore?.generation ?? 0
        let ranges = host.textView.selectedRanges.map(\.rangeValue)
        selectionBeforePaste = ranges.count == 1 ? ranges[0] : nil
        lengthBeforePaste = activeStore?.length ?? 0
        pasteFillsTab = activeStore.map { store in
            ranges.count == 1 && Self.isBlank(store.textStorage.mutableString, outside: ranges[0])
        } ?? false
    }

    /// The paste was an edit, so it replaces any card showing (edits during a paste do not clear it).
    func endPasteRecognition() {
        pasteDepth = max(0, pasteDepth - 1)
        guard pasteDepth == 0, let store = activeStore, store.generation != generationBeforePaste else { return }
        // The insert replaced the selection, so it starts there and is as long as the length grew plus
        // what it replaced (smart-insert spaces included).
        let pasted = selectionBeforePaste.flatMap { sel -> NSRange? in
            let length = store.length - lengthBeforePaste + sel.length
            guard length > 0, sel.location + length <= store.length else { return nil }
            return NSRange(location: sel.location, length: length)
        }
        schedulePasteRecognition(store, pasted: pasted, fillsTab: pasteFillsTab)
    }

    /// Hides the card. A language guess waiting behind it goes too, so the close button does not reveal it.
    func dismissPasteSuggestion() {
        guard let id = session.selectedBufferID else { return }
        clearPasteSuggestion(id)
        if session.buffers[id]?.languageSuggestion != nil { dismissLanguageSuggestion() }
    }

    /// Escape while the text view is first responder. Yields when marked text wants the key.
    func dismissPasteSuggestionFromEscape() -> Bool {
        guard let id = session.selectedBufferID, session.buffers[id]?.pasteSuggestion != nil else { return false }
        dismissPasteSuggestion()
        return true
    }

    /// The first edit after a suggestion appears hides it. Later keystrokes do not write.
    func clearPasteSuggestionAfterEdit(_ id: UUID) {
        guard pasteDepth == 0 else { return }
        clearPasteSuggestion(id)
    }

    /// Copies the decode and hides the card.
    func copyDecodedPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        dismissPasteSuggestion()
        showToast(String(localized: "Copied"))
    }

    /// Replaces the pasted line, keeping the whitespace around it, as one undo group. A JSON decode also
    /// switches the tab to JSON when the paste filled it. Does not suggest again: the edit is not a
    /// paste, so the card hides and recognition does not restart.
    func replaceWithDecodedPaste(_ candidate: PasteDecodeCandidate) {
        guard let store = activeStore, let range = selectedBuffer?.pasteSuggestion?.decodeRange,
              NSMaxRange(range) <= store.length else { return }
        let fillsTab = Self.isBlank(store.textStorage.mutableString, outside: range)
        replace(range, with: candidate.decoded, select: false)
        if candidate.isJSON, fillsTab, selectedBuffer?.language != .json { setLanguage(.json) }
    }

    /// Removes the escape codes and invisible characters from the pasted text as one undo group. The
    /// cleaned text then gets the usual offer.
    func cleanUpPaste() {
        guard let id = session.selectedBufferID, let store = stores[id],
              let cleanup = session.buffers[id]?.pasteSuggestion?.cleanup else { return }
        let ns = store.textStorage.mutableString
        guard NSMaxRange(cleanup.range) <= ns.length else { return }
        let cleaned = TextCleanup.removingAll(ns.substring(with: cleanup.range))
        replace(cleanup.range, with: cleaned, select: false)   // the edit hides the card
        var messages: [String] = []
        if cleanup.report.ansiSequences > 0 { messages.append(Self.message(for: .removedANSI(cleanup.report.ansiSequences))) }
        if !cleanup.report.invisible.isEmpty {
            messages.append(Self.message(for: .removedInvisible(cleanup.report.invisibleCount, cleanup.report.invisible)))
        }
        showToast(messages.joined(separator: " · "))
        schedulePasteRecognition(store, pasted: NSRange(location: cleanup.range.location, length: (cleaned as NSString).length),
                                 fillsTab: cleanup.fillsTab)
    }

    func applyPastedLanguage() {
        guard let id = session.selectedBufferID, let language = session.buffers[id]?.pasteSuggestion?.language else { return }
        clearPasteSuggestion(id)
        setLanguage(language)
    }

    /// Format JSON over the whole tab (one undo group), and switch the tab to JSON.
    func formatPastedJSON() {
        guard let id = session.selectedBufferID else { return }
        clearPasteSuggestion(id)
        if session.buffers[id]?.language != .json { setLanguage(.json) }
        formatJSON(wholeTab: true)
    }

    /// Off the main thread. A moved generation, a dismiss, or a newer paste drops the result.
    /// Observed state is written only when the card appears or disappears. A cleanup offer for the
    /// pasted text comes first, then the offer to send a pasted curl command; otherwise a paste that filled
    /// the tab gets the language and decode offer, and any other paste the decode offer alone.
    private func schedulePasteRecognition(_ store: BufferTextStore, pasted: NSRange?, fillsTab: Bool) {
        let id = store.id
        pasteTasks[id]?.cancel()
        pasteTasks[id] = nil
        let token = (pasteTokens[id] ?? 0) &+ 1
        pasteTokens[id] = token
        if session.buffers[id]?.pasteSuggestion != nil {
            session.buffers[id]?.pasteSuggestion = nil
        }
        guard let language = session.buffers[id]?.language else { return }
        let ns = store.textStorage.mutableString
        let pastedText = pasted.flatMap { r in
            r.length <= PasteDecodeDetector.maxBytes && NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil
        }
        let text = fillsTab && store.length <= PasteDecodeDetector.maxBytes ? store.logicalString() : nil
        guard pastedText != nil || text != nil else { return }
        let generation = store.generation
        let wholeTab = NSRange(location: 0, length: ns.length)
        let detectCurl = settings.recognizeCurlCommands
        let detectCleanup = settings.suggestPasteCleanup
        let detectDecodes = settings.suggestPasteDecodes
        let detectLanguage = settings.suggestPasteLanguage
        guard detectCurl || detectCleanup || detectDecodes || detectLanguage else { return }
        pasteTasks[id] = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> PasteSuggestion? in
                if detectCleanup, let pastedText, let pasted {
                    let report = TextCleanup.scan(pastedText)
                    if !report.isEmpty {
                        return PasteSuggestion(cleanup: PasteCleanup(report: report, range: pasted, fillsTab: fillsTab))
                    }
                }
                if detectCurl, let command = (pastedText ?? text).flatMap(CurlCommand.parse) {
                    return PasteSuggestion(curl: CurlOffer(command, range: pastedText != nil ? pasted ?? wholeTab : wholeTab))
                }
                if let text {
                    return PasteDecodeDetector.suggestion(in: text, currentLanguage: language,
                                                          suggestDecodes: detectDecodes, suggestLanguage: detectLanguage)
                }
                guard detectDecodes, let pastedText, let pasted else { return nil }
                return PasteDecodeDetector.decodeSuggestion(in: pastedText, at: pasted.location)
            }.value
            guard !Task.isCancelled, let self, store.generation == generation, self.pasteTokens[id] == token,
                  self.session.buffers[id] != nil else { return }
            self.pasteTasks[id] = nil
            if found != nil, let run = self.session.buffers[id]?.curlRun, !run.isSending {
                // A newer offer replaces a finished request's card rather than waiting behind it.
                self.dismissCurl(id)
            }
            if self.session.buffers[id]?.pasteSuggestion != found {
                self.session.buffers[id]?.pasteSuggestion = found
            }
        }
    }

    /// No-op when nothing is showing and nothing is in flight, so a keystroke does not write.
    private func clearPasteSuggestion(_ id: UUID) {
        let pending = pasteTasks[id] != nil
        let showing = session.buffers[id]?.pasteSuggestion != nil
        guard pending || showing else { return }
        if pending {
            pasteTasks[id]?.cancel()
            pasteTasks[id] = nil
            pasteTokens[id, default: 0] &+= 1
        }
        if showing { session.buffers[id]?.pasteSuggestion = nil }
    }

    /// Everything outside `range` is spaces, tabs or line breaks.
    static func isBlank(_ text: NSString, outside range: NSRange) -> Bool {
        let nonBlank = CharacterSet.whitespacesAndNewlines.inverted
        let before = NSRange(location: 0, length: range.location)
        let after = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
        return text.rangeOfCharacter(from: nonBlank, range: before).location == NSNotFound
            && text.rangeOfCharacter(from: nonBlank, range: after).location == NSNotFound
    }
}
