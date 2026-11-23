import AppKit
import ImageIO

/// What the status bar's JSON buttons would act on.
struct JSONCaretInfo: Equatable {
    var path: String
    var hasKey: Bool
    /// Open Value is offered for strings, objects and arrays, not for numbers, booleans or null.
    var canOpen: Bool
    /// Links, pictures, decodes, times and colors in the value.
    var value = JSONValueInsight()
}

extension JSONCaretInfo {
    init(_ m: JSONMember, in u: [UInt16]) {
        self.init(path: m.pathText, hasKey: m.key != nil, canOpen: m.kind != .scalar, value: JSONValueInsight(m, in: u))
    }
}

/// The card a JSON value button brought up over the editor: the value's decodes, or its picture.
struct JSONValueCard: Equatable {
    enum Content: Equatable {
        case decodes([PasteDecodeCandidate])
        case loadingImage(host: String)
        case image(PreviewImage)
        case failed(String)
    }

    var bufferID: UUID
    /// The member's path; the card goes when the caret leaves that member.
    var path: String
    var content: Content
}

/// A picture shown on the JSON value card. Compared by identity: it does not change once loaded.
struct PreviewImage: Equatable {
    let id = UUID()
    let image: NSImage
    let data: Data
    let pixelSize: CGSize
    /// Where it was downloaded from; nil for a `data:` URI.
    let link: URL?
    let suggestedName: String

    static func == (a: PreviewImage, b: PreviewImage) -> Bool { a.id == b.id }
}

