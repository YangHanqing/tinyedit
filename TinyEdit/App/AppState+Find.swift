import AppKit

extension AppState {
    private var searchOptions: NSString.CompareOptions {
        find.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
    }

    /// The query as a regular expression, when the card is in that mode and it compiles.
    private var findRegex: NSRegularExpression? {
        find.regex ? FindPattern.regex(find.query, caseSensitive: find.caseSensitive) : nil
    }

    /// Searches the live NSMutableString in place: no document copy, no hash, and it stops at the first match.
    private var liveText: NSMutableString? { activeStore?.textStorage.mutableString }

    func showFind(replace: Bool) {
        if !replace, previewVisible,
           previewFull || previewReader.hasFocus || (previewReader.findVisible && window?.firstResponder !== host.textView) {
            return showPreviewFind()
        }
        previewReader.closeFind(focus: false)
        if let doc = activeLargeFile {
            if let (a, b) = doc.selectionRange, a.row == b.row, b.column - a.column < 1000, let text = doc.selectedText(),
               !text.isEmpty {
                find.query = find.regex ? NSRegularExpression.escapedPattern(for: text) : text
            }
            if goToLineVisible { goToLineVisible = false }
            find.visible = true
            if replace { find.showReplace = true }
            find.focusReplace = replace
            find.focusToken += 1
            doc.highlightsMatches = true
            doc.setQuery(find.query, caseSensitive: find.caseSensitive, regex: find.regex)
            doc.refreshFind()
            return
        }
        leaveFullPreview()
        let sel = host.textView.selectedRange()
        if let ns = liveText, sel.length > 0, sel.length < 1000, NSMaxRange(sel) <= ns.length {
            let s = ns.substring(with: sel)
            if !s.contains("\n") { find.query = find.regex ? NSRegularExpression.escapedPattern(for: s) : s }
        }
        findAnchor = min(sel.location, liveText?.length ?? 0)
        if goToLineVisible { goToLineVisible = false }
        find.visible = true
        if replace { find.showReplace = true }
        find.focusReplace = replace
        find.focusToken += 1
        refreshFindMatches(delay: .zero)
    }

    func hideFind() {
        findStepTask?.cancel()
        findStepTask = nil
        if let doc = activeLargeFile {
            doc.highlightsMatches = false
            if doc.isFiltering { doc.setFilter(false) }
            doc.refreshFind()
            largeView.refresh()
        }
        if find.filterLines { find.filterLines = false }
        find.visible = false
        findMatches.clear()
        setFindCounts(nil, nil, false)
        host.focus()
    }

    /// Typing in the find field or toggling case: count and highlight again, and select the first
    /// match from where the search started.
    func findQueryChanged() {
        findStepTask?.cancel()
        findStepTask = nil
        let invalid = find.regex && !find.query.isEmpty && FindPattern.regex(find.query, caseSensitive: true) == nil
        if find.invalidPattern != invalid { find.invalidPattern = invalid }
        if let doc = activeLargeFile {
            doc.highlightsMatches = true
            if find.query.isEmpty, doc.isFiltering { setLargeFilter(false) }
            doc.setQuery(find.query, caseSensitive: find.caseSensitive, regex: find.regex)
            return refreshLargeStatus()
        }
        let large = (activeStore?.length ?? 0) > 1_000_000
        refreshFindMatches(delay: large ? .milliseconds(120) : .zero, selectFrom: findAnchor)
    }

    /// Re-searches the active buffer while the card is up: after edits, reloads and tab switches.
    func refreshFindMatches(delay: Duration, selectFrom: Int? = nil) {
        if let doc = activeLargeFile, find.visible { return doc.refreshFind() }
        guard find.visible, let store = activeStore else { return }
        findMatches.schedule(store: store, query: find.query, caseSensitive: find.caseSensitive, regex: find.regex,
                             delay: delay, selectFrom: selectFrom)
    }

    /// Written only when a value changes: the selection moves on every keystroke.
    func setFindCounts(_ count: Int?, _ current: Int?, _ capped: Bool) {
        if find.matchCount != count { find.matchCount = count }
        if find.currentMatch != current { find.currentMatch = current }
        if find.capped != capped { find.capped = capped }
    }

