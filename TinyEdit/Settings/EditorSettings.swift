import Foundation

/// Icon shown in the Dock and the title bar while the app is running.
enum AppIconStyle: String, CaseIterable, Sendable {
    case notepad, code, manuscript, cursor

    var label: String {
        switch self {
        case .code: String(localized: "Code Editor")
        case .manuscript: String(localized: "Manuscript")
        case .notepad: String(localized: "Notepad")
        case .cursor: String(localized: "Minimal Cursor")
        }
    }

    var imageName: String {
        switch self {
        case .code: "AppIconCode"
        case .manuscript: "AppIconManuscript"
        case .notepad: "AppIconNotepad"
        case .cursor: "AppIconCursor"
        }
    }
}

enum BackgroundPattern: String, CaseIterable, Sendable {
    case off, dots, grid, waves

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .dots: String(localized: "Soft Dots")
        case .grid: String(localized: "Fine Grid")
        case .waves: String(localized: "Gentle Waves")
        }
    }
}

/// Where a cursor-line math ghost may appear. Code languages never calculate, whatever this is.
enum InlineCalculationMode: String, CaseIterable, Sendable {
    case off
    case plainText
    case plainTextAndMarkdown

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .plainText: String(localized: "Plain Text")
        case .plainTextAndMarkdown: String(localized: "Plain Text and Markdown")
        }
    }
}

struct EditorSettings: Equatable, Sendable {
    static let defaultFontSize = 13.0
    static let fontSizeRange = 9.0...32.0
    static let tabWidthRange = 1...8

    var fontSize = defaultFontSize
    /// Columns a TAB character is drawn across, and the spaces in one indent level when `insertSpaces`.
    var tabWidth = 4
    /// Tab inserts spaces rather than a TAB character, unless the text or its language says otherwise.
    var insertSpaces = true
    /// Follow the indentation a file already uses.
    var detectIndentation = true
    var wordWrap = true
    var showLineNumbers = true
    var appearance = AppearanceMode.system
    var appIcon = AppIconStyle.notepad
    var backgroundPattern = BackgroundPattern.off
    var inlineCalculation = InlineCalculationMode.plainText
    var highlightCurrentLine = true
    var showIndentGuides = true
    /// Every space and TAB, not only the ones in the selection.
    var showInvisibles = false
    /// On Save, before writing. Markdown and Diff keep theirs (a Markdown line break, a blank context line).
    var trimTrailingWhitespaceOnSave = false
    var ensureFinalNewline = false
    /// A pasted or dropped picture inserts the text Vision reads in it.
    var recognizeTextInImages = true
    var recognizeDocumentTables = false

    static var supportsDocumentTables: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    /// A pasted curl command offers to send the request it describes.
    var recognizeCurlCommands = true
    /// JSON value marks after their lines (`JSONMarkOptions`).
    var jsonMarkImages = true
    var jsonMarkLinks = true
    var jsonMarkColors = true
    var jsonMarkTimes = true
    var jsonMarkJWTExpiry = true
    var jsonMarkDecodes = false

    var highlightMatchingBrackets = true
    var highlightSelectionOccurrences = true
    var autoIndent = true
    var smartBackspace = true
    var continueMarkdownTasks = true
    var suggestPasteDecodes = true
    var suggestPasteLanguage = true
    var suggestPasteCleanup = true
    var suggestLanguageWhileTyping = false

    private enum Key {
        static let highlightMatchingBrackets = "tinyedit.highlightMatchingBrackets"
        static let highlightSelectionOccurrences = "tinyedit.highlightSelectionOccurrences"
        static let autoIndent = "tinyedit.autoIndent"
        static let smartBackspace = "tinyedit.smartBackspace"
        static let continueMarkdownTasks = "tinyedit.continueMarkdownTasks"
        static let suggestPasteDecodes = "tinyedit.suggestPasteDecodes"
        static let suggestPasteLanguage = "tinyedit.suggestPasteLanguage"
        static let suggestPasteCleanup = "tinyedit.suggestPasteCleanup"
        static let suggestLanguageWhileTyping = "tinyedit.suggestLanguageWhileTyping"

        static let fontSize = "tinyedit.fontSize"
        static let tabWidth = "tinyedit.tabWidth"
        static let insertSpaces = "tinyedit.insertSpaces"
        static let detectIndentation = "tinyedit.detectIndentation"
        static let wordWrap = "tinyedit.wordWrap"
        static let showLineNumbers = "tinyedit.showLineNumbers"
        static let appearance = "tinyedit.appearance"
        static let appIcon = "tinyedit.appIcon"
        static let backgroundPattern = "tinyedit.backgroundPattern"
        static let inlineCalculation = "tinyedit.inlineCalculation"
        static let highlightCurrentLine = "tinyedit.highlightCurrentLine"
        static let showIndentGuides = "tinyedit.showIndentGuides"
        static let showInvisibles = "tinyedit.showInvisibles"
        static let trimTrailingWhitespaceOnSave = "tinyedit.trimTrailingWhitespaceOnSave"
        static let ensureFinalNewline = "tinyedit.ensureFinalNewline"
        static let recognizeDocumentTables = "tinyedit.recognizeDocumentTables"
        static let recognizeTextInImages = "tinyedit.recognizeTextInImages"
        static let recognizeCurlCommands = "tinyedit.recognizeCurlCommands"
        static let jsonMarkImages = "tinyedit.jsonMarkImages"
        static let jsonMarkLinks = "tinyedit.jsonMarkLinks"
        static let jsonMarkColors = "tinyedit.jsonMarkColors"
        static let jsonMarkTimes = "tinyedit.jsonMarkTimes"
        static let jsonMarkJWTExpiry = "tinyedit.jsonMarkJWTExpiry"
        static let jsonMarkDecodes = "tinyedit.jsonMarkDecodes"
    }

