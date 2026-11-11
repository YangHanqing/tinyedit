import SwiftUI

/// Share the editor's language scanners and theme. Unknown fence labels remain plain text.
enum MarkdownCode {
    static func language(_ hint: String?) -> EditorLanguage {
        guard let name = hint?.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return .plain }
        let aliases: [String: EditorLanguage] = ["js": .javascript, "ts": .typescript, "py": .python,
            "sh": .shell, "bash": .shell, "zsh": .shell, "cs": .csharp, "c#": .csharp,
            "c++": .cpp, "yml": .yaml, "text": .plain, "txt": .plain, "plaintext": .plain]
        return aliases[name] ?? EditorLanguage(rawValue: name) ?? EditorLanguage.from(fileExtension: name)
    }

    static func spans(_ code: String, hint: String?) -> [HighlightSpan] {
        guard code.utf8.count <= HighlightPolicy.fullLimit else { return [] }
        let spans = SyntaxHighlighter.spans(language: language(hint), text: code, limit: nil)
        cache.setObject(Spans(spans), forKey: key(code, hint: hint), cost: spans.count)
        return spans
    }

    /// The colors of a block scanned before. The preview's rows are rebuilt as they scroll into view; without
    /// this each code block showed plain for a moment every time it came back.
    static func cachedSpans(_ code: String, hint: String?) -> [HighlightSpan]? {
        cache.object(forKey: key(code, hint: hint))?.spans
    }

    private final class Spans: Sendable {
        let spans: [HighlightSpan]
        init(_ spans: [HighlightSpan]) { self.spans = spans }
    }

    private static let cache: NSCache<NSString, Spans> = {
        let cache = NSCache<NSString, Spans>()
        cache.totalCostLimit = 400_000
        return cache
    }()

    private static func key(_ code: String, hint: String?) -> NSString { "\(hint ?? "")|\(code)" as NSString }

    @MainActor static func styled(_ code: String, spans: [HighlightSpan], size: CGFloat) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: MarkdownText.plain(code,
            font: .monospacedSystemFont(ofSize: size, weight: .regular)))
        for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= value.length {
            value.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        return value
    }
}

struct MarkdownCodeView: View {
    let language: String?
    let code: String
    @State private var spans: [HighlightSpan]
    @State private var copied = false
    @Environment(\.markdownBodySize) private var bodySize

    init(language: String?, code: String) {
        self.language = language
        self.code = code
        _spans = State(initialValue: MarkdownCode.cachedSpans(code, hint: language) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .font(.caption).buttonStyle(.borderless)
                .task(id: copied) {
                    if copied {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(.horizontal) {
                MarkdownTextView(text: MarkdownCode.styled(code, spans: spans, size: MarkdownStyle.codeSize(body: bodySize)), wraps: false)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .task(id: "\(language ?? "")|\(code)") {
            copied = false
            // The colors on screen stay until the new ones are ready (an edit inside the block moves them by a
            // few characters for a moment, which reads better than the whole block going plain).
            if let cached = MarkdownCode.cachedSpans(code, hint: language) {
                if cached != spans { spans = cached }
                return
            }
            let result = await Task.detached(priority: .userInitiated) { MarkdownCode.spans(code, hint: language) }.value
            if !Task.isCancelled { spans = result }
        }
    }
}