    func findNext() {
        if previewVisible, previewReader.findVisible { return previewReader.nextMatch() }
        if activeLargeFile != nil { return largeFindNext(forward: true) }
        if !find.visible { showFind(replace: false) }
        guard !find.query.isEmpty, let store = activeStore, let ns = liveText else { return }
        let sel = host.textView.selectedRange()
        let start = min(NSMaxRange(sel), ns.length)
        if find.regex {
            guard let re = findRegex else { return }
            stepRegex(re, store: store, forward: true, from: start)
            return
        }
        var r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound {
            r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: 0, length: ns.length))
        }
        reveal(r)
    }

    func findPrevious() {
        if previewVisible, previewReader.findVisible { return previewReader.nextMatch(forward: false) }
        if activeLargeFile != nil { return largeFindNext(forward: false) }
        if !find.visible { showFind(replace: false) }
        guard !find.query.isEmpty, let store = activeStore, let ns = liveText else { return }
        let sel = host.textView.selectedRange()
        let start = min(sel.location, ns.length)
        if find.regex {
            guard let re = findRegex else { return }
            stepRegex(re, store: store, forward: false, from: start)
            return
        }
        var r = ns.range(of: find.query, options: searchOptions.union(.backwards),
                         range: NSRange(location: 0, length: start))
        if r.location == NSNotFound {
            r = ns.range(of: find.query, options: searchOptions.union(.backwards), range: NSRange(location: 0, length: ns.length))
        }
        reveal(r)
    }

    /// Runs regex Find Next / Previous off the main thread with progress-based cancellation so
    /// backtracking patterns cannot hang the UI and Find Previous never retains all earlier matches.
    private func stepRegex(_ re: NSRegularExpression, store: BufferTextStore, forward: Bool, from offset: Int) {
        findStepTask?.cancel()
        let generation = store.generation
        let query = find.query
        let caseSensitive = find.caseSensitive
        let text = store.logicalString()
        findStepTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> NSRange? in
                let ns = text as NSString
                let clamped = min(max(0, offset), ns.length)
                let cancelled: @Sendable () -> Bool = { Task.isCancelled }
                if forward {
                    let after = FindPattern.matches(re, in: ns, range: NSRange(location: clamped, length: ns.length - clamped),
                                                    limit: 1, isCancelled: cancelled).first?.range
                    if let after { return after }
                    if Task.isCancelled { return nil }
                    return FindPattern.matches(re, in: ns, limit: 1, isCancelled: cancelled).first?.range
                } else {
                    let before = FindPattern.lastMatch(re, in: ns, range: NSRange(location: 0, length: clamped),
                                                       isCancelled: cancelled)
                    if let before { return before }
                    if Task.isCancelled { return nil }
                    return FindPattern.lastMatch(re, in: ns, isCancelled: cancelled)
                }
            }
            let hit = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.activeStore === store, store.generation == generation,
                  self.find.regex, self.find.query == query, self.find.caseSensitive == caseSensitive else { return }
            self.reveal(hit ?? NSRange(location: NSNotFound, length: 0))
        }
    }

    /// The highlight of the current match shows where it is; the card shows "No matches" when there is none.
    private func reveal(_ r: NSRange) {
        guard r.location != NSNotFound else { return }   // the selection does not change
        findAnchor = r.location
        let tv = host.textView
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
    }

    private func selectionMatchesQuery() -> Bool {
        guard let ns = liveText else { return false }
        let sel = host.textView.selectedRange()
        guard sel.length > 0, NSMaxRange(sel) <= ns.length, !find.query.isEmpty else { return false }
        if find.regex {
            guard let re = findRegex,
                  let m = re.firstMatch(in: ns as String, options: [.withTransparentBounds], range: sel) else { return false }
            return m.range == sel
        }
        return ns.substring(with: sel).compare(find.query, options: searchOptions) == .orderedSame
    }

    func replaceCurrent() {
        if activeLargeFile != nil { return largeReplaceCurrent() }
        guard !find.query.isEmpty else { return }
        let tv = host.textView
        if selectionMatchesQuery() {
            let sel = tv.selectedRange()
            var replacement = find.replacement
            if let re = findRegex, let ns = liveText, NSMaxRange(sel) <= ns.length,
               let m = re.firstMatch(in: ns as String, options: [.withTransparentBounds], range: sel) {
                replacement = re.replacementString(for: m, in: ns as String, offset: 0, template: find.replacement)
            }
            tv.insertText(replacement, replacementRange: sel) // one undo step
        }
        findNext()
    }

    func replaceAll() {
        if activeLargeFile != nil { return largeReplaceAll() }
        guard !find.query.isEmpty, let ns = liveText else { return }
        var ranges: [NSRange] = []
        var replacements: [String] = []
        let template = LineEnding.normalizeToLF(find.replacement)
        if find.regex {
            guard let re = findRegex else { return }
            let snapshot = ns.copy() as! NSString
            for m in FindPattern.matches(re, in: snapshot) {
                ranges.append(m.range)
                replacements.append(re.replacementString(for: m, in: snapshot as String, offset: 0, template: template))
            }
        } else {
            var from = 0
            while from <= ns.length {
                let r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                ranges.append(r)
                replacements.append(template)
                from = r.location + max(r.length, 1)
            }
        }
        guard !ranges.isEmpty else { return }
        let tv = host.textView
        let um = tv.undoManager
        tv.breakUndoCoalescing()
        um?.beginUndoGrouping()
        tv.textStorage?.beginEditing()
        var appliedAny = false
        for (r, replacement) in zip(ranges, replacements).reversed() where tv.shouldChangeText(in: r, replacementString: replacement) {
            tv.replaceCharacters(in: r, with: replacement)
            appliedAny = true
        }
        tv.textStorage?.endEditing()
        if appliedAny { tv.didChangeText() }
        um?.endUndoGrouping()
        showToast(String(localized: "Replaced \(ranges.count)"))
    }
}
