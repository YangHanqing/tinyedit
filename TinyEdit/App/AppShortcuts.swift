import SwiftUI

/// The menu key equivalents. `AppCommands` binds them and the Shortcuts settings pane lists them,
/// so the two cannot disagree.
enum AppShortcut {
    /// ⌘N, as in Sublime Text and VS Code (a new untitled tab in this window).
    static let newTab = KeyboardShortcut("n", modifiers: .command)
    /// Not a menu item: AppDelegate's key monitor. ⌘T, the browser-style second key.
    static let newTabAlternate = KeyboardShortcut("t", modifiers: .command)
    static let newWindow = KeyboardShortcut("n", modifiers: [.command, .shift])
    static let open = KeyboardShortcut("o", modifiers: .command)
    static let openFolder = KeyboardShortcut("o", modifiers: [.command, .shift])
    static let closeTab = KeyboardShortcut("w", modifiers: .command)
    static let closeWindow = KeyboardShortcut("w", modifiers: [.command, .shift])
    static let reopenClosedTab = KeyboardShortcut("t", modifiers: [.command, .shift])
    /// Menu items, but taken by AppDelegate's key monitor first: the text view would otherwise see ⌃Tab.
    static let nextTab = KeyboardShortcut(.tab, modifiers: .control)
    static let previousTab = KeyboardShortcut(.tab, modifiers: [.control, .shift])
    /// Not menu items: AppDelegate's key monitor. ⌘1 to ⌘8 pick a tab, ⌘9 the last.
    static let firstTab = KeyboardShortcut("1", modifiers: .command)
    static let eighthTab = KeyboardShortcut("8", modifiers: .command)
    static let lastTab = KeyboardShortcut("9", modifiers: .command)
    static let save = KeyboardShortcut("s", modifiers: .command)
    static let saveAs = KeyboardShortcut("s", modifiers: [.command, .shift])

    static let find = KeyboardShortcut("f", modifiers: .command)
    static let findAndReplace = KeyboardShortcut("f", modifiers: [.command, .option])
    static let findNext = KeyboardShortcut("g", modifiers: .command)
    static let findPrevious = KeyboardShortcut("g", modifiers: [.command, .shift])
    static let goToLine = KeyboardShortcut("l", modifiers: .command)
    static let goToMatchingBracket = KeyboardShortcut("\\", modifiers: [.command, .shift])

    static let duplicateLine = KeyboardShortcut("d", modifiers: [.command, .shift])
    static let moveLineUp = KeyboardShortcut(.upArrow, modifiers: .option)
    static let moveLineDown = KeyboardShortcut(.downArrow, modifiers: .option)
    static let deleteLine = KeyboardShortcut("k", modifiers: [.command, .shift])
    static let joinLines = KeyboardShortcut("j", modifiers: .control)
    static let toggleComment = KeyboardShortcut("/", modifiers: .command)
    static let toggleTask = KeyboardShortcut(.return, modifiers: .command)

    static let toggleSidebar = KeyboardShortcut("s", modifiers: [.command, .control])
    static let markdownPreview = KeyboardShortcut("v", modifiers: [.command, .shift])
    static let zoomIn = KeyboardShortcut("+", modifiers: .command)
    /// Not a menu item: AppDelegate's key monitor. On a US keyboard "+" is Shift-"=", which AppKit does not
    /// match to the ⌘+ item, and a second menu item would show twice.
    static let zoomInAlternate = KeyboardShortcut("=", modifiers: .command)
    static let zoomOut = KeyboardShortcut("-", modifiers: .command)
    /// Not a menu item: AppDelegate's key monitor (Shift-"-").
    static let zoomOutAlternate = KeyboardShortcut("_", modifiers: .command)
    static let resetZoom = KeyboardShortcut("0", modifiers: .command)

    static let commandPalette = KeyboardShortcut("p", modifiers: [.command, .shift])
}

struct ShortcutGroup {
    let title: LocalizedStringResource
    let items: [ShortcutItem]
}

struct ShortcutItem {
    let title: LocalizedStringResource
    /// Alternatives: any one of them does it.
    let keys: [KeyboardShortcut]
    /// The two keys are the ends of a run (⌘1 – ⌘8), not alternatives.
    var isRange = false

    init(_ title: LocalizedStringResource, _ keys: KeyboardShortcut...) {
        self.title = title
        self.keys = keys
    }

    static func range(_ title: LocalizedStringResource, _ first: KeyboardShortcut, _ last: KeyboardShortcut) -> ShortcutItem {
        var item = ShortcutItem(title, first, last)
        item.isRange = true
        return item
    }
}

