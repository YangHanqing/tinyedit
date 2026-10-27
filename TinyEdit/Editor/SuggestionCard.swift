import AppKit
import SwiftUI

/// Floats over the editor's top-right corner, clear of the scroller. Shows the offer made after a paste
/// ("Pasted text has ANSI escape codes (12) · Remove"; "Looks like JWT" with the decoded text, Copy and
/// Replace; after one that filled the tab, "Looks like JSON · Apply · Format and Apply"), or else the
/// language guess made while typing ("Detected Python · Apply"). Text being read from a pasted or dropped
/// picture, or read but not inserted, comes before all of them, then a curl request sent from the tab.
struct SuggestionCard: View {
    @Environment(AppState.self) private var appState
    /// The reading the preview shows; the first one until another is picked.
    @State private var selected: PasteDecodeKind?
    /// What a curl response card shows.
    @State private var responsePart = ResponsePart.body

    private enum ResponsePart: Hashable { case body, headers }

    var body: some View {
        let buffer = appState.selectedBuffer
        let paste = buffer?.pasteSuggestion
        let language = paste == nil ? buffer?.languageSuggestion : nil
        let imageText = buffer?.imageText
        let curlRun = buffer?.curlRun
        let jsonCard = appState.jsonValueCard.flatMap { $0.bufferID == buffer?.id ? $0 : nil }
        ZStack(alignment: .topTrailing) {
            if let jsonCard {
                jsonValueCard(jsonCard)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let imageText {
                imageTextCard(imageText)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let curlRun {
                curlRunCard(curlRun)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let cleanup = paste?.cleanup {
                cleanupCard(cleanup)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let curl = paste?.curl {
                curlOfferCard(curl.summary)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let paste, !paste.candidates.isEmpty {
                decodeCard(paste)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let paste, let buffer, let offer = LanguageOffer(paste, current: buffer.language) {
                pastedLanguageCard(offer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let language {
                languageCard(language)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, 10)
        .animation(.easeOut(duration: 0.18), value: paste)
        .animation(.easeOut(duration: 0.18), value: language)
        .animation(.easeOut(duration: 0.18), value: imageText)
        .animation(.easeOut(duration: 0.18), value: curlRun)
        .animation(.easeOut(duration: 0.18), value: jsonCard)
        .onChange(of: paste) { _, _ in selected = nil }
        .onChange(of: jsonCard) { _, _ in selected = nil }
        .onChange(of: curlRun) { _, _ in responsePart = .body }
    }

    // MARK: Cards

    @ViewBuilder private func imageTextCard(_ state: ImageTextState) -> some View {
        switch state {
        case .recognizing, .recognizingSlow:
            chrome {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recognizing text in image…")
                        if state == .recognizingSlow {
                            Text("First recognition or model loading may take longer. Please wait…")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(Color.textSecondary)
                    .padding(.trailing, 4)
                    CardButton("Cancel", help: String(localized: "Stop recognizing text"), prominent: false) {
                        appState.cancelImageText()
                    }
                }
            }
        case .offer(let text):
            chrome {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accent)
                        Text("Text from image").foregroundStyle(Color.textPrimary).fontWeight(.semibold)
                        Spacer(minLength: 12)
                        CloseButton(label: String(localized: "Dismiss recognized text")) { appState.cancelImageText() }
                    }
                    preview(text)
                    HStack(spacing: 8) {
                        Spacer()
                        CardButton("Copy", help: String(localized: "Copy recognized text"), prominent: false) {
                            appState.copyRecognizedText()
                        }
                        CardButton("Insert", help: String(localized: "Insert at the cursor"), prominent: true) {
                            appState.insertRecognizedText()
                        }
                    }
                }
                .frame(width: Self.previewWidth)
            }
        }
    }

    private func languageCard(_ language: EditorLanguage) -> some View {
        chrome {
            HStack(spacing: 8) {
                wand
                (Text("Detected ").foregroundStyle(Color.textSecondary) + Text(language.statusLabel).foregroundStyle(Color.textPrimary).fontWeight(.semibold))
                    .lineLimit(1)
                    .padding(.trailing, 4)
                CardButton("Apply", help: String(localized: "Use \(language.statusLabel) syntax highlighting"), prominent: true) {
                    appState.setLanguage(language)
                }
                CloseButton(label: String(localized: "Dismiss language suggestion")) { appState.dismissLanguageSuggestion() }
            }
        }
    }

    private func cleanupCard(_ cleanup: PasteCleanup) -> some View {
        let report = cleanup.report
        return chrome {
            HStack(spacing: 8) {
                wand
                Text("Pasted text has").foregroundStyle(Color.textSecondary)
                if report.ansiSequences > 0 {
                    Text("ANSI escape codes (\(report.ansiSequences))").foregroundStyle(Color.textPrimary).fontWeight(.medium)
                    if !report.invisible.isEmpty { separator }
                }
                if !report.invisible.isEmpty {
                    Text("invisible characters (\(report.invisibleCount))")
                        .foregroundStyle(Color.textPrimary)
                        .fontWeight(.medium)
                        .toolTip(report.invisible.map { "\($0.label) ×\($0.count)" }.joined(separator: "\n"))
                }
                CardButton("Remove", help: String(localized: "Remove them from the pasted text"), prominent: true) {
                    appState.cleanUpPaste()
                }
                .padding(.leading, 4)
                CloseButton(label: String(localized: "Dismiss cleanup suggestion")) { appState.dismissPasteSuggestion() }
            }
        }
    }

    /// After a paste that filled the tab and decodes to nothing: the language, and Format for JSON.
    private func pastedLanguageCard(_ offer: LanguageOffer) -> some View {
        chrome {
            HStack(spacing: 8) {
                wand
                Text("Looks like").foregroundStyle(Color.textSecondary)
                Text(offer.language.statusLabel).foregroundStyle(Color.textPrimary).fontWeight(.semibold)
                    .padding(.trailing, 4)
                if offer.canApply {
                    CardButton("Apply", help: String(localized: "Use \(offer.language.statusLabel) syntax highlighting"),
                               prominent: !offer.canFormat) {
                        appState.applyPastedLanguage()
                    }
                }
                if offer.canFormat {
                    CardButton(offer.canApply ? "Format and Apply" : "Format", help: TextTool.formatJSON.title, prominent: true) {
                        appState.formatPastedJSON()
                    }
                }
                CloseButton(label: String(localized: "Dismiss language suggestion")) { appState.dismissPasteSuggestion() }
            }
        }
    }

    /// The selected reading's result, shown at once. Several readings get a segmented picker; each
    /// segment stays a button, so picking one does not remove the hovered view. A paste with readings
    /// does not show the language offer: Replace switches a JSON decode of a whole tab to JSON anyway.
    private func decodeCard(_ suggestion: PasteSuggestion) -> some View {
        let shown = suggestion.candidates.first { $0.kind == selected } ?? suggestion.candidates[0]
        return chrome {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    wand
                    Text("Looks like").foregroundStyle(Color.textSecondary)
                    if suggestion.candidates.count == 1 {
                        kindTitle(shown.kind)
                            .foregroundStyle(Color.textPrimary)
                            .fontWeight(.semibold)
                            .toolTip(shown.kind.tool.title)
                    } else {
                        ReadingPicker(kinds: suggestion.candidates.map(\.kind), selected: shown.kind, title: kindTitle,
                                      help: { $0.tool.title }) {
                            selected = $0
                        }
                    }
                    Spacer(minLength: 12)
                    CloseButton(label: String(localized: "Dismiss decode suggestion")) { appState.dismissPasteSuggestion() }
                }
                preview(shown.decoded)
                HStack(spacing: 8) {
                    Spacer()
                    CardButton("Copy", help: String(localized: "Copy decoded text"), prominent: false) {
                        appState.copyDecodedPaste(shown.decoded)
                    }
                    CardButton("Replace", help: String(localized: "Replace the pasted text with the decoded text"), prominent: true) {
                        appState.replaceWithDecodedPaste(shown)
                    }
                }
            }
            .frame(width: Self.previewWidth)
        }
    }

    // MARK: JSON value

    /// Brought up by a JSON value button: the value's decodes, or its picture (loading, shown or failed).
    @ViewBuilder private func jsonValueCard(_ card: JSONValueCard) -> some View {
        switch card.content {
        case .decodes(let candidates):
            jsonDecodeCard(card.path, candidates)
        case .loadingImage(let host):
            chrome {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                    Text("Loading picture from \(host)…").foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                    CardButton("Cancel", help: String(localized: "Stop downloading the picture"), prominent: false) {
                        appState.dismissJSONValueCard()
                    }
                }
            }
        case .image(let preview):
            imagePreviewCard(card.path, preview)
        case .failed(let message):
            chrome {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.error)
                        Text("Can't preview the picture").foregroundStyle(Color.textPrimary).fontWeight(.semibold)
                        Spacer(minLength: 12)
                        CloseButton(label: String(localized: "Dismiss picture preview")) { appState.dismissJSONValueCard() }
                    }
                    Text(message)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: Self.previewWidth)
            }
        }
    }

