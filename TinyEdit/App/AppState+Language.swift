import Foundation

extension AppState {
    func dismissLanguageSuggestion() {
        guard let id = session.selectedBufferID else { return }
        session.buffers[id]?.languageSuggestion = nil
        session.buffers[id]?.languageDetectionSuppressed = true
        flushImmediately()
    }

    func detectLanguageFromContent() {
        guard let id = session.selectedBufferID else { return }
        scheduleLanguageDetection(id, manual: true, delay: .zero)
    }

    func scheduleLanguageDetection(_ id: UUID, manual: Bool = false, delay: Duration = .seconds(1)) {
        languageDetectionTasks.removeValue(forKey: id)?.cancel()
        guard let buffer = session.buffers[id],
              manual || (settings.suggestLanguageWhileTyping && buffer.isUntitled && buffer.language == .plain && !buffer.languageDetectionSuppressed) else { return }
        languageDetectionTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let store = self.stores[id] else { return }
            let generation = store.generation
            let ns = store.textStorage.mutableString
            let sample = ns.substring(with: NSRange(location: 0, length: min(ns.length, ContentLanguageDetector.sampleLimit)))
            let complete = ns.length <= ContentLanguageDetector.sampleLimit
            let result = await Task.detached(priority: .utility) {
                ContentLanguageDetector.detect(sample, isComplete: complete)
            }.value
            guard !Task.isCancelled, store.generation == generation, let current = self.session.buffers[id],
                  manual || (self.settings.suggestLanguageWhileTyping && current.isUntitled && current.language == .plain && !current.languageDetectionSuppressed) else { return }
            self.languageDetectionTasks[id] = nil
            if manual, result == nil || result == current.language {
                self.session.buffers[id]?.languageSuggestion = nil
                if self.session.selectedBufferID == id {
                    self.showToast(result.map { String(localized: "Already \($0.statusLabel)") } ?? String(localized: "No confident language match"))
                }
            } else if current.languageSuggestion != result {
                // Until it is applied or dismissed the suggestion follows the text: a guess made on a half-typed
                // buffer is replaced as more arrives, and one the text no longer supports goes away.
                self.session.buffers[id]?.languageSuggestion = result
            } else {
                return
            }
            self.scheduleFlush()
        }
    }
}
