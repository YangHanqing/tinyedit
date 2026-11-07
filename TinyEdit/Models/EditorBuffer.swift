import Foundation

/// Metadata for one tab. Text is NOT here: it lives in `BufferTextStore`.
/// Per-keystroke state (generation, live cursor, scroll) is deliberately absent so that
/// SwiftUI observation of the session does not fire on every keystroke.
struct EditorBuffer: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    /// An Untitled tab the user renamed keeps `title` instead of naming itself from its text.
    var titleIsCustom = false
    /// Pinned tabs sit first in the strip (`EditorSession.keepPinnedFirst`) and batch closes leave them.
    var isPinned = false
    var fileBookmark: Data?          // nil iff Untitled
    var fileDisplayName: String?
    /// Absolute parent directory, written when the file URL is resolved (open, save, move,
    /// relocate, restore). Nil for Untitled. Optional in the session manifest. Render never
    /// resolves the bookmark; a missing file keeps the last value.
    var directoryPath: String?
    var language: EditorLanguage = .plain
    var languageSuggestion: EditorLanguage?
    var languageDetectionSuppressed = false
    /// Cleanup, language or decode offer after a paste. Session-only: not written to the manifest.
    var pasteSuggestion: PasteSuggestion?
    /// Text being read from a pasted or dropped picture, or read but not inserted. Session-only.
    var imageText: ImageTextState?
    /// A curl request sent from this tab: in flight, its response, or why it failed. Session-only.
    var curlRun: CurlRunState?
    var encoding: TextEncoding = .utf8
    var lineEnding: LineEnding = .lf
    var dirty: Bool = false
    var cursorLocation: Int = 0      // flush-time copy of BufferTextStore.viewState
    var selectionLength: Int = 0
    var scrollPosition: Double = 0
    /// Nil until the user toggles the preview in this tab: it then follows Settings `markdownPreviewByDefault`.
    var markdownPreviewVisible: Bool?
    var lastSavedContentHash: String?  // nil only for Untitled
    var diskContentHash: String?       // last acknowledged raw on-disk bytes
    var diskModificationDate: Date?
    var diskFileSize: Int?
    var conflict: ConflictState = .none {
        didSet { if conflict != .external { externalChange = nil } }
    }
    /// What the current `.external` conflict is about. Cleared whenever the conflict ends or becomes `.missing`.
    var externalChange: ExternalChange?

    var recoveryFile: String { "\(id.uuidString).snapshot" }
    var isUntitled: Bool { fileBookmark == nil }

    /// Session titles stay English (`Untitled`, `Untitled N`, `Recovered N`). Everything else
    /// (a filename, or a name taken from the text) is shown unchanged.
    var displayTitle: String {
        if let n = Self.generatedNumber(title, prefix: "Recovered ") {
            return String(localized: "Recovered \(n)")
        }
        if title == "Untitled" {
            return String(localized: "Untitled")
        }
        if let n = Self.generatedNumber(title, prefix: "Untitled ") {
            return String(localized: "Untitled \(n)")
        }
        return title
    }

    private static func generatedNumber(_ title: String, prefix: String) -> Int? {
        guard title.hasPrefix(prefix) else { return nil }
        let rest = String(title.dropFirst(prefix.count))
        guard let n = Int(rest), n > 0, String(n) == rest else { return nil }
        return n
    }

    /// Records the name and parent directory from a URL that was just resolved. Does not touch the bookmark.
    mutating func rememberFileURL(_ url: URL) {
        fileDisplayName = url.lastPathComponent
        directoryPath = TitlePathFormatting.directory(ofFile: url)
    }

    /// Tab title for an Untitled buffer: the first non-blank line, whitespace collapsed, cut to `limit`
    /// display columns (CJK and other wide characters count as 2). nil when the text is blank,
    /// so the caller falls back to "Untitled".
    static func derivedTitle(fromPrefix text: String, limit: Int = 18) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            .first(where: { !$0.isEmpty }) else { return nil }
        var width = 0
        var out = ""
        for ch in line {
            let w = (ch.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1
            if width + w > limit { return out.trimmingCharacters(in: .whitespaces) + "…" }
            width += w
            out.append(ch)
        }
        return out
    }

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}
