import SwiftUI
// macOS 15 TranslationSession lacks Sendable annotations; it stays inside one view-bound task.
@preconcurrency import Translation

struct TranslationView: View {
    let input: TranslationInput
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = TranslationPreferences.load()
    @State private var languages: [String] = []
    @State private var detectedSource: String?
    @State private var source = ""
    @State private var target = ""
    @State private var manualTarget = false
    @State private var run: TranslationRun?
    @State private var original: PreviewExcerpt?
    @State private var ready = false
    @State private var instructionsExpanded = false
    @State private var validationError: String?
    @State private var appleJob: AppleJob?
    @State private var modelTask: Task<Void, Never>?

    private struct AppleJob: Identifiable {
        let id: UUID
        let source: String?
        let target: String
    }

    private var running: Bool { run?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            languageBar
            if preferences.engine == .custom {
                DisclosureGroup("Extra Translation Instructions", isExpanded: $instructionsExpanded) {
                    TextEditor(text: Binding(get: { preferences.extraInstructions }, set: {
                        preferences.extraInstructions = $0
                        reset()
                    }))
                    .font(.system(size: 13)).frame(height: 58).disabled(running)
                    Text("Optional style or terminology preferences. Changes here apply to this translation only.")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                }
                .font(.system(size: 12)).foregroundStyle(Color.textSecondary)
            }
            HStack(spacing: 14) {
                preview(original, title: "Original", symbol: "doc.text", placeholder: false)
                preview(run?.excerpt, title: "Translation", symbol: "character.bubble")
            }
            progress
            if let error = validationError ?? run?.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.error)
                    Text(verbatim: error).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.warningBackground, in: RoundedRectangle(cornerRadius: 8))
            }
            if let run, !run.isComplete, run.completed > 0 {
                Text("Partial translation. Continue to finish before replacing the original.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }
            footer
        }
        .padding(22)
        .frame(width: 780, height: instructionsExpanded ? 570 : 490)
        .foregroundStyle(Color.textPrimary)
        .background(Color.chromeBackground)
        .background {
            if let job = appleJob, let run {
                AppleTranslationOperation(run: run, jobID: job.id, source: job.source, target: job.target).id(job.id)
            }
        }
        .task {
            // Reappearing after a cancelled run must not silently resume or send another request.
            guard !ready else { return }
            let text = input.text
            let engine = preferences.engine
            if original == nil { original = PreviewExcerpt(text) }
            let prepared = await Task.detached { (TranslationPlan.make(text, for: engine), TranslationLanguages.detect(text)) }.value
            guard !Task.isCancelled else { return }
            run = TranslationRun(segments: prepared.0)
            detectedSource = prepared.1
            target = recommendedTarget()
            languages = await TranslationLanguages.choices(extra: [preferences.primary, preferences.secondary, target, prepared.1 ?? ""])
            guard !Task.isCancelled else { return }
            ready = true
            if !target.isEmpty { start() }
        }
        .onChange(of: running) { _, active in if !active { stopTasks() } }
        .onDisappear { cancel() }
    }

    private var closeButton: some View {
        Button { cancel(); dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.textSecondary).frame(width: 28, height: 28)
                .background(Color.tabHoverBackground, in: Circle())
        }
        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text("Close")).toolTip(String(localized: "Close"))
    }

    private var languageBar: some View {
        HStack(spacing: 14) {
            languagePicker("Source Language", selection: Binding(get: { source }, set: { new in
                guard source != new else { return }
                reset()
                source = new
                if !manualTarget { target = recommendedTarget() }
                if !target.isEmpty { start() }
            }), automatic: "Auto Detect")
                .disabled(!ready)
            HStack(spacing: 10) {
                languagePicker("Target Language", selection: Binding(get: { target }, set: { new in
                    guard target != new else { return }
                    reset()
                    target = new; manualTarget = true
                    if !target.isEmpty { start() }
                }), automatic: "Choose Language")
                    .disabled(!ready)
                closeButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
    }

    private func languagePicker(_ title: LocalizedStringKey, selection: Binding<String>, automatic: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.textSecondary)
                .fixedSize()
            Picker(title, selection: selection) {
                Text(automatic).tag("")
                ForEach(languages, id: \.self) { Text(verbatim: TranslationLanguages.name($0)).tag($0) }
            }
            .labelsHidden().controlSize(.large)
                .fixedSize().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemeDivider()
            HStack(spacing: 10) {
                if running {
                    Button("Cancel") { cancel() }.buttonStyle(.bordered)
                } else if ready, !target.isEmpty {
                    Button(run?.canContinue == true ? LocalizedStringKey("Continue Translation") :
                           run?.isComplete == true ? LocalizedStringKey("Translate Again") : LocalizedStringKey("Translate")) { start() }
                        .buttonStyle(.borderless).foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: 12)
                Button { if appState.openTranslationTab(run?.preview ?? "") { dismiss() } } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("Open in New Tab")).toolTip(String(localized: "Open in New Tab"))
                .disabled(run?.preview.isEmpty != false || running)
                Button("Replace Original") {
                    if appState.replaceTranslation(input, with: run?.preview ?? "") { dismiss() }
                    else { validationError = String(localized: "The original text changed. Copy the translation or open it in a new tab.") }
                }
                .buttonStyle(.bordered).disabled(run?.isComplete != true || running)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run?.preview ?? "", forType: .string)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(run?.preview.isEmpty != false || running)
            }
            .controlSize(.regular)
            Text(preferences.engine == .custom ?
                 LocalizedStringKey("The selected text will be sent to your configured service. Its usage fees and privacy policy apply.") :
                 LocalizedStringKey("Apple translates on device. You may be asked to download language resources."))
                .font(.system(size: 10)).foregroundStyle(Color.textTertiary)
        }
    }

    @ViewBuilder private var progress: some View {
        HStack(spacing: 8) {
            if !ready {
                ProgressView().controlSize(.small)
                Text("Preparing Translation…")
            } else if target.isEmpty {
                Image(systemName: "arrow.up").foregroundStyle(Color.accent)
                Text("Choose a target language to start translation.")
            } else if let run {
                switch run.phase {
                case .idle:
                    Text("\(run.total) parts to translate")
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Preparing Translation…")
                case .languages:
                    ProgressView().controlSize(.small)
                    Text("Waiting for Language Resources…")
                case .translating:
                    ProgressView().controlSize(.small)
                    Text("Translating part \(min(run.completed + 1, run.total)) of \(run.total)…")
                    Spacer()
                    ProgressView(value: Double(run.completed), total: Double(max(1, run.total)))
                        .frame(width: 120)
                case .paused, .failed:
                    Image(systemName: "pause.circle")
                    Text("\(run.completed) of \(run.total) parts completed")
                case .complete:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent)
                    Text("Translation Complete")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(Color.textSecondary)
        .frame(minHeight: 18)
    }

    /// Nil is still being measured (the original) or not started (the translation).
    private func preview(_ excerpt: PreviewExcerpt?, title: LocalizedStringKey, symbol: String,
                         placeholder: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title).fontWeight(.medium)
                Spacer()
            }
            .font(.system(size: 12)).foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            ThemeDivider()
            if let excerpt, !excerpt.text.isEmpty {
                ScrollView {
                    Text(verbatim: excerpt.text).textSelection(.enabled)
                        .font(.system(size: 14)).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if excerpt.shortened {
                    Text("Preview shortened. Copy and Open in New Tab include the full available text.")
                        .font(.system(size: 10)).foregroundStyle(Color.textTertiary)
                        .padding(10)
                }
            } else if placeholder {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 28, weight: .light))
                    Text("The translation will appear here.").font(.system(size: 12))
                }
                .foregroundStyle(Color.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.separator, lineWidth: 1) }
    }

    private func recommendedTarget() -> String {
        TranslationLanguages.target(source: source.isEmpty ? detectedSource : source,
                                    preferences: preferences, system: TranslationLanguages.systemPreferences)
    }

    private func start() {
        guard ready, !target.isEmpty, let run else { return }
        validationError = nil
        let effectiveSource = source.isEmpty ? detectedSource : source
        if let effectiveSource, TranslationLanguages.same(effectiveSource, target) {
            validationError = String(localized: "Choose a target language different from the source language.")
            return
        }
        if preferences.engine == .custom && preferences.extraInstructions.utf16.count > 2_000 {
            validationError = TranslationFailure.instructionsTooLong.localizedDescription
            return
        }
        stopTasks()
        if run.isComplete { run.reset() }
        let id = run.begin()
        if preferences.engine == .apple {
            appleJob = AppleJob(id: id, source: effectiveSource, target: target)
        } else {
            let config = preferences
            let requestedTarget = target
            modelTask = Task {
                let session = ModelTranslation.makeSession()
                defer { session.invalidateAndCancel() }
                do {
                    let key = try await TranslationKeychain.readInBackground(endpoint: config.endpoint)
                    await run.execute(id: id, concurrency: ModelTranslation.concurrency) { text in
                        try await ModelTranslation.translate(text: text, source: effectiveSource,
                                                             target: requestedTarget, preferences: config, key: key,
                                                             session: session)
                    }
                } catch { if !Task.isCancelled { run.fail(error, id: id) } }
            }
        }
    }

    private func reset() {
        cancel(); run?.reset(); validationError = nil
    }

    private func cancel() {
        run?.cancel(); stopTasks()
    }

    private func stopTasks() {
        modelTask?.cancel(); modelTask = nil
        // Removing the task view invalidates the session on macOS 15.
        appleJob = nil
    }
}

private struct AppleTranslationOperation: View {
    let run: TranslationRun
    let jobID: UUID
    let source: String?
    let target: String

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(source: source.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: target)) { session in
                await run.execute(id: jobID, prepare: {
                    guard let text = run.segments.first(where: \.needsTranslation)?.text else { return }
                    let availability = LanguageAvailability()
                    let status: LanguageAvailability.Status
                    if let source {
                        status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                    } else {
                        status = try await availability.status(for: text, to: Locale.Language(identifier: target))
                    }
                    guard status != .unsupported else { throw TranslationFailure.unsupported }
                    if status != .installed { run.preparingLanguages(jobID) }
                    try await session.prepareTranslation()
                }, translate: { text in
                    try await session.translate(text).targetText
                })
            }
    }
}
