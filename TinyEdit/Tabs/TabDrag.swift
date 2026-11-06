import AppKit
import UniformTypeIdentifiers

/// Dragging a tab. The item is a private type visible only to this process, so no other app accepts it and the
/// payload is never a string that lands in another document. A tab bar or window that takes the drop calls
/// `take()`. When the mouse comes up and nothing took it, `Workspaces.tabDragEnded` decides by where it came
/// up: another window gets the tab, empty space gets a new window. SwiftUI's drag reports no end, so the
/// mouse button is polled while the drag runs.
@MainActor
enum TabDrag {
    static let type = UTType(exportedAs: "cn.hqyang.tinyedit.tab")

    private(set) static var current: UUID?
    private static var taken = false
    private static var timer: Timer?
    /// Only a release after a press ends a drag; a provider asked for with the button up starts nothing.
    private static var pressed = false

    static func begin(_ id: UUID) -> NSItemProvider {
        current = id
        taken = false
        pressed = NSEvent.pressedMouseButtons & 1 != 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// The tab being dropped, for a drop target that accepts it.
    static func take() -> UUID? {
        guard let id = current else { return nil }
        taken = true
        return id
    }

    private static func poll() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { pressed = true; return }
        timer?.invalidate()
        timer = nil
        guard pressed else { current = nil; return }
        let point = NSEvent.mouseLocation
        // A drop target runs on the release too; give it the turn before deciding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated {
                guard let id = current else { return }
                current = nil
                if !taken { Workspaces.shared.tabDragEnded(id, at: point) }
            }
        }
    }
}
