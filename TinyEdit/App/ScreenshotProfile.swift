#if DEBUG
import AppKit

/// Opt-in documentation fixtures. Release builds contain none of this launch path.
/// Uses real editor actions, with a separate app identity and disposable recovery directory.
@MainActor
enum ScreenshotProfile {
    static var scene: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--screenshot-scene"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static let size = CGSize(width: 1100, height: 720)

    static func prepareDefaults() {
        guard scene != nil else { return }
        UserDefaults.standard.setVolatileDomain([
            "AppleLanguages": ["en"], "tinyedit.language": "en",
            "tinyedit.appearance": scene?.hasSuffix("-light") == true ? "light" : "dark", "tinyedit.fontSize": 16.0,
            "tinyedit.tabWidth": 4, "tinyedit.insertSpaces": true,
            "tinyedit.detectIndentation": true, "tinyedit.wordWrap": true,
            "tinyedit.showLineNumbers": true, "tinyedit.appIcon": "notepad",
            "tinyedit.backgroundPattern": "off", "tinyedit.inlineCalculation": "plainText",
            "tinyedit.highlightCurrentLine": true, "tinyedit.showIndentGuides": true,
            "tinyedit.showInvisibles": false, "tinyedit.trimTrailingWhitespaceOnSave": true,
            "tinyedit.ensureFinalNewline": true, "tinyedit.recognizeTextInImages": true,
            "tinyedit.recognizeCurlCommands": true,
            "translation.primary": "zh-Hans", "translation.secondary": "en",
            "translation.engine": "apple"
        ], forName: UserDefaults.argumentDomain)
    }

