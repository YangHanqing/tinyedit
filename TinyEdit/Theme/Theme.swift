import AppKit
import SwiftUI

/// User-selectable appearance. `.system` follows the macOS setting; the others pin `NSApp.appearance`,
/// which every window, menu and the text view inherit.
enum AppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() { NSApp.appearance = nsAppearance }
}

/// Design tokens. Every color is dynamic: it resolves against the drawing view's effective appearance,
/// so switching light/dark needs no re-assignment, only a redraw.
enum Theme {
    // MARK: Surfaces
    static let editorBackground = dynamic("editorBackground", light: 0xFFFFFF, dark: 0x1E1F22)
    static let backgroundPattern = dynamic("backgroundPattern", light: 0xCADCE2, dark: 0x3E4A54)
    /// Title row, tab bar, find bar, status bar.
    static let chromeBackground = dynamic("chromeBackground", light: 0xF3F3F5, dark: 0x2A2B2F)
    static let separator = dynamic("separator", light: 0xDEDEE3, dark: 0x3A3B40)
    static let tabSelectedBackground = dynamic("tabSelectedBackground", light: 0xDCE5FC, dark: 0x37425E)
    static let tabHoverBackground = dynamic("tabHoverBackground", light: 0xE7E7EB, dark: 0x34353A)
    /// The selected segment of a segmented control, raised above `tabHoverBackground`.
    static let controlRaised = dynamic("controlRaised", light: 0xFFFFFF, dark: 0x4A4B52)
    static let textSelection = dynamic("textSelection", light: 0xC9DBFB, dark: 0x3B4F78)
    static let warningBackground = dynamic("warningBackground", light: 0xFFF3D1, dark: 0x3B3220)

    // MARK: Foregrounds
    static let textPrimary = dynamic("textPrimary", light: 0x1D1D1F, dark: 0xE4E4E7)
    static let textSecondary = dynamic("textSecondary", light: 0x5E5F66, dark: 0xA4A5AD)
    static let textTertiary = dynamic("textTertiary", light: 0x84858C, dark: 0x7C7D85)
    static let gutterText = dynamic("gutterText", light: 0x8A8B92, dark: 0x6C6D75)
    static let accent = dynamic("accent", light: 0x2F6BED, dark: 0x7AA2FF)
    /// Text and icons on an `accent` fill.
    static let onAccent = dynamic("onAccent", light: 0xFFFFFF, dark: 0x14161B)
    static let warning = dynamic("warning", light: 0x8A5B00, dark: 0xF2C14E)
    static let error = dynamic("error", light: 0xC9302C, dark: 0xFF6B6B)
    static let success = dynamic("success", light: 0x1A7F37, dark: 0x3FB950)
    /// Space and tab marks drawn over `textSelection`.
    static let whitespaceMarker = dynamic("whitespaceMarker", light: 0x5873A3, dark: 0xA9BBE0)

    // MARK: Gutter marks for lines changed by a disk reload
    static let changeAdded = dynamic("changeAdded", light: 0x2DA44E, dark: 0x3FB950)
    static let changeModified = dynamic("changeModified", light: 0x2F6BED, dark: 0x7AA2FF)
    static let changeDeleted = dynamic("changeDeleted", light: 0xCF222E, dark: 0xF85149)

    // MARK: Compare With (unified diff rows, and the changed part of a paired line)
    static let diffAddedBackground = dynamic("diffAddedBackground", light: 0xE7F6EA, dark: 0x1F3326)
    static let diffAddedHighlight = dynamic("diffAddedHighlight", light: 0xB4E5BF, dark: 0x2F5C3B)
    static let diffRemovedBackground = dynamic("diffRemovedBackground", light: 0xFCEBEC, dark: 0x3A2427)
    static let diffRemovedHighlight = dynamic("diffRemovedHighlight", light: 0xF5BEC2, dark: 0x6B3037)

    /// Blanks outside the selection while Show Invisible Characters is on.
    static let whitespaceMarkerFaint = dynamic("whitespaceMarkerFaint", light: 0xC2C4CA, dark: 0x4A4C54)

