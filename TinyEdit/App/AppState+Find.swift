import AppKit

extension AppState {
    private var searchOptions: NSString.CompareOptions {
        find.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
    }

    /// Searches the live NSMutableString in place: no document copy, no hash, and it stops at the first match.
    private var liveText: NSMutableString? { activeStore?.textStorage.mutableString }

    func showFind(replace: Bool) {
        leaveFullPreview()
        let sel = host.textView.selectedRange()
        if sel.length > 0, sel.length < 1000, let ns = liveText {
            let s = ns.substring(with: sel)
            if !s.contains("\n") { find.query = s }
        }
        findAnchor = sel.location
        if goToLineVisible { goToLineVisible = false }
        find.visible = true
        if replace { find.showReplace = true }
        find.focusReplace = replace
        find.focusToken += 1
        refreshFindMatches(delay: .zero)
    }

    func hideFind() {
        find.visible = false
        findMatches.clear()
        setFindCounts(nil, nil, false)
        host.focus()
    }

    /// Typing in the find field or toggling case: count and highlight again, and select the first
    /// match from where the search started.
    func findQueryChanged() {
        let large = (activeStore?.length ?? 0) > 1_000_000
        refreshFindMatches(delay: large ? .milliseconds(120) : .zero, selectFrom: findAnchor)
    }

    /// Re-searches the active buffer while the card is up: after edits, reloads and tab switches.
    func refreshFindMatches(delay: Duration, selectFrom: Int? = nil) {
        guard find.visible, let store = activeStore else { return }
        findMatches.schedule(store: store, query: find.query, caseSensitive: find.caseSensitive,
                             delay: delay, selectFrom: selectFrom)
    }

    /// Written only when a value changes: the selection moves on every keystroke.
    func setFindCounts(_ count: Int?, _ current: Int?, _ capped: Bool) {
        if find.matchCount != count { find.matchCount = count }
        if find.currentMatch != current { find.currentMatch = current }
        if find.capped != capped { find.capped = capped }
    }

    func findNext() {
        if !find.visible { showFind(replace: false) }
        guard !find.query.isEmpty, let ns = liveText else { return }
        let sel = host.textView.selectedRange()
        let start = sel.location + sel.length
        var r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound {
            r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: 0, length: ns.length))
        }
        reveal(r)
    }

    func findPrevious() {
        if !find.visible { showFind(replace: false) }
        guard !find.query.isEmpty, let ns = liveText else { return }
        let sel = host.textView.selectedRange()
        var r = ns.range(of: find.query, options: searchOptions.union(.backwards),
                         range: NSRange(location: 0, length: sel.location))
        if r.location == NSNotFound {
            r = ns.range(of: find.query, options: searchOptions.union(.backwards), range: NSRange(location: 0, length: ns.length))
        }
        reveal(r)
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
        guard sel.length > 0, !find.query.isEmpty else { return false }
        return ns.substring(with: sel).compare(find.query, options: searchOptions) == .orderedSame
    }

    func replaceCurrent() {
        guard !find.query.isEmpty else { return }
        let tv = host.textView
        if selectionMatchesQuery() {
            tv.insertText(find.replacement, replacementRange: tv.selectedRange()) // one undo step
        }
        findNext()
    }

    func replaceAll() {
        guard !find.query.isEmpty, let ns = liveText else { return }
        var ranges: [NSRange] = []
        var from = 0
        while from <= ns.length {
            let r = ns.range(of: find.query, options: searchOptions, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            ranges.append(r)
            from = r.location + max(r.length, 1)
        }
        guard !ranges.isEmpty else { return }
        let tv = host.textView
        let replacement = LineEnding.normalizeToLF(find.replacement)
        let um = tv.undoManager
        um?.beginUndoGrouping()
        for r in ranges.reversed() where tv.shouldChangeText(in: r, replacementString: replacement) {
            tv.replaceCharacters(in: r, with: replacement)
            tv.didChangeText()
        }
        um?.endUndoGrouping()
        showToast(String(localized: "Replaced \(ranges.count)"))
    }
}
