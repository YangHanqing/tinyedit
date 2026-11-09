import Foundation

/// What the preview shows for a file, worked out off the main thread.
enum QuickLookContent: Sendable {
    /// Rendered like the editor's preview pane; nil when the file is too large or does not parse.
    case markdown([MarkdownNode]?)
    /// Every other text: highlighted as the editor would, with a one-line JSON document formatted.
    case text(String, spans: [HighlightSpan])

    /// Blocking. Same decoding (BOM, UTF-8, GB18030) and size policy as the editor. Of a file larger than the
    /// preview shows, only the first part is read (cut at a line), so Space on a 2 GB log is instant.
    static func load(_ url: URL) throws -> QuickLookContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let partial = size > HighlightPolicy.offLimit
        var text = (partial ? try FileLoader.loadHead(of: url, maxBytes: HighlightPolicy.offLimit)
                            : try FileLoader.load(from: url)).logicalLF
        let language = EditorLanguage.detect(fileName: url.lastPathComponent, text: text)
        if language == .markdown {
            guard !partial, text.utf8.count <= HighlightPolicy.offLimit else { return .markdown(nil) }
            return .markdown(try? MarkdownDocument.parse(text))
        }
        if text.utf16.count > HighlightPolicy.offLimit {
            text = String(decoding: Array(text.utf16.prefix(HighlightPolicy.offLimit)), as: UTF16.self) + "\n…"
        } else if partial {
            text += "\n…"
        } else if language == .json, !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"),
                  case .formatted(let pretty, _) = JSONFormatter.format(text: text, selection: nil) {
            text = pretty
        }
        let spans = text.utf8.count <= HighlightPolicy.fullLimit
            ? SyntaxHighlighter.spans(language: language, text: text, limit: nil) : []
        return .text(text, spans: spans)
    }
}