    // MARK: Editor decorations, painted beneath the text
    static let currentLine = dynamic("currentLine", light: 0xF2F5FA, dark: 0x26282D)
    static let indentGuide = dynamic("indentGuide", light: 0xE4E5EA, dark: 0x34363C)
    /// Other occurrences of the selected text.
    static let occurrenceHighlight = dynamic("occurrenceHighlight", light: 0xE1E6EF, dark: 0x3A3D46)
    static let bracketMatch = dynamic("bracketMatch", light: 0xDCE6F8, dark: 0x343B4C)
    static let bracketMatchBorder = dynamic("bracketMatchBorder", light: 0x9AB2DE, dark: 0x5F6E90)

    // MARK: Find matches, drawn behind the text
    static let findMatch = dynamic("findMatch", light: 0xFBEBA8, dark: 0x4A4126)
    /// The match the selection is on; the selection color would read as inactive while the find field has focus.
    static let findMatchCurrent = dynamic("findMatchCurrent", light: 0xF6C343, dark: 0x8A6A1A)

    // MARK: Syntax (all at least 4.5:1 against `editorBackground` in both modes)
    static let syntaxKeyword = dynamic("syntaxKeyword", light: 0x9B2393, dark: 0xFF7AB2)
    static let syntaxString = dynamic("syntaxString", light: 0xC41A16, dark: 0xFC6A5D)
    static let syntaxNumber = dynamic("syntaxNumber", light: 0x1C00CF, dark: 0xD9C97C)
    static let syntaxComment = dynamic("syntaxComment", light: 0x6E7781, dark: 0x8A949E)
    static let syntaxLiteral = dynamic("syntaxLiteral", light: 0x0F68A0, dark: 0x67B7E4)
    static let syntaxKey = dynamic("syntaxKey", light: 0x326D74, dark: 0x6BD1C6)
    static let syntaxEntity = dynamic("syntaxEntity", light: 0x2349B3, dark: 0x7AA2F7)
    static let syntaxAttribute = dynamic("syntaxAttribute", light: 0x8A5A00, dark: 0xE5B567)
    static let syntaxCode = dynamic("syntaxCode", light: 0x9A4F1F, dark: 0xE0A872)
    static let syntaxPreprocessor = dynamic("syntaxPreprocessor", light: 0x7A3E9D, dark: 0xFD8F3F)
    static let syntaxAdded = dynamic("syntaxAdded", light: 0x1A7F37, dark: 0x6BCB77)
    static let syntaxRemoved = dynamic("syntaxRemoved", light: 0xCF222E, dark: 0xFF7B72)

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("TinyEdit." + name)) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

extension TokenKind {
    var color: NSColor {
        switch self {
        case .keyword, .taskBox: Theme.syntaxKeyword
        case .heading, .tag: Theme.syntaxEntity
        case .string: Theme.syntaxString
        case .number: Theme.syntaxNumber
        case .comment, .taskDone: Theme.syntaxComment
        case .boolean, .null: Theme.syntaxLiteral
        case .code: Theme.syntaxCode
        case .key: Theme.syntaxKey
        case .attribute: Theme.syntaxAttribute
        case .preprocessor: Theme.syntaxPreprocessor
        case .added: Theme.syntaxAdded
        case .removed: Theme.syntaxRemoved
        }
    }
}

/// SwiftUI mirrors of the chrome tokens.
extension Color {
    static let editorBackground = Color(nsColor: Theme.editorBackground)
    static let chromeBackground = Color(nsColor: Theme.chromeBackground)
    static let separator = Color(nsColor: Theme.separator)
    static let tabSelectedBackground = Color(nsColor: Theme.tabSelectedBackground)
    static let tabHoverBackground = Color(nsColor: Theme.tabHoverBackground)
    static let controlRaised = Color(nsColor: Theme.controlRaised)
    static let warningBackground = Color(nsColor: Theme.warningBackground)
    static let textPrimary = Color(nsColor: Theme.textPrimary)
    static let textSecondary = Color(nsColor: Theme.textSecondary)
    static let textTertiary = Color(nsColor: Theme.textTertiary)
    static let accent = Color(nsColor: Theme.accent)
    static let onAccent = Color(nsColor: Theme.onAccent)
    static let warning = Color(nsColor: Theme.warning)
    static let error = Color(nsColor: Theme.error)
    static let success = Color(nsColor: Theme.success)
    static let changeAdded = Color(nsColor: Theme.changeAdded)
    static let changeDeleted = Color(nsColor: Theme.changeDeleted)
}

/// 1 pt hairline in the `separator` token; replaces `Divider()` in the window chrome.
struct ThemeDivider: View {
    var body: some View {
        Rectangle().fill(Color.separator).frame(height: 1)
    }
}