    /// Like the paste decode card, with the member's path and Open in New Tab in place of Replace.
    private func jsonDecodeCard(_ path: String, _ candidates: [PasteDecodeCandidate]) -> some View {
        let shown = candidates.first { $0.kind == selected } ?? candidates[0]
        return chrome {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    wand
                    if candidates.count == 1 {
                        kindTitle(shown.kind)
                            .foregroundStyle(Color.textPrimary)
                            .fontWeight(.semibold)
                            .toolTip(shown.kind.tool.title)
                    } else {
                        ReadingPicker(kinds: candidates.map(\.kind), selected: shown.kind, title: kindTitle,
                                      help: { $0.tool.title }) {
                            selected = $0
                        }
                    }
                    Spacer(minLength: 12)
                    Text(verbatim: path)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    CloseButton(label: String(localized: "Dismiss decode suggestion")) { appState.dismissJSONValueCard() }
                }
                preview(shown.decoded)
                HStack(spacing: 8) {
                    Spacer()
                    CardButton("Copy", help: String(localized: "Copy decoded text"), prominent: false) {
                        appState.copyDecodedJSONValue(shown)
                    }
                    CardButton("Open in New Tab", help: String(localized: "Open the decoded text in a new tab"), prominent: true) {
                        appState.openDecodedJSONValue(shown)
                    }
                }
            }
            .frame(width: Self.previewWidth)
        }
    }

    /// The picture at most at its own size, inside the card's width and `imageMaxHeight`.
    private func imagePreviewCard(_ path: String, _ preview: PreviewImage) -> some View {
        let natural = preview.image.size
        let width = natural.width > 0 ? min(natural.width, Self.previewWidth - 16) : Self.previewWidth - 16
        let height = natural.height > 0 ? min(natural.height, Self.imageMaxHeight) : Self.imageMaxHeight
        let dims = "\(Int(preview.pixelSize.width)) × \(Int(preview.pixelSize.height)) · \(Self.size(preview.data.count))"
        return chrome {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accent)
                    Text(verbatim: path)
                        .foregroundStyle(Color.textPrimary)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: dims)
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 12)
                    CloseButton(label: String(localized: "Dismiss picture preview")) { appState.dismissJSONValueCard() }
                }
                Image(nsImage: preview.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width, maxHeight: height)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.editorBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separator))
                    .toolTip(preview.link?.absoluteString ?? "")
                HStack(spacing: 8) {
                    Spacer()
                    if preview.link != nil {
                        CardButton("Open Link", help: String(localized: "Open the picture in the browser"), prominent: false) {
                            appState.openPreviewImageLink()
                        }
                    }
                    CardButton("Copy Image", help: String(localized: "Copy the picture"), prominent: false) {
                        appState.copyPreviewImage()
                    }
                    CardButton("Save Image…", help: String(localized: "Save the picture to a file"), prominent: true) {
                        appState.savePreviewImage()
                    }
                }
            }
            .frame(width: Self.previewWidth)
        }
    }

    // MARK: curl

    /// A pasted curl command, before anything is sent: where it goes and what it carries.
    private func curlOfferCard(_ summary: CurlSummary) -> some View {
        chrome {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    curlIcon
                    Text("curl request").foregroundStyle(Color.textPrimary).fontWeight(.semibold)
                    Spacer(minLength: 12)
                    CloseButton(label: String(localized: "Dismiss curl request")) { appState.dismissPasteSuggestion() }
                }
                requestLine(summary)
                requestDetails(summary)
                HStack(spacing: 8) {
                    if let option = summary.unsupported {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warning)
                        Text("\(option) is not supported, so this request can't be sent.")
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    } else {
                        Spacer()
                        CardButton("Send", help: String(localized: "Send this request from TinyEdit"), prominent: true) {
                            appState.sendPastedCurl()
                        }
                    }
                }
            }
            .frame(width: Self.previewWidth)
        }
    }

    @ViewBuilder private func curlRunCard(_ run: CurlRunState) -> some View {
        switch run {
        case .sending(let summary, let started):
            chrome {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                    MethodBadge(method: summary.method)
                    Text(verbatim: summary.host).foregroundStyle(Color.textPrimary).lineLimit(1)
                    Text(started, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                        .padding(.trailing, 4)
                    CardButton("Cancel", help: String(localized: "Stop the request"), prominent: false) {
                        appState.dismissCurl()
                    }
                }
            }
        case .finished(let summary, let result):
            responseCard(summary, result)
        case .failed(let summary, let message):
            chrome {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.error)
                        Text("Request failed").foregroundStyle(Color.textPrimary).fontWeight(.semibold)
                        Spacer(minLength: 12)
                        CloseButton(label: String(localized: "Dismiss curl request")) { appState.dismissCurl() }
                    }
                    requestLine(summary)
                    Text(message)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        CardButton("Send Again", help: String(localized: "Send the same request again"), prominent: true) {
                            appState.resendCurl()
                        }
                    }
                }
                .frame(width: Self.previewWidth)
            }
        }
    }

    private func responseCard(_ summary: CurlSummary, _ result: CurlResult) -> some View {
        let color = result.status < 300 ? Color.success : result.status < 400 ? Color.accent : Color.error
        let icon = result.status < 300 ? "checkmark.circle.fill"
            : result.status < 400 ? "arrow.uturn.right.circle.fill" : "exclamationmark.circle.fill"
        let showsHeaders = responsePart == .headers && !result.headers.isEmpty
        return chrome {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(color)
                    Text(verbatim: "\(result.status) \(result.reason)".trimmingCharacters(in: .whitespaces))
                        .foregroundStyle(color)
                        .fontWeight(.semibold)
                    Text(verbatim: "· \(Self.elapsed(result.elapsed)) · \(Self.size(result.byteCount))")
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    CloseButton(label: String(localized: "Dismiss curl request")) { appState.dismissCurl() }
                }
                HStack(spacing: 8) {
                    requestLine(summary)
                    Spacer(minLength: 8)
                    if !result.headers.isEmpty {
                        ReadingPicker(kinds: [ResponsePart.body, .headers], selected: showsHeaders ? .headers : .body,
                                      title: { $0 == .body ? Text("Body") : Text("Headers \(result.headers.count)") },
                                      help: { _ in "" }) { responsePart = $0 }
                    }
                }
                if showsHeaders {
                    preview(result.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                } else {
                    switch result.body {
                    case .text(let text, _): preview(text)
                    case .empty: responseNote(Text("The response has no body."))
                    case .binary(let mime):
                        responseNote(Text("Binary response (\(mime ?? "application/octet-stream")) is not shown."))
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    CardButton("Send Again", help: String(localized: "Send the same request again"), prominent: false) {
                        appState.resendCurl()
                    }
                    if case .text = result.body {
                        CardButton("Copy", help: String(localized: "Copy the response body"), prominent: false) {
                            appState.copyCurlResponse()
                        }
                        CardButton("Replace", help: String(localized: "Replace the curl command with the response body"), prominent: false) {
                            appState.replaceCurlCommandWithResponse()
                        }
                        CardButton("Open in New Tab", help: String(localized: "Open the response body in a new tab"), prominent: true) {
                            appState.openCurlResponse()
                        }
                    }
                }
            }
            .frame(width: Self.previewWidth)
        }
    }

    /// `GET example.com/v1/users?page=2`, the host stronger than the path.
    private func requestLine(_ summary: CurlSummary) -> some View {
        HStack(spacing: 6) {
            MethodBadge(method: summary.method)
            (Text(verbatim: summary.host).foregroundStyle(Color.textPrimary).fontWeight(.medium)
                + Text(verbatim: summary.path).foregroundStyle(Color.textSecondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .toolTip(summary.host + summary.path)
        }
    }

    /// `Headers 12 · Sends cookies · Body 182 bytes JSON`; what carries a login stands out.
    private func requestDetails(_ summary: CurlSummary) -> some View {
        var parts: [Text] = [Text("Headers \(summary.headerNames.count)").foregroundStyle(Color.textSecondary)]
        if summary.sendsCookies { parts.append(Text("Sends cookies").foregroundStyle(Color.warning)) }
        if summary.sendsCredentials { parts.append(Text("Sends credentials").foregroundStyle(Color.warning)) }
        if let kind = summary.bodyKind {
            let kindText: Text = switch kind {
            case .json: Text(verbatim: "JSON")
            case .form: Text("form")
            case .multipart: Text(verbatim: "multipart")
            case .text: Text("text")
            }
            parts.append(Text("Body \(Self.size(summary.bodyBytes))").foregroundStyle(Color.textSecondary)
                         + Text(verbatim: " ").foregroundStyle(Color.textSecondary)
                         + kindText.foregroundStyle(Color.textSecondary))
        }
        let dot = Text(verbatim: " · ").foregroundStyle(Color.textTertiary)
        let line = parts.dropFirst().reduce(parts[0]) { $0 + dot + $1 }
        return line
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .toolTip(summary.headerNames.joined(separator: "\n"))
    }

    private func responseNote(_ text: Text) -> some View {
        text
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.previewPadding.width)
            .padding(.vertical, Self.previewPadding.height)
            .background(Color.editorBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separator))
    }

    private var curlIcon: some View {
        Image(systemName: "network")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accent)
    }

    private static func elapsed(_ duration: Duration) -> String {
        let ms = Int((duration / .milliseconds(1)).rounded())
        return ms < 1_000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1_000)
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The language part of a paste offer, as the tab is now: the language may have been changed since.
    private struct LanguageOffer {
        var language: EditorLanguage
        var canApply: Bool
        var canFormat: Bool

        init?(_ suggestion: PasteSuggestion, current: EditorLanguage) {
            guard let language = suggestion.language ?? (suggestion.canFormatJSON ? .json : nil) else { return nil }
            self.language = language
            canApply = language != current
            canFormat = suggestion.canFormatJSON && language == .json
            guard canApply || canFormat else { return nil }
        }
    }

    // MARK: Parts

    private func chrome(@ViewBuilder _ content: () -> some View) -> some View {
        content().floatingCard()
    }

    private var wand: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accent)
    }

    private var separator: some View {
        Text(verbatim: "·").foregroundStyle(Color.textTertiary)
    }

    private func kindTitle(_ kind: PasteDecodeKind) -> Text {
        switch kind {
        case .jwt: Text(verbatim: "JWT")
        case .jsonString: Text("JSON string")
        case .base64: Text("Base64")
        case .url: Text("URL-encoded")
        case .unicodeEscape: Text("Unicode escapes")
        case .timestamp: Text("Unix timestamp")
        }
    }

    private func preview(_ decoded: String) -> some View {
        let shown = Self.clipped(decoded)
        return ScrollView {
            Text(shown)
                .font(.system(size: Self.previewFontSize, design: .monospaced))
                .lineSpacing(Self.previewLineSpacing)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.previewPadding.width)
                .padding(.vertical, Self.previewPadding.height)
        }
        .frame(height: Self.height(of: shown))
        .background(Color.editorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separator))
    }

    private static let previewWidth: CGFloat = 380
    private static let previewPadding = CGSize(width: 10, height: 8)
    private static let previewFontSize: CGFloat = 12
    private static let previewLineSpacing: CGFloat = 2
    private static let previewMaxHeight: CGFloat = 180
    private static let previewCharLimit = 2_000
    private static let imageMaxHeight: CGFloat = 260

    private static func clipped(_ decoded: String) -> String {
        guard decoded.count > previewCharLimit else { return decoded }
        return String(decoded.prefix(previewCharLimit)) + "…"
    }

    /// Caps a long decode so the text view stays small. Copy and Replace still use the full string.
    private static func height(of text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: previewFontSize, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = previewLineSpacing
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: previewWidth - 2 * previewPadding.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style])
        return min(previewMaxHeight, ceil(rect.height) + 2 * previewPadding.height)
    }
}

