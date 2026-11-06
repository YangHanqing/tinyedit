import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppState.shared.settings.appearance.apply()
        AppState.shared.applyAppIcon()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tabs are ours. Keep AppKit's native window tabbing (and its menu items) out.
        NSWindow.allowsAutomaticWindowTabbing = false
        AppState.shared.recentURLs = NSDocumentController.shared.recentDocumentURLs
        Workspaces.shared.start()
        #if DEBUG
        EndToEnd.run()
        #endif
        // ⌘T opens a tab like ⌘N (New Window is ⇧⌘N). SwiftUI menus cannot hold a hidden second shortcut.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard NSApp.modalWindow == nil else { return false }
                if flags == .command, event.charactersIgnoringModifiers == String(AppShortcut.newTabAlternate.key.character) {
                    Workspaces.shared.target.newTabInWindow()
                    return true
                }
                if let delta = Self.zoomAlternate(event, flags: flags) {
                    AppState.shared.zoom(by: delta)
                    return true
                }
                return Self.handleTabKey(event, flags: flags)
            }
            return handled ? nil : event
        }
    }

    /// ⌘= and ⌘_ (with or without the Shift the layout needs), the second keys for Zoom In and Zoom Out.
    private static func zoomAlternate(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Double? {
        guard flags.subtracting(.shift) == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case String(AppShortcut.zoomInAlternate.key.character): return 1
        case String(AppShortcut.zoomOutAlternate.key.character): return -1
        default: return nil
        }
    }

    /// ⌃Tab and ⌃⇧Tab (before the text view takes them), and ⌘1 to ⌘9, in the editor window only.
    /// The digits are matched by key code, so they work on layouts where the number row needs Shift.
    @MainActor
    private static func handleTabKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let state = Workspaces.shared.state(for: NSApp.keyWindow) else { return false }
        if event.keyCode == 48 /* Tab */ && (flags == .control || flags == [.control, .shift]) {
            state.selectAdjacentTab(flags.contains(.shift) ? -1 : 1)
            return true
        }
        // kVK_ANSI_1 ... kVK_ANSI_9
        let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if flags == .command, let number = digitKeys[event.keyCode] {
            state.selectTab(number: number)
            return true
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// No per-tab save dialogs. Copy from the stores, flush, and exit only after the flush succeeded.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Workspaces.shared.handleTerminate { reply in
            NSApp.reply(toApplicationShouldTerminate: reply)
        }
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        Workspaces.shared.openURLs(urls)
    }

    @MainActor
    func applicationWillResignActive(_ notification: Notification) {
        Workspaces.shared.flushAll()
    }

    /// The main window's scene phase covers it; the other windows are checked here.
    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        for window in Workspaces.shared.all { window.refreshFolderLocations() }
        let state = Workspaces.shared.target
        guard !state.isMain else { return }
        Task { await state.checkSelectedFileForExternalChanges() }
    }

    /// Clicking the Dock icon with no window on screen brings back the main window, which the red button hid.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppState.shared.showWindow() }
        return true
    }

    // MARK: Dock menu

    /// The system lists the windows on screen above these. The main window is missing from that list while
    /// the red button hides it, so it gets an item of its own then.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(dockItem(String(localized: "New Window"), #selector(dockNewWindow)))
        menu.addItem(dockItem(String(localized: "New Tab"), #selector(dockNewTab)))
        menu.addItem(dockItem(String(localized: "Open Folder…"), #selector(dockOpenFolder)))
        if AppState.shared.window?.isVisible != true {
            menu.addItem(.separator())
            menu.addItem(dockItem(String(localized: "Show Main Window"), #selector(dockShowMain)))
        }
        return menu
    }

    private func dockItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @MainActor @objc private func dockNewWindow() {
        NSApp.activate()
        Workspaces.shared.newWindow()
    }

    @MainActor @objc private func dockNewTab() {
        NSApp.activate()
        Workspaces.shared.target.newTabInWindow()
    }

    @MainActor @objc private func dockOpenFolder() {
        Workspaces.shared.beginOpenFolderPanel()
    }

    @MainActor @objc private func dockShowMain() {
        NSApp.activate()
        AppState.shared.showWindow()
    }
}
