import SwiftUI

/// The fragment spelling used by the reader's heading index.
enum MarkdownNavigation {
    static func slug(_ title: String) -> String {
        let scalars = title.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                || $0 == "-" || $0 == "_" || CharacterSet.whitespaces.contains($0)
        }
        return String(String.UnicodeScalarView(scalars)).map { $0.isWhitespace ? "-" : String($0) }.joined()
    }
}

/// SwiftUI's lazy reader can reveal a top-level row, but cannot reliably locate a heading deep
/// inside that row. A native layout anchor finishes the jump after that row has been laid out.
@MainActor final class MarkdownHeadingRegistry {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }
    private var views: [String: WeakView] = [:]
    private var pending: String?

    func register(_ view: NSView, path: String) {
        views[path] = WeakView(view)
        finishJump()
    }

    func canLocate(_ path: String) -> Bool {
        guard let view = views[path]?.value, view.window != nil, let scroll = view.enclosingScrollView else { return false }
        // A lazy row can remain attached outside the viewport with an outdated frame. Let the
        // SwiftUI reader bring that row back before using its native anchor for the exact jump.
        return scroll.contentView.bounds.contains(view.convert(NSPoint.zero, to: scroll.contentView))
    }

    func jump(to path: String) {
        pending = path
        finishJump()
    }

    func cancelJump() { pending = nil }
    func reset() { pending = nil; views.removeAll() }

    private func finishJump() {
        guard let path = pending else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.pending == path,
                  let view = self.views[path]?.value, view.window != nil,
                  let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let rect = view.convert(view.bounds, to: document)
            let clip = scroll.contentView
            let top = document.isFlipped ? rect.minY : rect.maxY - clip.bounds.height
            let y = max(document.bounds.minY, min(top, document.bounds.maxY - clip.bounds.height))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            self.pending = nil
        }
    }
}

struct MarkdownHeadingAnchor: NSViewRepresentable {
    let path: String
    let registry: MarkdownHeadingRegistry?

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) { registry?.register(view, path: path) }
}

extension EnvironmentValues {
    @Entry var markdownHeadingRegistry: MarkdownHeadingRegistry? = nil
}
