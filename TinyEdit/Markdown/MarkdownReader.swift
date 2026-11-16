import AppKit
import Observation
import SwiftUI

/// A heading owns the following siblings up to the next heading of the same or a higher level.
/// Stable fragment IDs retain folds across edits; paths still address the original, unfiltered tree.
struct MarkdownStructure: Sendable {
    struct Heading: Identifiable, Sendable {
        let id: String
        let path: String
        let level: Int
        let title: String
        let canFold: Bool
    }
    var headings: [Heading] = []
    var ancestors: [String: [String]] = [:]

    init(_ blocks: [MarkdownNode]) {
        var used: Set<String> = []
        func visit(_ nodes: [MarkdownNode], prefix: String, inherited: [String]) {
            var stack: [(level: Int, id: String)] = []
            for (index, node) in nodes.enumerated() {
                if Task.isCancelled { return }
                let path = prefix + String(index)
                if case .heading(let level, let text) = node {
                    while let last = stack.last, last.level >= level { stack.removeLast() }
                    let title = String(text.characters)
                    let base = MarkdownNavigation.slug(title)
                    var id = base, suffix = 0
                    while used.contains(id) { suffix += 1; id = "\(base)-\(suffix)" }
                    used.insert(id)
                    let nextIsContent: Bool
                    if index + 1 == nodes.count { nextIsContent = false }
                    else if case .heading(let next, _) = nodes[index + 1] { nextIsContent = next > level }
                    else { nextIsContent = true }
                    headings.append(Heading(id: id, path: path, level: level, title: title, canFold: nextIsContent))
                    ancestors[path] = inherited + stack.map(\.id)
                    stack.append((level, id))
                } else {
                    ancestors[path] = inherited + stack.map(\.id)
                }
                let parents = ancestors[path] ?? inherited
                switch node {
                case .blockQuote(let children): visit(children, prefix: path + ".", inherited: parents)
                case .list(let list):
                    for (item, value) in list.items.enumerated() {
                        visit(value.blocks, prefix: "\(path).\(item).", inherited: parents)
                    }
                default: break
                }
            }
        }
        visit(blocks, prefix: "", inherited: [])
    }
}

/// Reading UI metadata only. Text, native selections and match arrays stay outside Observation.
/// The same page controller also works in Quick Look without any dependency on AppState.
@MainActor @Observable
final class MarkdownReader {
    struct Jump: Equatable {
        let path: String
        let search: Bool
        let token = UUID()
        var topLevel: String { String(path.prefix { $0 != "." }) }
    }

    let selection = MarkdownSelection()
    var headings: [MarkdownStructure.Heading] = []
    private(set) var headingByPath: [String: MarkdownStructure.Heading] = [:]
    private(set) var collapsed: Set<String> = []
    private(set) var hiddenPaths: Set<String> = []
    private(set) var jump: Jump?
    var findVisible = false
    var query = ""
    var caseSensitive = false
    var regex = false
    var focusToken = 0
    private(set) var matchCount: Int?
    private(set) var currentMatch: Int?
    private(set) var capped = false
    private(set) var invalidPattern = false
    var navigationFailed = false

    @ObservationIgnored private var document: MarkdownSelectionDocument?
    @ObservationIgnored private var identity: AnyHashable?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var matches: [NSRange] = []
    @ObservationIgnored private var pendingFragment: (identity: AnyHashable, fragment: String)?

    init() {
        selection.onDocumentReady = { [weak self] document in self?.install(document) }
    }
    deinit { searchTask?.cancel() }

    var hasFocus: Bool { selection.responder?.window?.firstResponder === selection.responder && selection.responder != nil }

    func beginDocument(identity: AnyHashable?) {
        if self.identity != identity {
            self.identity = identity
            document = nil
            collapsed = []
            hiddenPaths = []
            headings = []
            headingByPath = [:]
            jump = nil
            navigationFailed = false
            closeFind(focus: false)
            selection.invalidateDocument()
            if pendingFragment?.identity != identity { pendingFragment = nil }
        }
    }

    func setDocument(_ blocks: [MarkdownNode], identity: AnyHashable?) {
        beginDocument(identity: identity)
        if selection.setDocument(blocks, identity: identity) {
            document = nil
            searchTask?.cancel()
            matches = []
            matchCount = nil
            currentMatch = nil
        }
    }

    private func install(_ document: MarkdownSelectionDocument) {
        self.document = document
        headings = document.structure.headings
        headingByPath = Dictionary(uniqueKeysWithValues: headings.map { ($0.path, $0) })
        collapsed.formIntersection(Set(headings.filter(\.canFold).map(\.id)))
        updateHiddenPaths()
        refreshSearch()
        if let pending = pendingFragment, pending.identity == identity {
            pendingFragment = nil
            navigate(fragment: pending.fragment)
        }
    }

