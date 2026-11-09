import Cocoa
import FinderSync

/// Finder's menu on the empty space of any folder: “New Text File with TinyEdit”. The extension is off until the
/// user turns it on in System Settings (Settings ▸ General shows the switch). It writes nothing: it asks the app,
/// through `FinderMenu`'s link, for an Untitled tab whose first Save starts in that folder.
final class FinderMenuExtension: FIFinderSync {
    override init() {
        super.init()
        // Every folder: the menu is the only thing this extension does, so it watches nothing else.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: String(localized: "New Text File with TinyEdit"),
                              action: #selector(newTextFile(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc func newTextFile(_ sender: AnyObject?) {
        guard let folder = FIFinderSyncController.default().targetedURL(), let scheme = FinderMenu.scheme,
              let link = FinderMenu.link(directory: folder, scheme: scheme) else { return }
        NSWorkspace.shared.open(link)
    }
}
