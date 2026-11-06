import SwiftUI

/// Applies as it is edited, like the rest of Settings. Only the API key waits for an explicit Save, because it
/// goes to Keychain and is bound to the URL.
struct TranslationSettingsView: View {
    @State private var preferences = TranslationPreferences.load()
    @State private var languages: [String] = []
    @State private var credential = TranslationCredentialDraft()
    @State private var instructionsExpanded = false
    @State private var message: String?
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var testID: UUID?
    @State private var testTask: Task<Void, Never>?
    @State private var savingKey = false

    var body: some View {
        Form {
            Section("Translation Languages") {
                Picker("Preferred Language", selection: $preferences.primary) {
                    Text("System Preferred Language").tag("")
                    ForEach(languages, id: \.self) { Text(verbatim: TranslationLanguages.name($0)).tag($0) }
                }
                Picker("Second Language", selection: $preferences.secondary) {
                    Text("Automatic (English or System Second Language)").tag("")
                    ForEach(languages, id: \.self) { Text(verbatim: TranslationLanguages.name($0)).tag($0) }
                }
                Text("Translate into your preferred language. When the original is already in that language, use your second language.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
                Picker("Default Engine", selection: $preferences.engine) {
                    ForEach(TranslationEngine.available) { Text($0.title).tag($0) }
                }
            }
            if preferences.engine == .custom { modelSettings }
        }
        .onChange(of: preferences) { _, new in new.trimmed.save() }
        .task { languages = await TranslationLanguages.choices(extra: [preferences.primary, preferences.secondary]) }
        .task(id: preferences.endpoint) {
            let endpoint = preferences.endpoint
            guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let present = try await TranslationKeychain.containsInBackground(endpoint: endpoint)
                guard !Task.isCancelled, preferences.endpoint == endpoint else { return }
                credential.hasSavedKey = present
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
        .onChange(of: preferences.endpoint) { _, _ in
            credential = TranslationCredentialDraft()
            message = nil
            cancelTest()
        }
        .onChange(of: preferences.model) { _, _ in cancelTest() }
        .onChange(of: preferences.thinking) { _, _ in cancelTest() }
        .onChange(of: preferences.thinkingFormat) { _, _ in cancelTest() }
        .onChange(of: preferences.engine) { _, _ in cancelTest() }
        .onDisappear { cancelTest() }
    }

    private var modelSettings: some View {
        Section("Custom AI Model (OpenAI Compatible)") {
            Text("Uses an AI model through an OpenAI-compatible Chat Completions API.")
                .font(.caption).foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Chat Completions URL").font(.system(size: 12, weight: .medium))
                TextField("Chat Completions URL", text: $preferences.endpoint,
                          prompt: Text(verbatim: "https://api.example.com/v1/chat/completions"), axis: .vertical)
                    .labelsHidden().lineLimit(2...4)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if let problem = endpointProblem {
                    Text(verbatim: problem).font(.caption).foregroundStyle(Color.error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text("Model").font(.system(size: 12, weight: .medium))
                TextField("Model", text: $preferences.model).labelsHidden().textFieldStyle(.roundedBorder)
                if preferences.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter the model identifier your service expects.").font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("API Key (Optional)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    if credential.showsSavedMask {
                        Label("API Key Saved", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(Color.textSecondary)
                    }
                }
                SecureField("API Key (Optional)", text: Binding(get: { credential.value }, set: {
                    credential.edit($0); cancelTest()
                }), prompt: credential.showsSavedMask ? Text(verbatim: "••••••••") : nil)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                HStack {
                    Text("Stored in Keychain for this URL. Other translation settings save automatically.")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 8)
                    Button("Remove Saved API Key") { storeKey("") }
                        .disabled(!credential.hasSavedKey || savingKey)
                    Button("Save API Key") { storeKey(credential.value) }
                        .disabled(!credential.isEdited || credential.value.isEmpty || savingKey)
                }
                if let message {
                    Text(verbatim: message).font(.caption).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Thinking Mode", selection: $preferences.thinking) {
                ForEach(TranslationThinking.allCases) { Text($0.title).tag($0) }
            }
            if preferences.thinking != .serviceDefault {
                Picker("Thinking API Format", selection: $preferences.thinkingFormat) {
                    ForEach(TranslationThinkingFormat.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Text("Thinking controls vary by service. Use its documented format, or Service Default if unsupported.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }
            DisclosureGroup("Extra Translation Instructions", isExpanded: $instructionsExpanded) {
                TextEditor(text: $preferences.extraInstructions).frame(height: 80)
                if preferences.extraInstructions.utf16.count > 2_000 {
                    Text(verbatim: TranslationFailure.instructionsTooLong.localizedDescription)
                        .font(.caption).foregroundStyle(Color.error)
                }
                Text("Optional style or terminology preferences, such as formal tone or Korean honorifics. Applies only to Custom Model.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Test Connection") { testConnection() }.disabled(testID != nil)
                    if testID != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancel Test") { cancelTest() }
                    }
                }
                if let testMessage {
                    Text(verbatim: testMessage).font(.caption)
                        .foregroundStyle(testFailed ? Color.error : Color.accent)
                        .textSelection(.enabled)
                }
                Text("Sends a short sample request using these settings. Does not save settings or send editor content.")
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var endpointProblem: String? {
        let endpoint = preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, (try? ModelTranslation.validatedURL(endpoint)) == nil else { return nil }
        return TranslationFailure.endpoint.localizedDescription
    }

    /// Writes or removes the key for the current URL at once. An empty key removes it.
    private func storeKey(_ key: String) {
        cancelTest()
        let endpoint = preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !endpoint.isEmpty else { throw TranslationFailure.configuration }
            _ = try ModelTranslation.validatedURL(endpoint)
        } catch {
            message = error.localizedDescription
            return
        }
        var draft = credential
        draft.edit(key)
        savingKey = true
        Task {
            defer { savingKey = false }
            do {
                try await draft.persist { try await TranslationKeychain.saveInBackground($0, endpoint: endpoint) }
                // A URL edited meanwhile already reset the draft for the new URL.
                guard preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint else { return }
                draft.didSave()
                credential = draft
                message = key.isEmpty ? String(localized: "API key removed.") : String(localized: "API key saved.")
            } catch { message = error.localizedDescription }
        }
    }

    private func testConnection() {
        cancelTest()
        // Translation reads the stored, trimmed URL; test exactly that, not a pasted trailing newline.
        let config = preferences.trimmed
        let draft = credential
        let id = UUID()
        testID = id
        testTask = Task {
            do {
                // Validate before reading a saved secret; test the unsaved draft exactly as shown.
                _ = try ModelTranslation.connectionTestRequest(preferences: config, key: "")
                let key = try await draft.keyForRequest { try await TranslationKeychain.readInBackground(endpoint: config.endpoint) }
                try await ModelTranslation.testConnection(preferences: config, key: key)
                guard testID == id, !Task.isCancelled else { return }
                testMessage = String(localized: "Connection test passed. This model is ready to translate.")
                testFailed = false
            } catch {
                guard testID == id, !Task.isCancelled else { return }
                testMessage = error.localizedDescription
                testFailed = true
            }
            testID = nil; testTask = nil
        }
    }

    private func cancelTest() {
        testID = nil
        testTask?.cancel(); testTask = nil
        testMessage = nil
    }
}