extension View {
    /// The chrome of the cards floating over the editor's top-right corner (suggestions, find).
    func floatingCard(leading: CGFloat = 12) -> some View {
        font(.system(size: 12))
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color.chromeBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.separator))
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            .fixedSize()
    }
}

/// A small rounded button. The prominent one is filled with the accent; the other has a quiet fill.
struct CardButton: View {
    let title: LocalizedStringKey
    let help: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, help: String, prominent: Bool, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.onAccent : Color.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(prominent ? Color.accent : Color.tabHoverBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.textPrimary.opacity(hovering ? 0.07 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressedOpacityStyle())
        .onHover { hovering = $0 }
        .toolTip(help)
    }
}

/// The readings (or a response's parts) as a segmented control: the selected one raised, the others plain.
private struct ReadingPicker<Kind: Hashable>: View {
    let kinds: [Kind]
    let selected: Kind
    let title: (Kind) -> Text
    let help: (Kind) -> String
    let select: (Kind) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds, id: \.self) { kind in
                let isSelected = kind == selected
                Button { select(kind) } label: {
                    title(kind)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(isSelected ? Color.controlRaised : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(PressedOpacityStyle())
                .toolTip(help(kind))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.tabHoverBackground, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A request method in a small capsule; methods that change something on the server stand out.
private struct MethodBadge: View {
    let method: String

    var body: some View {
        let safe = ["GET", "HEAD", "OPTIONS"].contains(method)
        Text(verbatim: method)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(safe ? Color.textSecondary : Color.warning)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(safe ? Color.tabHoverBackground : Color.warningBackground, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// The × at the card's trailing end, with a hover background like the title-bar buttons.
struct CloseButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Color.textSecondary : Color.textTertiary)
                .frame(width: 20, height: 20)
                .background(hovering ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(label)
        .accessibilityLabel(label)
    }
}

struct PressedOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
