import SwiftUI
import XCTest
@testable import TinyEdit

final class ShortcutCatalogTests: XCTestCase {

    /// Context keys (Escape, Return, Tab) mean different things in different places; a key with
    /// ⌘ or ⌃ is global and must be listed once.
    func testGlobalShortcutsAreListedOnce() {
        var seen: [String: String] = [:]
        for group in ShortcutCatalog.groups {
            for item in group.items {
                for key in item.keys where !key.modifiers.isDisjoint(with: [.command, .control]) {
                    let title = item.title.key
                    if let other = seen[key.displayString] {
                        XCTFail("\(key.displayString) is listed for \(other) and \(title)")
                    }
                    seen[key.displayString] = title
                }
            }
        }
        XCTAssertGreaterThan(seen.count, 30)
    }

    func testEveryTitleIsInTheStringCatalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TinyEdit/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])
        XCTAssertNotNil(strings["Shortcuts"])
        for group in ShortcutCatalog.groups {
            XCTAssertNotNil(strings[group.title.key], group.title.key)
            for item in group.items {
                XCTAssertNotNil(strings[item.title.key], item.title.key)
            }
        }
    }
}