    static func configure(_ window: NSWindow, state: AppState) {
        guard let scene else { return }
        window.setContentSize(size)
        window.center()
        window.appearance = NSAppearance(named: scene.hasSuffix("-light") ? .aqua : .darkAqua)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await state.recoveryActor.setLaunchGateOpen(true)
            state.launchGateOpen = true
            @MainActor func tab(_ title: String, _ text: String, _ language: EditorLanguage = .plain) {
                var buffer = EditorBuffer(title: title)
                buffer.titleIsCustom = true
                buffer.language = language
                buffer.languageDetectionSuppressed = true
                state.makeStore(for: buffer, text: text)
                state.session.buffers[buffer.id] = buffer
                state.session.tabOrder.append(buffer.id)
                state.session.selectedBufferID = buffer.id
            }
            let notes = """
            Everyday notes

            A small space for ideas, snippets and the next task.

            TODAY
            - Review the release notes
            - Check the API response
            - Keep the useful parts

            Quick calculation
            128 × 3 = 384
            0.1 + 0.2 = 0.3

            Everything stays here when you close the window.
            """
            let markdown = """
            # A little less friction

            Notes, code and everyday tasks in one place.

            ## Release checklist

            - [x] Polish the editor
            - [x] Test the text tools
            - [ ] Write the release notes
            - [ ] Publish the new version

            ## Keyboard first

            | Action | Shortcut |
            | --- | --- |
            | Command palette | ⇧⌘P |
            | Markdown preview | ⇧⌘V |
            | Toggle task | Cmd + Return |

            > Simple on the surface. Ready for everyday work.
            """
            switch scene {
            case "hero-simple-light", "hero-simple-dark":
                tab("Notes.txt", """
                Monday notes

                A little time to settle in before the week begins.

                Morning meeting
                Share the latest ideas with the team.
                Ask Maya about the new project timeline.
                Make room for questions and fresh perspectives.

                Things to remember
                Send the follow-up notes after lunch.
                Book a quiet hour for the next draft.
                Pick up coffee on the way home.

                Good work takes space to think.
                One thing at a time is enough.
                """)
            case "hero-code-light", "hero-code-dark":
                tab("Notes.swift", """
                import Foundation

                struct Note: Identifiable {
                    let id = UUID()
                    let title: String
                    let createdAt: Date
                    var isComplete = false

                    var summary: String {
                        let status = isComplete ? "Done" : "In progress"
                        return "\\(title) · \\(status)"
                    }
                }

                struct Notebook {
                    private(set) var notes: [Note] = []

                    mutating func add(_ title: String) {
                        let note = Note(title: title, createdAt: .now)
                        notes.append(note)
                    }

                    var unfinished: [Note] {
                        notes.filter { !$0.isComplete }
                    }
                }

                var notebook = Notebook()
                notebook.add("Write the first draft")
                notebook.add("Share the idea with the team")

                for note in notebook.unfinished {
                    print(note.summary)
                }
                """, .swift)
            case "syntax":
                tab("Notes.swift", """
                import Foundation

                // Keep everyday text editing simple.
                struct Note: Codable {
                    let title: String
                    var tags: [String]
                    var completed = false

                    var summary: String {
                        completed ? "Ready to share" : "Work in progress"
                    }
                }

                let note = Note(
                    title: "A little less friction",
                    tags: ["ideas", "snippets", "everyday"]
                )

                print(note.summary)
                """, .swift)
            case "json-open":
                tab("Response.json", """
                {
                  "app": "TinyEdit",
                  "data": {
                    "title": "Release checklist",
                    "notes": "First line\\nSecond line\\nReady to share.",
                    "items": [
                      { "name": "Review the notes", "done": true },
                      { "name": "Publish the release", "done": false }
                    ]
                  }
                }
                """, .json)
            case "overview", "palette":
                tab("Notes.txt", notes)
                tab("Response.json", "{\n  \"app\": \"TinyEdit\",\n  \"platform\": \"macOS\",\n  \"ready\": true\n}", .json)
                tab("Checklist.md", markdown, .markdown)
                state.session.selectedBufferID = scene == "overview" ? state.session.tabOrder.last : state.session.tabOrder.first
            case "calculator":
                tab("Quick calculations.txt", """
                Project estimate

                Design                     12.5 × 4 = 50
                Development                8 × 6 = 48
                Review                     3 × 2 = 6

                Decimal arithmetic         0.1 + 0.2 = 0.3
                With parentheses           (120 + 80) × 1.1 = 220

                Type an expression. Press Tab to keep the result.

                12.5 × 4 + 3
                """)
            case "markdown": tab("Checklist.md", markdown, .markdown)
            case "json-paste", "base64", "curl": tab("Untitled", "")
            case "json-value", "json-image":
                tab("Response.json", """
                {
                  "data": {
                    "name": "TinyEdit",
                    "platform": "macOS",
                    "description": "A minimal editor for everyday work.",
                    "website": "https://example.com/docs?lang=en&theme=dark",
                    "preview": "http://localhost:18473/preview.png",
                    "theme": "#6BD1C6",
                    "updated": 1767225600,
                    "items": [
                      { "name": "Notes", "ready": true },
                      { "name": "Snippets", "ready": true }
                    ]
                  }
                }
                """, .json)
            case "translation":
                tab("Release notes.txt", "TinyEdit keeps everyday text editing simple. Write notes, format JSON, preview Markdown and work with useful text tools in one native macOS app.")
            default: tab("Notes.txt", notes)
            }
            state.activeBufferChanged()
            if let store = state.activeStore { state.host.activate(store, settings: state.settings) }
            state.host.focus()
            if scene.hasPrefix("hero-simple"), let store = state.activeStore {
                let range = store.textStorage.mutableString.range(of: "Send the follow-up notes after lunch.")
                if range.location != NSNotFound {
                    state.host.textView.setSelectedRange(NSRange(location: range.location + range.length, length: 0))
                }
            }
            if scene == "markdown" || scene == "overview" { state.togglePreview() }
            if scene == "palette" { state.togglePalette() }
            if scene == "json-open", let store = state.activeStore {
                let range = store.textStorage.mutableString.range(of: "\"data\"")
                state.host.textView.setSelectedRange(NSRange(location: range.location + 2, length: 0))
                state.host.captureViewState()
                state.refreshJSONCaret()
            }
            if scene == "calculator", let store = state.activeStore {
                state.host.textView.setSelectedRange(NSRange(location: store.length, length: 0))
            }
            if scene == "json-value" || scene == "json-image", let store = state.activeStore {
                let target = scene == "json-image" ? "http://localhost" : "TinyEdit"
                let range = store.textStorage.mutableString.range(of: target)
                state.host.textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                state.host.captureViewState()
                state.refreshJSONCaret()
                if scene == "json-image", let image = state.visibleJSONMarks.first(where: \.isImage) {
                    state.previewJSONImage(at: image.valueRange)   // as a click on the line's picture icon
                }
            }
            if scene == "json-paste" || scene == "base64" || scene == "curl" {
                let samples = [
                    "json-paste": "{\"app\":\"TinyEdit\",\"platform\":\"macOS\",\"features\":[\"Text editing\",\"JSON tools\",\"Markdown preview\"],\"ready\":true}",
                    "base64": "VGlueUVkaXQga2VlcHMgZXZlcnlkYXkgdGV4dCBlZGl0aW5nIHNpbXBsZS4=",
                    "curl": "curl 'http://localhost:18473/v1/notes' \\\n  -H 'Accept: application/json'"
                ]
                state.beginPasteRecognition()
                state.host.textView.insertText(samples[scene]!, replacementRange: NSRange(location: 0, length: 0))
                state.endPasteRecognition()
            }
            if scene == "translation" { state.presentTranslation(wholeDocument: true) }
            if ProcessInfo.processInfo.arguments.contains("--screenshot-export") {
                if scene == "curl" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { state.sendPastedCurl() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (scene == "translation" ? 12 : 3)) {
                    export(window, scene: scene)
                }
            }
        }
    }
    /// Capture our content view, excluding macOS screen-sharing decorations in the title bar.
    private static func export(_ window: NSWindow, scene: String) {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/TinyEdit-captures", isDirectory: true)
        guard let view = window.contentView else { return }
        let bounds = view.bounds
        let scale = scene.hasPrefix("hero-") ? 3 : 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        // A SwiftUI sheet is a separate NSWindow. Render it at its actual on-screen position.
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
           let sheetBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
               pixelsWide: Int(sheetView.bounds.width * 2), pixelsHigh: Int(sheetView.bounds.height * 2),
               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            sheetBitmap.size = sheetView.bounds.size
            sheetView.cacheDisplay(in: sheetView.bounds, to: sheetBitmap)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
            let image = NSImage(size: sheetView.bounds.size)
            image.addRepresentation(sheetBitmap)
            image.draw(in: NSRect(x: sheet.frame.minX - window.frame.minX,
                                  y: sheet.frame.minY - window.frame.minY,
                                  width: sheet.frame.width, height: sheet.frame.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: directory.appendingPathComponent(scene + ".png"))
        } catch { AppState.shared.showToast("Export: " + error.localizedDescription, error: true) }
    }
}
#endif
