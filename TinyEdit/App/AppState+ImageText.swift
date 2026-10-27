import AppKit

/// A picture being read for one buffer.
struct ImageTextJob {
    var token: UInt64
    /// Where the text goes if the buffer has not changed by the time it is ready.
    var range: NSRange
    var generation: UInt64
    var task: Task<Void, Never>
}

extension AppState {
    /// Every paste variant asks this before AppKit reads the pasteboard. File references insert their paths, or
    /// with recognition on and only pictures among them, the pictures' text; pixels without text are read too.
    /// Anything else (text first) is AppKit's paste.
    func handlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let store = activeStore else { return false }
        let selection = host.textView.selectedRange()
        switch PastedImage.content(of: pasteboard) {
        case .other:
            return false
        case .files(let urls):
            if settings.recognizeTextInImages, urls.allSatisfy(PastedImage.isImageFile) {
                recognizeImageFiles(urls, in: store, at: selection)
            } else {
                host.textView.insertPasted(urls.map(\.path).joined(separator: "\n"), replacing: selection)
            }
            return true
        case .image(let data):
            guard settings.recognizeTextInImages else { return false }
            startImageTextRecognition([data], in: store, at: selection)
            return true
        }
    }

    /// Files dropped on the editor (`location` is the character under the pointer) or elsewhere in the window
    /// (the selection). With recognition on, pictures are read into the text and the other files open as tabs.
    func dropFiles(_ urls: [URL], at location: Int?) {
        guard launchGateOpen, settings.recognizeTextInImages, let store = activeStore else { return openURLs(urls) }
        let images = urls.filter(PastedImage.isImageFile)
        let others = urls.filter { !images.contains($0) }
        let range = location.map { NSRange(location: min(max($0, 0), store.length), length: 0) } ?? host.textView.selectedRange()
        if !images.isEmpty { recognizeImageFiles(images, in: store, at: range) }
        if !others.isEmpty { openURLs(others) }
    }

    /// Inserts an offered text at the selection, like a paste.
    func insertRecognizedText() {
        guard let id = session.selectedBufferID, case .offer(let text) = session.buffers[id]?.imageText else { return }
        session.buffers[id]?.imageText = nil
        insertImageText(text, replacing: host.textView.selectedRange())
    }

    func copyRecognizedText() {
        guard let id = session.selectedBufferID, case .offer(let text) = session.buffers[id]?.imageText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        session.buffers[id]?.imageText = nil
        showToast(String(localized: "Copied"))
    }

    /// Cancel while reading, or dismiss an offer, in the visible tab.
    func cancelImageText() {
        guard let id = session.selectedBufferID else { return }
        imageTextJobs[id]?.task.cancel()
        imageTextJobs[id] = nil
        if session.buffers[id]?.imageText != nil { session.buffers[id]?.imageText = nil }
    }

    /// Escape in the text view. False when there is no image card, so the paste card gets the key.
    func cancelImageTextFromEscape() -> Bool {
        guard let id = session.selectedBufferID, session.buffers[id]?.imageText != nil else { return false }
        cancelImageText()
        return true
    }

    private func recognizeImageFiles(_ urls: [URL], in store: BufferTextStore, at range: NSRange) {
        let images = PastedImage.read(urls)
        guard !images.isEmpty else { return showToast(String(localized: "Could not read the image"), error: true) }
        startImageTextRecognition(images, in: store, at: range)
    }

    /// Off the main thread; a newer picture for the same buffer replaces this one. The card shows while it runs
    /// and observed state is written only when it appears and when the result lands.
    private func startImageTextRecognition(_ images: [Data], in store: BufferTextStore, at range: NSRange) {
        let id = store.id
        guard let language = session.buffers[id]?.language else { return }
        imageTextJobs[id]?.task.cancel()
        imageTextToken &+= 1
        let token = imageTextToken
        let correction = language == .plain || language == .markdown
        let indent = activeIndentStyle
        let tabWidth = settings.tabWidth
        let documentTables = settings.recognizeDocumentTables
        let task = Task { [weak self] in
            let slowNotice = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.showSlowImageRecognition(id, token: token)
            }
            defer { slowNotice.cancel() }
            let work = Task.detached(priority: .userInitiated) {
                try await ImageTextRecognizer.recognize(images, languageCorrection: correction, indent: indent, tabWidth: tabWidth, recognizeDocumentTables: documentTables)
            }
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.finishImageText(id, token: token, result: result)
        }
        imageTextJobs[id] = ImageTextJob(token: token, range: range, generation: store.generation, task: task)
        if session.buffers[id]?.imageText != .recognizing { session.buffers[id]?.imageText = .recognizing }
    }

    /// A late timer must not revive a cancelled, completed, or replaced job.
    func showSlowImageRecognition(_ id: UUID, token: UInt64) {
        guard imageTextJobs[id]?.token == token, session.buffers[id]?.imageText == .recognizing else { return }
        session.buffers[id]?.imageText = .recognizingSlow
    }

    /// Inserted where the paste or drop was if the tab is still showing and unchanged; otherwise offered on the
    /// card. Vision's confidence is not a gate: it reports 0.3 for lines it read correctly.
    private func finishImageText(_ id: UUID, token: UInt64, result: Result<String, Error>) {
        guard let job = imageTextJobs[id], job.token == token else { return }
        imageTextJobs[id] = nil
        guard session.buffers[id] != nil, let store = stores[id] else { return }
        switch result {
        case .failure(let error):
            session.buffers[id]?.imageText = nil
            guard !(error is CancellationError) else { return }
            Log.files.error("image text failed: \(String(describing: error), privacy: .public)")
            showToast(String(localized: "Could not read the image"), error: true)
        case .success(let text) where text.isEmpty:
            session.buffers[id]?.imageText = nil
            showToast(String(localized: "No text found in the image"))
        case .success(let text):
            if id == session.selectedBufferID, store.generation == job.generation, NSMaxRange(job.range) <= store.length {
                session.buffers[id]?.imageText = nil
                insertImageText(text, replacing: job.range)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                showToast(String(localized: "Lines recognized from image: \(lines)"))
            } else {
                session.buffers[id]?.imageText = .offer(text)
            }
        }
    }

    /// As a paste: one undo step, then the usual paste checks (cleanup, language, decodes).
    private func insertImageText(_ text: String, replacing range: NSRange) {
        host.textView.setSelectedRange(range)
        beginPasteRecognition()
        host.textView.insertPasted(text, replacing: range)
        endPasteRecognition()
    }
}
