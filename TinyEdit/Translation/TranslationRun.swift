import Foundation
import Observation

/// The first `limit` characters of a text and whether it was cut, measured once per change rather than on
/// every render (a whole document can be 500,000 UTF-16 units).
struct PreviewExcerpt: Equatable, Sendable {
    static let limit = 20_000
    let text: String
    let shortened: Bool

    init(_ full: String, limit: Int = Self.limit) {
        // UTF-16 units never undercount characters, so a short text needs no character walk.
        if full.utf16.count > limit, let end = full.index(full.startIndex, offsetBy: limit, limitedBy: full.endIndex),
           end < full.endIndex {
            text = String(full[..<end])
            shortened = true
        } else {
            text = full
            shortened = false
        }
    }
}

/// One panel's in-memory progress. Completed parts survive pause/error; configuration changes reset it.
@MainActor
@Observable
final class TranslationRun {
    enum Phase { case idle, preparing, languages, translating, paused, failed, complete }
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    private(set) var segments: [TranslationSegment]
    private var outputs: [String?]
    /// The contiguous completed prefix of `outputs`, extended as parts finish instead of joined on each read.
    private(set) var preview = ""
    private(set) var excerpt = PreviewExcerpt("")
    @ObservationIgnored private var previewEnd = 0
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private let timeout: Duration

    /// The per-part watchdog is a backstop for a stalled session; a model request times out on its own first.
    static let defaultTimeout = Duration.seconds(ModelTranslation.requestTimeout + 20)

    init(text: String, timeout: Duration = defaultTimeout) {
        let planned = TranslationPlan.make(text)
        self.segments = planned
        outputs = planned.map { $0.needsTranslation ? nil : $0.text }
        self.timeout = timeout
        extendPreview()
    }

    init(segments: [TranslationSegment], timeout: Duration = defaultTimeout) {
        self.segments = segments
        outputs = segments.map { $0.needsTranslation ? nil : $0.text }
        self.timeout = timeout
        extendPreview()
    }

    var isRunning: Bool {
        phase == .preparing || phase == .languages || phase == .translating
    }
    var isComplete: Bool { phase == .complete }
    var total: Int { segments.filter(\.needsTranslation).count }
    var completed: Int { segments.indices.filter { segments[$0].needsTranslation && outputs[$0] != nil }.count }
    var canContinue: Bool { !isRunning && !isComplete && completed > 0 }

    func reset() {
        cancel()
        outputs = segments.map { $0.needsTranslation ? nil : $0.text }
        phase = .idle; error = nil
        rebuildPreview()
    }

    func begin() -> UUID {
        cancel()
        let id = UUID()
        token = id; phase = .preparing; error = nil
        return id
    }

    func preparingLanguages(_ id: UUID) {
        if token == id { phase = .languages }
    }

    func cancel() {
        token = nil
        watchdog?.cancel(); watchdog = nil
        if phase == .preparing || phase == .languages || phase == .translating { phase = .paused }
    }

    func fail(_ failure: Error, id: UUID) {
        guard token == id else { return }
        cancel()
        phase = .failed; error = failure.localizedDescription
    }

    /// Called by either the model task or a view-bound Apple translation task. Up to `concurrency` parts are
    /// requested at once; results are applied in order once the whole batch is back, so indices stay put.
    func execute(id: UUID, concurrency: Int = 1, prepare: (() async throws -> Void)? = nil,
                 translate: @escaping (String) async throws -> String) async {
        guard token == id else { return }
        do {
            if let prepare { try await prepare() }
            while true {
                let batch = Array(outputs.indices.filter { outputs[$0] == nil }.prefix(max(concurrency, 1)))
                guard !batch.isEmpty else { break }
                guard token == id, !Task.isCancelled else { return }
                phase = .translating
                armTimeout(id)
                let texts = batch.map { segments[$0].text }
                let results = await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                    for (position, text) in texts.enumerated() {
                        group.addTask { @MainActor in
                            do { return (position, .success(try await translate(text))) }
                            catch { return (position, .failure(error)) }
                        }
                    }
                    var results = [Result<String, Error>?](repeating: nil, count: texts.count)
                    for await (position, result) in group { results[position] = result }
                    return results
                }
                guard token == id, !Task.isCancelled else { return }
                watchdog?.cancel(); watchdog = nil
                var failure: (index: Int, error: Error)?
                for (index, result) in zip(batch, results) {
                    do {
                        let raw = try result?.get().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let body = LineEnding.normalizeToLF(raw)
                        guard !body.isEmpty else { throw TranslationFailure.empty }
                        outputs[index] = body
                    } catch {
                        if failure == nil { failure = (index, error) }
                    }
                }
                extendPreview()
                // Only the first failure is handled; later failed parts are simply requested again.
                guard let (index, error) = failure else { continue }
                // Only known size/truncation errors and timeouts qualify; auth/rate-limit errors wait for the user.
                if let failure = error as? TranslationFailure, failure.shouldReduceChunk || failure.shouldReduceNextAttempt,
                   segments[index].text.utf16.count > 256 {
                    let smaller = TranslationPlan.split(segments[index].text, limit: segments[index].text.utf16.count / 2)
                    if smaller.filter(\.needsTranslation).count > 1 {
                        segments.replaceSubrange(index...index, with: smaller)
                        outputs.replaceSubrange(index...index, with: smaller.map { $0.needsTranslation ? nil : $0.text })
                        if index < previewEnd { rebuildPreview() } else { extendPreview() }
                        if failure.shouldReduceChunk { continue }
                    }
                }
                throw error
            }
            guard token == id, !Task.isCancelled else { return }
            cancel(); phase = .complete
        } catch {
            if !Task.isCancelled { fail(error, id: id) }
        }
    }

    private func extendPreview() {
        let start = previewEnd
        while previewEnd < outputs.count, let output = outputs[previewEnd] {
            preview += output
            previewEnd += 1
        }
        // Once cut, the excerpt cannot change: the preview only grows at its end.
        if previewEnd != start, !excerpt.shortened { excerpt = PreviewExcerpt(preview) }
    }

    private func rebuildPreview() {
        preview = ""
        previewEnd = 0
        excerpt = PreviewExcerpt("")
        extendPreview()
    }

    private func armTimeout(_ id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            self?.fail(TranslationFailure.timeout, id: id)
        }
    }
}
