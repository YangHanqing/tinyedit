import AppKit

/// The editor window's size, remembered across launches. The position is not: the window opens centered.
/// Only a resize the user drags is stored, so zoom, tiling and full screen do not replace it.
enum WindowSize {
    static let storageKey = "tinyedit.windowSize"
    static let standard = CGSize(width: 960, height: 640)
    /// RootView's minimum frame.
    static let minimum = CGSize(width: 480, height: 320)

    /// The stored size, shrunk to fit `visible` (the screen's visible frame) and no smaller than `minimum`.
    static func load(from defaults: UserDefaults = .standard, visible: CGSize?) -> CGSize {
        var size = standard
        if let pair = defaults.array(forKey: storageKey) as? [Double], pair.count == 2,
           pair.allSatisfy({ $0.isFinite && $0 > 0 }) {
            size = CGSize(width: pair[0], height: pair[1])
        }
        if let visible {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        return CGSize(width: max(size.width, minimum.width).rounded(), height: max(size.height, minimum.height).rounded())
    }

    static func reset(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: storageKey) }

    static func save(_ size: CGSize, to defaults: UserDefaults = .standard) {
        defaults.set([Double(size.width.rounded()), Double(size.height.rounded())], forKey: storageKey)
    }
}

extension AppState {
    /// Window ▸ Reset Window Size: the standard size (no larger than the screen), centered, with the stored size
    /// forgotten and the Markdown preview back to half. Full screen is left alone but still forgets the size.
    func resetWindowSize() {
        WindowSize.reset()
        resetPreviewFraction()
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let content = WindowSize.load(visible: visible.size)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = NSPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded())
        window.setFrame(frame, display: true, animate: true)
    }
}