extension AppState {
    /// Finds the member around the selection of a JSON tab, and after an edit the values the editor marks
    /// after their lines (pictures, links, colors, times). Small documents are scanned on the spot; larger ones off the main thread
    /// after a short pause, with the previous buttons left up meanwhile (the icons wait for the new scan).
    /// Written only when it changes. The buttons locate the member again when clicked, so a result
    /// that is a moment stale never decides what is copied.
    func refreshJSONCaret(_ store: BufferTextStore? = nil) {
        jsonCaretTask?.cancel()
        jsonCaretTask = nil
        guard let store = store ?? activeStore, store.id == session.selectedBufferID,
              session.buffers[store.id]?.language == .json, store.length <= JSONLocator.sizeLimit else {
            return setJSONCaret(nil)
        }
        let selection = store.viewState.selection
        let ns = store.textStorage.mutableString
        let generation = store.generation
        let needsMarks = store.jsonMarks?.generation != generation
        if store.length <= JSONLocator.synchronousLimit {
            let units = JSONLocator.units(of: ns)
            setJSONCaret(JSONLocator.member(around: selection, in: units).map { JSONCaretInfo($0, in: units) })
            let context = JSONLocator.context(around: selection, in: units, collectMarks: needsMarks)
            jsonContainerSize = context.size
            if needsMarks { setJSONMarks(context.marks, generation: generation, store: store) }
            return
        }
        jsonCaretTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, store.generation == generation else { return }
            let units = JSONLocator.units(of: ns)
            let (info, context) = await Task.detached(priority: .userInitiated) {
                (JSONLocator.member(around: selection, in: units).map { JSONCaretInfo($0, in: units) },
                 JSONLocator.context(around: selection, in: units, collectMarks: needsMarks))
            }.value
            guard !Task.isCancelled, store.generation == generation else { return }
            self.setJSONCaret(info)
            self.jsonContainerSize = context.size
            if needsMarks { self.setJSONMarks(context.marks, generation: generation, store: store) }
        }
    }

    private func setJSONMarks(_ values: [JSONValueMark], generation: UInt64, store: BufferTextStore) {
        store.jsonMarks = (values, generation)
        if store.id == session.selectedBufferID { host.textView.setNeedsOverlays() }
    }

    /// The selected JSON tab's marked values, while they were found for its current text.
    var visibleJSONMarks: [JSONValueMark] {
        guard let store = activeStore, selectedBuffer?.language == .json,
              let found = store.jsonMarks, found.generation == store.generation else { return [] }
        return found.values
    }

    /// A click on a value's mark in the editor, looked up again in the current marks so a mark drawn for
    /// older text does nothing: Preview for a picture, the system browser for a link, a copy for a time,
    /// the decode card for a decode or a JWT.
    func activateJSONMark(at valueRange: NSRange, pasteboard: NSPasteboard = .general) {
        guard let mark = visibleJSONMarks.first(where: { $0.valueRange == valueRange }) else { return }
        switch mark.kind {
        case .image: previewJSONImage(at: valueRange)
        case .link(let url): NSWorkspace.shared.open(url)
        case .date(let date, let milliseconds): copyDate(date, milliseconds: milliseconds, to: pasteboard)
        case .decode: if placeCaret(in: valueRange) { decodeJSONValue() }
        case .color: break
        }
    }

    /// Puts the caret just inside the value and makes it the current member at once, so a card opened for
    /// it stays while the caret is there. False when the member there is not that value.
    private func placeCaret(in valueRange: NSRange) -> Bool {
        guard let store = activeStore, NSMaxRange(valueRange) <= store.length else { return false }
        host.textView.setSelectedRange(NSRange(location: valueRange.location + 1, length: 0))
        guard let found = currentJSONMember(), found.member.valueRange == valueRange else { return false }
        setJSONCaret(JSONCaretInfo(found.member, in: found.units))
        return true
    }

    /// A value card stays only while the caret is on the member it was opened for.
    func setJSONCaret(_ info: JSONCaretInfo?) {
        if info == nil { jsonContainerSize = nil }
        if info != jsonCaret { jsonCaret = info }
        if let card = jsonValueCard, info?.path != card.path || card.bufferID != session.selectedBufferID {
            dismissJSONValueCard()
        }
    }

    func copyJSONPath(to pasteboard: NSPasteboard = .general) {
        guard let found = currentJSONMember() else { return }
        copy(found.member.pathText, to: pasteboard)
        showToast(String(localized: "Copied path \(found.member.pathText)"))
    }

    func copyJSONKey(to pasteboard: NSPasteboard = .general) {
        guard let key = currentJSONMember()?.member.key else { return }
        copy(key, to: pasteboard)
        showToast(String(localized: "Copied key “\(key)”"))
    }

    func copyJSONValue(to pasteboard: NSPasteboard = .general) {
        guard let found = currentJSONMember() else { return }
        copy(JSONLocator.valueText(found.member, in: found.units), to: pasteboard)
        showToast(String(localized: "Copied value of \(found.member.pathText)"))
    }

    /// The value in a new Untitled tab named after its key. A string that holds JSON is decoded and
    /// formatted; an object or array opens as JSON; any other string is left to language detection.
    func openJSONValue() {
        guard launchGateOpen, let id = session.selectedBufferID, let found = currentJSONMember(),
              found.member.kind != .scalar, ensureRoomForTab() else { return }
        let member = found.member
        let value = JSONLocator.valueText(member, in: found.units)
        Task { [weak self] in
            let (text, isJSON) = await Task.detached(priority: .userInitiated) {
                Self.openedText(value, kind: member.kind)
            }.value
            self?.openValueTab(text, isJSON: isJSON, title: member.shortName, from: id)
        }
    }

    /// A new Untitled tab holding `text`, named `title`, set to JSON when it is.
    private func openValueTab(_ text: String, isJSON: Bool, title: String, from id: UUID) {
        guard session.buffers[id] != nil else { return }
        openTranslationTab(text)
        guard let newID = session.selectedBufferID, newID != id else { return }
        if isJSON { setLanguage(.json) }
        renameTab(newID, to: EditorBuffer.derivedTitle(fromPrefix: title, limit: 24) ?? title)
    }

    nonisolated static func openedText(_ value: String, kind: JSONMember.Kind) -> (String, isJSON: Bool) {
        guard kind == .string else { return (value, kind != .scalar) }
        guard let first = value.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else {
            return (value, false)
        }
        switch JSONFormatter.format(text: value, selection: nil) {
        case .formatted(let pretty, _): return (pretty, true)
        case .unchanged: return (value, true)
        case .invalid: return (value, false)
        }
    }

    // MARK: Value actions

    /// Open Link: the http(s) URL in the default browser. TinyEdit itself fetches nothing.
    func openJSONLink() {
        guard let url = currentJSONValue()?.insight.link else { return }
        NSWorkspace.shared.open(url)
    }

    /// Query: the link's query parameters as a JSON object in a new tab.
    func openJSONQuery() {
        guard launchGateOpen, let id = session.selectedBufferID, let found = currentJSONValue() else { return }
        guard let url = found.insight.link, let json = JSONValueInsight.queryJSON(url) else {
            return showToast(String(localized: "The link has no query parameters"))
        }
        guard ensureRoomForTab() else { return }
        openValueTab(json, isJSON: true, title: "\(found.member.shortName) query", from: id)
    }

    /// Copies the Unix timestamp as the local date and time the status bar shows.
    func copyJSONDate(to pasteboard: NSPasteboard = .general) {
        guard let insight = currentJSONValue()?.insight, let date = insight.date else { return }
        copyDate(date, milliseconds: insight.dateHasMilliseconds, to: pasteboard)
    }

    private func copyDate(_ date: Date, milliseconds: Bool, to pasteboard: NSPasteboard) {
        let text = JSONValueInsight.dateText(date, milliseconds: milliseconds)
        copy(text, to: pasteboard)
        showToast(String(localized: "Copied \(text)"))
    }

    /// Decode: the value's readings (JWT, Base64, URL, `\uXXXX`) on the card, the first one shown.
    func decodeJSONValue() {
        guard let id = session.selectedBufferID, let found = currentJSONValue() else { return }
        let kinds = found.insight.decodes
        let candidates = (PasteDecodeDetector.candidates(in: found.value) ?? []).filter { kinds.contains($0.kind) }
        guard !candidates.isEmpty else { return showToast(String(localized: "Nothing to decode")) }
        showJSONValueCard(JSONValueCard(bufferID: id, path: found.member.pathText, content: .decodes(candidates)))
    }

    func copyDecodedJSONValue(_ candidate: PasteDecodeCandidate) {
        copy(candidate.decoded, to: .general)
        dismissJSONValueCard()
        showToast(String(localized: "Copied"))
    }

    func openDecodedJSONValue(_ candidate: PasteDecodeCandidate) {
        guard launchGateOpen, let id = session.selectedBufferID, let card = jsonValueCard, ensureRoomForTab() else { return }
        dismissJSONValueCard()
        let title = card.path.split(separator: ".").last.map(String.init) ?? card.path
        openValueTab(candidate.decoded, isJSON: candidate.isJSON, title: title, from: id)
    }

    /// Preview: a `data:image/` URI is decoded here; an http(s) image is downloaded now, on this click only.
    func previewJSONImage() {
        guard let id = session.selectedBufferID, let found = currentJSONValue(), let source = found.insight.image else { return }
        let path = found.member.pathText
        let name = found.member.shortName
        let value = found.value
        jsonValueTask?.cancel()
        switch source {
        case .inline:
            jsonValueTask = Task { [weak self] in
                let decoded = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage, CGSize, String)? in
                    guard let uri = DataURI.parse(value),
                          let (cgImage, pixels) = Self.decodePreviewImage(uri.data) else { return nil }
                    let file = Self.fileName(name, extension: uri.fileExtension)
                    return (uri.data, cgImage, pixels, file)
                }.value
                guard let self, !Task.isCancelled else { return }
                guard let (data, cgImage, pixels, file) = decoded else {
                    return self.finishImage(id, path: path, .failure(.notImage))
                }
                self.finishImage(id, path: path, .success((data, cgImage, pixels, nil, file)))
            }
        case .remote:
            guard let url = found.insight.link else { return }
            showJSONValueCard(JSONValueCard(bufferID: id, path: path, content: .loadingImage(host: url.host() ?? "")))
            jsonValueTask = Task { [weak self] in
                let work = Task.detached(priority: .userInitiated) { () -> Result<(Data, CGImage, CGSize, URL?, String), ImagePreviewFailure> in
                    do {
                        let loaded = try await RemoteImageLoader.load(url)
                        guard let (cgImage, pixels) = Self.decodePreviewImage(loaded.data) else {
                            return .failure(.notImage)
                        }
                        let ext = loaded.mimeType.flatMap(DataURI.fileExtension(forMIMEType:)) ?? url.pathExtension
                        let last = url.deletingPathExtension().lastPathComponent
                        let file = Self.fileName(last.isEmpty || last == "/" ? name : last, extension: ext.isEmpty ? "png" : ext)
                        return .success((loaded.data, cgImage, pixels, url, file))
                    } catch let failure as ImagePreviewFailure {
                        return .failure(failure)
                    } catch {
                        return .failure(.request(.other))
                    }
                }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled else { return }
                self.finishImage(id, path: path, result)
            }
        }
    }

    /// Decodes a bounded thumbnail off the main thread while preserving the real pixel dimensions.
    nonisolated private static func decodePreviewImage(_ data: Data) -> (CGImage, CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let rawH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let pixels = rawW > 0 && rawH > 0 ? CGSize(width: rawW, height: rawH) : CGSize(width: cg.width, height: cg.height)
        return (cg, pixels)
    }

    /// The editor's Preview icon: puts the caret in the value, so the card stays while it is there, and previews it.
    func previewJSONImage(at valueRange: NSRange) {
        if placeCaret(in: valueRange) { previewJSONImage() }
    }

    private func finishImage(_ id: UUID, path: String, _ result: Result<(Data, CGImage, CGSize, URL?, String), ImagePreviewFailure>) {
        jsonValueTask = nil
        guard session.selectedBufferID == id, jsonCaret?.path == path else { return }
        let content: JSONValueCard.Content
        switch result {
        case .success(let (data, cgImage, pixels, link, file)):
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            content = .image(PreviewImage(image: image, data: data, pixelSize: pixels, link: link, suggestedName: file))
        case .failure(let failure):
            content = .failed(Self.imageFailureMessage(failure))
        }
        showJSONValueCard(JSONValueCard(bufferID: id, path: path, content: content))
    }

    static func imageFailureMessage(_ failure: ImagePreviewFailure) -> String {
        switch failure {
        case .request(let request): CurlShownFailure.failed(request).message
        case .status(let code):
            String(localized: "The server answered \("\(code) \(CurlRunner.reason(for: code))".trimmingCharacters(in: .whitespaces)).")
        case .notImage: String(localized: "This is not a picture TinyEdit can show.")
        }
    }

    nonisolated static func fileName(_ base: String, extension ext: String) -> String {
        let cleaned = base.map { "/:\\".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "image" : name) + "." + ext
    }

    func copyPreviewImage() {
        guard case .image(let preview) = jsonValueCard?.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([preview.image])
        showToast(String(localized: "Copied image"))
    }

    func savePreviewImage() {
        guard case .image(let preview) = jsonValueCard?.content else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = preview.suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try preview.data.write(to: url, options: .atomic)
            showToast(String(localized: "Saved \(url.lastPathComponent)"))
        } catch {
            Log.files.error("image save failed: \((error as NSError).code)")
            showToast(String(localized: "Could not save the image"), error: true)
        }
    }

    func openPreviewImageLink() {
        guard case .image(let preview) = jsonValueCard?.content, let link = preview.link else { return }
        NSWorkspace.shared.open(link)
    }

    // MARK: Value card

    private func showJSONValueCard(_ card: JSONValueCard) {
        if jsonValueCard != card { jsonValueCard = card }
    }

    /// Close, Cancel or Escape. Stops a download in flight.
    func dismissJSONValueCard() {
        jsonValueTask?.cancel()
        jsonValueTask = nil
        if jsonValueCard != nil { jsonValueCard = nil }
    }

    func dismissJSONValueCardFromEscape() -> Bool {
        guard jsonValueCard != nil else { return false }
        dismissJSONValueCard()
        return true
    }

    /// The first edit in the tab hides its card; later keystrokes write nothing.
    func clearJSONValueCardAfterEdit(_ id: UUID) {
        guard jsonValueCard?.bufferID == id || (jsonValueTask != nil && session.selectedBufferID == id) else { return }
        dismissJSONValueCard()
    }

    /// The member at the caret with its value as text (a string decoded) and what is special about it.
    private func currentJSONValue() -> (member: JSONMember, value: String, insight: JSONValueInsight)? {
        guard let found = currentJSONMember() else { return nil }
        let member = found.member
        return (member, JSONLocator.valueText(member, in: found.units), JSONValueInsight(member, in: found.units))
    }

    private func currentJSONMember() -> (member: JSONMember, units: [UInt16])? {
        guard let store = activeStore, selectedBuffer?.language == .json, store.length <= JSONLocator.sizeLimit
        else { return nil }
        let units = JSONLocator.units(of: store.textStorage.mutableString)
        guard let member = JSONLocator.member(around: store.viewState.selection, in: units) else {
            setJSONCaret(nil)
            showToast(String(localized: "No JSON value at the cursor"))
            return nil
        }
        return (member, units)
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
