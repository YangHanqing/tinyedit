import AppKit
import XCTest
@testable import TinyEdit

final class EditorSettingsTests: XCTestCase {
    func testDefaultsAndPreferenceRoundTrip() throws {
        let name = "EditorSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = EditorSettings.load(from: defaults)
        XCTAssertEqual(fresh.appearance, .system)
        XCTAssertEqual(fresh.backgroundPattern, .off)
        XCTAssertFalse(fresh.trimTrailingWhitespaceOnSave)
        XCTAssertFalse(fresh.ensureFinalNewline)
        XCTAssertFalse(fresh.jsonMarkDecodes)
        XCTAssertFalse(fresh.suggestLanguageWhileTyping)
        var changed = fresh
        for key in [\EditorSettings.highlightMatchingBrackets, \.highlightSelectionOccurrences,
                    \.autoIndent, \.smartBackspace, \.continueMarkdownTasks, \.suggestPasteDecodes,
                    \.suggestPasteLanguage, \.suggestPasteCleanup, \.suggestLanguageWhileTyping] {
            changed[keyPath: key].toggle()
        }
        changed.save(to: defaults)
        XCTAssertEqual(EditorSettings.load(from: defaults), changed)
        // Existing explicit preferences win over the new defaults.
        defaults.set(true, forKey: "tinyedit.ensureFinalNewline")
        defaults.set("dark", forKey: "tinyedit.appearance")
        XCTAssertTrue(EditorSettings.load(from: defaults).ensureFinalNewline)
        XCTAssertEqual(EditorSettings.load(from: defaults).appearance, .dark)
    }

    func testPasteDecodeAndLanguageSuggestionsAreIndependent() throws {
        let json = "{\"value\":1}"
        XCTAssertNil(PasteDecodeDetector.suggestion(in: json, currentLanguage: .plain,
                                                   suggestDecodes: false, suggestLanguage: false))
        let language = try XCTUnwrap(PasteDecodeDetector.suggestion(in: json, currentLanguage: .plain,
                                                                    suggestDecodes: false, suggestLanguage: true))
        XCTAssertEqual(language.language, .json)
        XCTAssertTrue(language.canFormatJSON)
        XCTAssertTrue(language.candidates.isEmpty)
        let encoded = "SGVsbG8gd29ybGQ="
        XCTAssertNil(PasteDecodeDetector.suggestion(in: encoded, currentLanguage: .plain,
                                                   suggestDecodes: false, suggestLanguage: false))
        let decode = try XCTUnwrap(PasteDecodeDetector.suggestion(in: encoded, currentLanguage: .plain,
                                                                 suggestDecodes: true, suggestLanguage: false))
        XCTAssertEqual(decode.candidates.first?.decoded, "Hello world")
        XCTAssertNil(decode.language)
        XCTAssertFalse(decode.canFormatJSON)
        // Manual decoding is unaffected by suggestion preferences.
        XCTAssertEqual(try TextTransform.apply(.base64Decode, to: encoded), "Hello world")
    }

