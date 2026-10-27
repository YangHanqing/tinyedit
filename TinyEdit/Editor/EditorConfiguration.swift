import AppKit

/// The plain-text checklist, set on the text view by `EditorConfiguration.apply`.
/// Whether AppKit actually honors the flags (`"hello"` stays straight-quoted) stays a manual check.
struct EditorFeatureFlags: Equatable {
    var isRichText = false
    var usesFontPanel = false
    var allowsUndo = true
    var automaticQuoteSubstitution = false
    var automaticDashSubstitution = false
    var automaticTextReplacement = false
    var automaticSpellingCorrection = false
    var automaticLinkDetection = false
    var continuousSpellChecking = false
    var grammarChecking = false
    var enabledTextCheckingTypes: UInt64 = 0
    var smartInsertDelete = false
    var importsGraphics = false

    static let plainText = EditorFeatureFlags()

    @MainActor
    func apply(to tv: NSTextView) {
        tv.isRichText = isRichText
        tv.usesFontPanel = usesFontPanel
        tv.allowsUndo = allowsUndo
        tv.isAutomaticQuoteSubstitutionEnabled = automaticQuoteSubstitution
        tv.isAutomaticDashSubstitutionEnabled = automaticDashSubstitution
        tv.isAutomaticTextReplacementEnabled = automaticTextReplacement
        tv.isAutomaticSpellingCorrectionEnabled = automaticSpellingCorrection
        tv.isAutomaticLinkDetectionEnabled = automaticLinkDetection
        tv.isContinuousSpellCheckingEnabled = continuousSpellChecking
        tv.isGrammarCheckingEnabled = grammarChecking
        tv.enabledTextCheckingTypes = enabledTextCheckingTypes
        tv.smartInsertDeleteEnabled = smartInsertDelete
        tv.importsGraphics = importsGraphics
    }
}

enum EditorConfiguration {
    static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func paragraphStyle(fontSize: Double, tabWidth: Int) -> NSParagraphStyle {
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font(size: fontSize)]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * Double(tabWidth)
        return style
    }

    /// Base attributes for typed text. Highlight colors are rendering attributes and never go here.
    static func baseAttributes(fontSize: Double, tabWidth: Int) -> [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize),
            .foregroundColor: Theme.textPrimary,
            .paragraphStyle: paragraphStyle(fontSize: fontSize, tabWidth: tabWidth),
        ]
    }

    /// Idempotent. Reapplied on tab swap and in `viewDidMoveToWindow` because AppKit can copy the
    /// user's global substitution defaults onto a text view when it enters a window.
    @MainActor
    static func apply(_ settings: EditorSettings, to tv: EditorTextView) {
        EditorFeatureFlags.plainText.apply(to: tv)
        let attrs = baseAttributes(fontSize: settings.fontSize, tabWidth: settings.tabWidth)
        // Each setter rewrites the attribute over the whole storage, which took 0.3 s on a 2 MB buffer on every
        // tab switch and setting change. The stores already carry both (`applyBaseAttributes`).
        let font = font(size: settings.fontSize)
        if tv.font != font { tv.font = font }
        if tv.textColor != Theme.textPrimary { tv.textColor = Theme.textPrimary }
        tv.insertionPointColor = Theme.accent
        tv.backgroundColor = Theme.editorBackground
        // The clip view paints the pattern across the whole viewport, including below short files.
        tv.drawsBackground = false
        tv.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        tv.typingAttributes = attrs
        tv.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        tv.autoIndent = settings.autoIndent
        tv.smartBackspace = settings.smartBackspace
        tv.continueMarkdownTasks = settings.continueMarkdownTasks
        tv.tabWidth = settings.tabWidth
        tv.decorationOptions = settings.decorationOptions
        tv.textContainerInset = NSSize(width: 8, height: 4)
    }
}