    static func load(from d: UserDefaults = .standard) -> EditorSettings {
        var s = EditorSettings()
        if d.object(forKey: Key.highlightMatchingBrackets) != nil { s.highlightMatchingBrackets = d.bool(forKey: Key.highlightMatchingBrackets) }
        if d.object(forKey: Key.highlightSelectionOccurrences) != nil { s.highlightSelectionOccurrences = d.bool(forKey: Key.highlightSelectionOccurrences) }
        if d.object(forKey: Key.autoIndent) != nil { s.autoIndent = d.bool(forKey: Key.autoIndent) }
        if d.object(forKey: Key.smartBackspace) != nil { s.smartBackspace = d.bool(forKey: Key.smartBackspace) }
        if d.object(forKey: Key.continueMarkdownTasks) != nil { s.continueMarkdownTasks = d.bool(forKey: Key.continueMarkdownTasks) }
        if d.object(forKey: Key.suggestPasteDecodes) != nil { s.suggestPasteDecodes = d.bool(forKey: Key.suggestPasteDecodes) }
        if d.object(forKey: Key.suggestPasteLanguage) != nil { s.suggestPasteLanguage = d.bool(forKey: Key.suggestPasteLanguage) }
        if d.object(forKey: Key.suggestPasteCleanup) != nil { s.suggestPasteCleanup = d.bool(forKey: Key.suggestPasteCleanup) }
        if d.object(forKey: Key.suggestLanguageWhileTyping) != nil { s.suggestLanguageWhileTyping = d.bool(forKey: Key.suggestLanguageWhileTyping) }

        if d.object(forKey: Key.fontSize) != nil { s.fontSize = d.double(forKey: Key.fontSize) }
        if d.object(forKey: Key.tabWidth) != nil { s.tabWidth = d.integer(forKey: Key.tabWidth) }
        if d.object(forKey: Key.insertSpaces) != nil { s.insertSpaces = d.bool(forKey: Key.insertSpaces) }
        if d.object(forKey: Key.detectIndentation) != nil { s.detectIndentation = d.bool(forKey: Key.detectIndentation) }
        if d.object(forKey: Key.wordWrap) != nil { s.wordWrap = d.bool(forKey: Key.wordWrap) }
        if d.object(forKey: Key.showLineNumbers) != nil { s.showLineNumbers = d.bool(forKey: Key.showLineNumbers) }
        if d.object(forKey: Key.highlightCurrentLine) != nil { s.highlightCurrentLine = d.bool(forKey: Key.highlightCurrentLine) }
        if d.object(forKey: Key.showIndentGuides) != nil { s.showIndentGuides = d.bool(forKey: Key.showIndentGuides) }
        if d.object(forKey: Key.showInvisibles) != nil { s.showInvisibles = d.bool(forKey: Key.showInvisibles) }
        if d.object(forKey: Key.trimTrailingWhitespaceOnSave) != nil {
            s.trimTrailingWhitespaceOnSave = d.bool(forKey: Key.trimTrailingWhitespaceOnSave)
        }
        if d.object(forKey: Key.ensureFinalNewline) != nil { s.ensureFinalNewline = d.bool(forKey: Key.ensureFinalNewline) }
        if d.object(forKey: Key.recognizeTextInImages) != nil {
            s.recognizeTextInImages = d.bool(forKey: Key.recognizeTextInImages)
        }
        if d.object(forKey: Key.recognizeCurlCommands) != nil {
            s.recognizeCurlCommands = d.bool(forKey: Key.recognizeCurlCommands)
        }
        if d.object(forKey: Key.jsonMarkImages) != nil { s.jsonMarkImages = d.bool(forKey: Key.jsonMarkImages) }
        if d.object(forKey: Key.jsonMarkLinks) != nil { s.jsonMarkLinks = d.bool(forKey: Key.jsonMarkLinks) }
        if d.object(forKey: Key.jsonMarkColors) != nil { s.jsonMarkColors = d.bool(forKey: Key.jsonMarkColors) }
        if d.object(forKey: Key.jsonMarkTimes) != nil { s.jsonMarkTimes = d.bool(forKey: Key.jsonMarkTimes) }
        if d.object(forKey: Key.jsonMarkJWTExpiry) != nil { s.jsonMarkJWTExpiry = d.bool(forKey: Key.jsonMarkJWTExpiry) }
        if d.object(forKey: Key.jsonMarkDecodes) != nil { s.jsonMarkDecodes = d.bool(forKey: Key.jsonMarkDecodes) }
        if let raw = d.string(forKey: Key.appearance), let mode = AppearanceMode(rawValue: raw) { s.appearance = mode }
        if let raw = d.string(forKey: Key.appIcon) {
            // Map retired icons to the closest remaining design when upgrading.
            let previousIcons: [String: AppIconStyle] = [
                "night": .code, "moon": .manuscript, "leaf": .manuscript,
                "sun": .notepad, "wave": .notepad,
                "quill": .manuscript, "paper": .notepad, "nib": .cursor, "lines": .cursor
            ]
            s.appIcon = AppIconStyle(rawValue: raw) ?? previousIcons[raw] ?? .notepad
        }
        if let raw = d.string(forKey: Key.backgroundPattern), let pattern = BackgroundPattern(rawValue: raw) {
            s.backgroundPattern = pattern
        }
        if let raw = d.string(forKey: Key.inlineCalculation), let mode = InlineCalculationMode(rawValue: raw) {
            s.inlineCalculation = mode
        }
        s.recognizeDocumentTables = supportsDocumentTables && d.bool(forKey: Key.recognizeDocumentTables)
        return s.clamped()
    }