    @MainActor
    func testInputSettingsControlActualEdits() {
        let host = EditorTextHost()
        var settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "    hello", settings: settings)
        host.activate(store, settings: settings)
        func reset(_ text: String) {
            store.replaceLogicalText(text, recordUndo: false, settings: settings)
            host.textView.setSelectedRange(NSRange(location: store.length, length: 0))
        }
        reset("    hello")
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "    hello\n    ")
        settings.autoIndent = false
        host.apply(settings: settings, stores: [store])
        reset("    hello")
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "    hello\n")
        reset("    ")
        host.textView.deleteBackward(nil)
        XCTAssertEqual(store.logicalString(), "")
        settings.smartBackspace = false
        host.apply(settings: settings, stores: [store])
        reset("    ")
        host.textView.deleteBackward(nil)
        XCTAssertEqual(store.logicalString(), "   ")
        host.textView.taskLanguage = { .markdown }
        reset("- [ ] task")
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "- [ ] task\n- [ ] ")
        settings.continueMarkdownTasks = false
        host.apply(settings: settings, stores: [store])
        reset("- [ ] task")
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "- [ ] task\n")
    }

    @MainActor
    func testDisabledDecorationsAreNotProduced() {
        let host = EditorTextHost()
        host.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "(hello) hello", settings: settings)
        host.activate(store, settings: settings)
        host.textView.layoutSubtreeIfNeeded()
        let rect = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(host.textView.decorations(in: rect).brackets.count, 2)
        host.textView.setSelectedRange(NSRange(location: 1, length: 5))
        XCTAssertFalse(host.textView.decorations(in: rect).occurrences.isEmpty)
        settings.highlightMatchingBrackets = false
        settings.highlightSelectionOccurrences = false
        host.apply(settings: settings, stores: [store])
        XCTAssertTrue(host.textView.decorations(in: rect).occurrences.isEmpty)
        host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(host.textView.decorations(in: rect).brackets.isEmpty)
    }

    @MainActor
    func testPastePreferencesGateCardsAndCancelPendingRecognition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = EditorSettings.load()
        defer { saved.save(); try? FileManager.default.removeItem(at: root) }
        let state = AppState(root: root, autoRestore: false)
        await state.restore()
        let store = try XCTUnwrap(state.activeStore)
        var settings = EditorSettings()
        settings.suggestPasteLanguage = false
        settings.recognizeCurlCommands = false
        state.updateSettings(settings)
        state.host.activate(store, settings: settings)
        func paste(_ text: String) {
            store.replaceLogicalText("", recordUndo: false, settings: state.settings)
            state.host.textView.setSelectedRange(NSRange(location: 0, length: 0))
            state.beginPasteRecognition()
            state.host.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            state.endPasteRecognition()
        }
        func finishRecognition() async throws {
            for _ in 0..<100 where state.pasteTasks[store.id] != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let colored = "\u{1B}[31mred\u{1B}[0m"
        paste(colored)
        try await finishRecognition()
        XCTAssertNotNil(state.selectedBuffer?.pasteSuggestion?.cleanup)
        XCTAssertEqual(store.logicalString(), colored)
        settings.suggestPasteCleanup = false
        state.updateSettings(settings)
        paste(colored)
        try await finishRecognition()
        XCTAssertNil(state.selectedBuffer?.pasteSuggestion)
        paste("SGVsbG8gd29ybGQ=")
        XCTAssertNotNil(state.pasteTasks[store.id])
        settings.suggestPasteDecodes = false
        state.updateSettings(settings)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(state.pasteTasks[store.id])
        XCTAssertNil(state.selectedBuffer?.pasteSuggestion)
        paste("SGVsbG8gd29ybGQ=")
        XCTAssertNil(state.pasteTasks[store.id])
        settings.suggestPasteLanguage = true
        state.updateSettings(settings)
        paste("{\"value\":1}")
        try await finishRecognition()
        XCTAssertEqual(state.selectedBuffer?.pasteSuggestion?.language, .json)
        XCTAssertTrue(state.selectedBuffer?.pasteSuggestion?.canFormatJSON == true)
        XCTAssertTrue(state.selectedBuffer?.pasteSuggestion?.candidates.isEmpty == true)
        await state.performFlush()
    }

    @MainActor
    func testDisablingSuggestionsCancelsPendingWorkAndManualDetectionStillWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let saved = EditorSettings.load()
        defer { saved.save(); try? FileManager.default.removeItem(at: root) }
        let state = AppState(root: root, autoRestore: false)
        await state.restore()
        var settings = state.settings
        settings.suggestLanguageWhileTyping = true
        state.updateSettings(settings)
        let store = try XCTUnwrap(state.activeStore)
        store.replaceLogicalText("{\"value\":1}", recordUndo: false, settings: settings)
        state.scheduleLanguageDetection(store.id, delay: .seconds(10))
        XCTAssertNotNil(state.languageDetectionTasks[store.id])
        settings.suggestLanguageWhileTyping = false
        state.updateSettings(settings)
        XCTAssertTrue(state.languageDetectionTasks.isEmpty)
        XCTAssertNil(state.selectedBuffer?.languageSuggestion)
        state.scheduleLanguageDetection(store.id)
        XCTAssertNil(state.languageDetectionTasks[store.id])
        state.detectLanguageFromContent()
        for _ in 0..<100 where state.selectedBuffer?.languageSuggestion == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.selectedBuffer?.languageSuggestion, .json)
        await state.performFlush()
        let restored = AppState(root: root, autoRestore: false)
        await restored.restore()
        XCTAssertNil(restored.selectedBuffer?.languageSuggestion)
        await restored.performFlush()
    }
}