    func toggleFold(_ heading: MarkdownStructure.Heading) {
        guard heading.canFold else { return }
        selection.clearSelection()
        if !collapsed.insert(heading.id).inserted { collapsed.remove(heading.id) }
        updateHiddenPaths()
    }

    func foldAll() {
        selection.clearSelection()
        collapsed = Set(headings.filter(\.canFold).map(\.id))
        updateHiddenPaths()
    }

    func unfoldAll() { collapsed = []; updateHiddenPaths() }

    private func updateHiddenPaths() {
        hiddenPaths = Set((document?.structure.ancestors ?? [:]).compactMap { path, parents in
            parents.contains(where: collapsed.contains) ? path : nil
        })
    }

    func reveal(path: String, search: Bool = false) {
        if let parents = document?.structure.ancestors[path] {
            collapsed.subtract(parents)
            updateHiddenPaths()
        }
        if let heading = headingByPath[path], collapsed.remove(heading.id) != nil { updateHiddenPaths() }
        jump = Jump(path: path, search: search)
    }

    func navigate(fragment: String) {
        if fragment.isEmpty { reveal(path: "0"); return }
        guard let decoded = fragment.removingPercentEncoding,
              let heading = headings.first(where: { $0.id == decoded.precomposedStringWithCanonicalMapping }) else {
            navigationFailed = true
            return
        }
        reveal(path: heading.path)
    }

    func navigateWhenReady(fragment: String, identity: AnyHashable) {
        if self.identity == identity, document != nil { navigate(fragment: fragment) }
        else { pendingFragment = (identity, fragment) }
    }

    func openFind() {
        if let text = selection.selectedText, !text.contains("\n"), text.utf16.count < 1000 {
            query = regex ? NSRegularExpression.escapedPattern(for: text) : text
        }
        selection.clearSelection()
        findVisible = true
        focusToken += 1
        refreshSearch()
    }

    func closeFind(focus: Bool = true) {
        searchTask?.cancel()
        findVisible = false
        matches = []
        matchCount = nil
        currentMatch = nil
        selection.setSearchMatches([], current: nil)
        if focus, let responder = selection.responder { responder.window?.makeFirstResponder(responder) }
    }

    func refreshSearch() {
        searchTask?.cancel()
        matches = []
        matchCount = nil
        currentMatch = nil
        selection.setSearchMatches([], current: nil)
        invalidPattern = regex && !query.isEmpty && FindPattern.regex(query, caseSensitive: caseSensitive) == nil
        guard findVisible, !query.isEmpty, !invalidPattern, let document else { return }
        let query = query, sensitive = caseSensitive, regex = regex
        searchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let found = FindMatches.ranges(of: query, in: document.text, caseSensitive: sensitive, regex: regex)
                // The copy index also holds list markers and image alt text. Only matches touching
                // an actual text label can be highlighted and navigated in the rendered page.
                var leaf = 0
                let ranges = found.ranges.filter { match in
                    while leaf < document.orderedRanges.count, NSMaxRange(document.orderedRanges[leaf].range) <= match.location { leaf += 1 }
                    return leaf < document.orderedRanges.count && NSIntersectionRange(document.orderedRanges[leaf].range, match).length > 0
                }
                return (ranges: ranges, capped: found.capped)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.matches = result.ranges
            self.matchCount = result.ranges.count
            self.capped = result.capped
            if result.ranges.isEmpty { self.selection.setSearchMatches([], current: nil) }
            else { self.showMatch(0) }
        }
    }

    func nextMatch(forward: Bool = true) {
        guard !matches.isEmpty else { return }
        let index = (currentMatch ?? (forward ? 0 : 1)) - 1
        showMatch((index + (forward ? 1 : -1) + matches.count) % matches.count)
    }

    private func showMatch(_ index: Int) {
        currentMatch = index + 1
        let match = matches[index]
        selection.setSearchMatches(matches, current: match)
        guard let leaf = document?.orderedRanges.first(where: { NSIntersectionRange($0.range, match).length > 0 }) else { return }
        reveal(path: leaf.blockPath, search: true)
    }

    func finishSearchJump() {
        guard let currentMatch, matches.indices.contains(currentMatch - 1) else { return }
        let match = matches[currentMatch - 1]
        guard let leaf = document?.orderedRanges.first(where: { NSIntersectionRange($0.range, match).length > 0 }) else { return }
        selection.revealSearchMatch(match, in: leaf.id)
    }
}

extension EnvironmentValues {
    @Entry var markdownReader: MarkdownReader? = nil
    /// Supplied by the app; Quick Look leaves local document links disabled.
    @Entry var markdownOpenDocument: OpenURLAction? = nil
}