/// Everything the Shortcuts settings pane lists: the `AppShortcut` menu items, the standard macOS
/// menu items TinyEdit keeps, and the keys the editor, cards and palette handle themselves.
enum ShortcutCatalog {
    private static func key(_ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Files and Tabs", items: [
            ShortcutItem("New Tab", AppShortcut.newTab, AppShortcut.newTabAlternate),
            ShortcutItem("New Window", AppShortcut.newWindow),
            ShortcutItem("Open…", AppShortcut.open),
            ShortcutItem("Open Folder…", AppShortcut.openFolder),
            ShortcutItem("Reopen Closed Tab", AppShortcut.reopenClosedTab),
            ShortcutItem("Close Tab", AppShortcut.closeTab),
            ShortcutItem("Show Next Tab", AppShortcut.nextTab),
            ShortcutItem("Show Previous Tab", AppShortcut.previousTab),
            ShortcutItem.range("Show Tab 1 to 8", AppShortcut.firstTab, AppShortcut.eighthTab),
            ShortcutItem("Show Last Tab", AppShortcut.lastTab),
            ShortcutItem("Save", AppShortcut.save),
            ShortcutItem("Save As…", AppShortcut.saveAs),
        ]),
        ShortcutGroup(title: "Editing", items: [
            ShortcutItem("Undo", key("z", .command)),
            ShortcutItem("Redo", key("z", [.command, .shift])),
            ShortcutItem("Cut", key("x", .command)),
            ShortcutItem("Copy", key("c", .command)),
            ShortcutItem("Paste", key("v", .command)),
            ShortcutItem("Select All", key("a", .command)),
            ShortcutItem("Toggle Comment", AppShortcut.toggleComment),
            ShortcutItem("Toggle Task", AppShortcut.toggleTask),
        ]),
        ShortcutGroup(title: "Lines and Indentation", items: [
            ShortcutItem("Duplicate Line", AppShortcut.duplicateLine),
            ShortcutItem("Move Line Up", AppShortcut.moveLineUp),
            ShortcutItem("Move Line Down", AppShortcut.moveLineDown),
            ShortcutItem("Delete Line", AppShortcut.deleteLine),
            ShortcutItem("Join Lines", AppShortcut.joinLines),
            ShortcutItem("Indent", key(.tab)),
            ShortcutItem("Outdent", key(.tab, .shift)),
            ShortcutItem("New line, indented after an opening bracket", key(.return)),
            ShortcutItem("New line without indentation", key(.return, .option)),
            ShortcutItem("Delete one indent level", key(.delete)),
        ]),
        ShortcutGroup(title: "Find and Navigate", items: [
            ShortcutItem("Find…", AppShortcut.find),
            ShortcutItem("Find and Replace…", AppShortcut.findAndReplace),
            ShortcutItem("Find Next", AppShortcut.findNext),
            ShortcutItem("Find Previous", AppShortcut.findPrevious),
            ShortcutItem("Previous match from the find field", key(.return, .shift)),
            ShortcutItem("Go to Line…", AppShortcut.goToLine),
            ShortcutItem("Go to Matching Bracket", AppShortcut.goToMatchingBracket),
            ShortcutItem("Close the find or Go to Line card", key(.escape)),
        ]),
        ShortcutGroup(title: "View", items: [
            ShortcutItem("Show or Hide Sidebar", AppShortcut.toggleSidebar),
            ShortcutItem("Toggle Markdown Preview", AppShortcut.markdownPreview),
            ShortcutItem("Zoom In", AppShortcut.zoomIn),
            ShortcutItem("Zoom Out", AppShortcut.zoomOut),
            ShortcutItem("Reset Font Size", AppShortcut.resetZoom),
        ]),
        ShortcutGroup(title: "Tools", items: [
            ShortcutItem("Command Palette…", AppShortcut.commandPalette),
            ShortcutItem("Choose a command", key(.upArrow), key(.downArrow)),
            ShortcutItem("Run the command", key(.return)),
            ShortcutItem("Close the command palette", key(.escape)),
            ShortcutItem("Insert the inline calculation result", key(.tab)),
            ShortcutItem("Dismiss the inline calculation", key(.escape)),
            ShortcutItem("Dismiss a suggestion or cancel text recognition", key(.escape)),
            ShortcutItem("Copy the translation", key(.return)),
            ShortcutItem("Close the translation", key(.escape)),
        ]),
        ShortcutGroup(title: "App and Window", items: [
            ShortcutItem("Settings…", key(",", .command)),
            ShortcutItem("Close Window", AppShortcut.closeWindow),
            ShortcutItem("Minimize", key("m", .command)),
            ShortcutItem("Hide TinyEdit", key("h", .command)),
            ShortcutItem("Quit TinyEdit", key("q", .command)),
        ]),
    ]
}

extension KeyboardShortcut {
    /// The shortcut as a menu draws it: ⌃⌥⇧⌘, then the key.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.symbol(for: key)
    }

    private static func symbol(for key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .return: "↩"
        case .tab: "⇥"
        case .escape: "⎋"
        case .delete: "⌫"
        case .space: "␣"
        default: String(key.character).uppercased()
        }
    }
}