    func save(to d: UserDefaults = .standard) {
        d.set(highlightMatchingBrackets, forKey: Key.highlightMatchingBrackets)
        d.set(highlightSelectionOccurrences, forKey: Key.highlightSelectionOccurrences)
        d.set(autoIndent, forKey: Key.autoIndent)
        d.set(smartBackspace, forKey: Key.smartBackspace)
        d.set(continueMarkdownTasks, forKey: Key.continueMarkdownTasks)
        d.set(suggestPasteDecodes, forKey: Key.suggestPasteDecodes)
        d.set(suggestPasteLanguage, forKey: Key.suggestPasteLanguage)
        d.set(suggestPasteCleanup, forKey: Key.suggestPasteCleanup)
        d.set(suggestLanguageWhileTyping, forKey: Key.suggestLanguageWhileTyping)

        d.set(fontSize, forKey: Key.fontSize)
        d.set(tabWidth, forKey: Key.tabWidth)
        d.set(insertSpaces, forKey: Key.insertSpaces)
        d.set(detectIndentation, forKey: Key.detectIndentation)
        d.set(wordWrap, forKey: Key.wordWrap)
        d.set(showLineNumbers, forKey: Key.showLineNumbers)
        d.set(highlightCurrentLine, forKey: Key.highlightCurrentLine)
        d.set(showIndentGuides, forKey: Key.showIndentGuides)
        d.set(showInvisibles, forKey: Key.showInvisibles)
        d.set(trimTrailingWhitespaceOnSave, forKey: Key.trimTrailingWhitespaceOnSave)
        d.set(ensureFinalNewline, forKey: Key.ensureFinalNewline)
        d.set(recognizeDocumentTables, forKey: Key.recognizeDocumentTables)
        d.set(recognizeTextInImages, forKey: Key.recognizeTextInImages)
        d.set(recognizeCurlCommands, forKey: Key.recognizeCurlCommands)
        d.set(jsonMarkImages, forKey: Key.jsonMarkImages)
        d.set(jsonMarkLinks, forKey: Key.jsonMarkLinks)
        d.set(jsonMarkColors, forKey: Key.jsonMarkColors)
        d.set(jsonMarkTimes, forKey: Key.jsonMarkTimes)
        d.set(jsonMarkJWTExpiry, forKey: Key.jsonMarkJWTExpiry)
        d.set(jsonMarkDecodes, forKey: Key.jsonMarkDecodes)
        d.set(appearance.rawValue, forKey: Key.appearance)
        d.set(appIcon.rawValue, forKey: Key.appIcon)
        d.set(backgroundPattern.rawValue, forKey: Key.backgroundPattern)
        d.set(inlineCalculation.rawValue, forKey: Key.inlineCalculation)
    }

    var preferredIndent: IndentStyle { insertSpaces ? .spaces(tabWidth) : .tabs }

    var decorationOptions: EditorDecorationOptions {
        EditorDecorationOptions(currentLine: highlightCurrentLine, indentGuides: showIndentGuides, invisibles: showInvisibles,
                                matchingBrackets: highlightMatchingBrackets, selectionOccurrences: highlightSelectionOccurrences,
                                jsonMarks: JSONMarkOptions(images: jsonMarkImages, links: jsonMarkLinks, colors: jsonMarkColors, times: jsonMarkTimes, jwtExpiry: jsonMarkJWTExpiry, decodes: jsonMarkDecodes))
    }

    func clamped() -> EditorSettings {
        var s = self
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        s.tabWidth = min(max(tabWidth, Self.tabWidthRange.lowerBound), Self.tabWidthRange.upperBound)
        return s
    }
}
