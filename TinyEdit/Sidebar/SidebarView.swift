import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The left sidebar: the window's folders as a tree. A click on a file opens it in this window; folders
/// dropped here join it. With no folder it asks for one.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if appState.folders.isEmpty {
                emptyState
            } else {
                tree
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chromeBackground)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accent, lineWidth: 2).padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { appState.dropOnSidebar($0) }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Folders")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
            Spacer(minLength: 0)
            SidebarIconButton(symbol: "plus", help: String(localized: "Add Folder…")) {
                Workspaces.shared.beginOpenFolderPanel(into: appState)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.textTertiary)
            Text("Drop a folder here")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Workspaces.shared.beginOpenFolderPanel(into: appState)
            } label: {
                Text("Open Folder…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.controlRaised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.separator))
            }
            .buttonStyle(PressedOpacityStyle())
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    /// At least as wide as the sidebar, so a row's highlight spans it; wider names scroll sideways.
    private var tree: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                FileTreeRows()
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// The rows, in a view of their own: it reads only the tree, so a divider drag (a new width every frame)
/// does not flatten the tree again.
private struct FileTreeRows: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let selected = appState.selectedFilePath
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(appState.fileTree.rows(for: appState.folders)) { row in
                FileTreeRowView(row: row, isSelected: row.node.path == selected,
                                unreadable: appState.fileTree.unreadable.contains(row.node.path))
            }
        }
    }
}

private struct FileTreeRowView: View {
    @Environment(AppState.self) private var appState
    let row: FileTreeRow
    let isSelected: Bool
    let unreadable: Bool
    @State private var hovering = false

    var body: some View {
        let node = row.node
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            Group {
                if node.isDirectory {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(row.rootID != nil ? Color.accent : Color.textSecondary)
                .frame(width: 16)
            Text(verbatim: node.name)
                .font(.system(size: 12, weight: row.rootID != nil ? .semibold : .regular))
                .foregroundStyle(unreadable ? Color.textTertiary : Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate() }
        .contextMenu { menu }
        .toolTip(unreadable ? String(localized: "This folder can't be read.") : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var icon: String {
        row.node.isDirectory ? "folder" : "doc.text"
    }

    private var background: Color {
        if isSelected { return .tabSelectedBackground }
        return hovering ? .tabHoverBackground : .clear
    }

    private func activate() { appState.activateSidebarItem(row.node) }

    @ViewBuilder private var menu: some View {
        let node = row.node
        if !node.isDirectory {
            Button("Open") { appState.openURLs([node.url]) }
        } else if row.rootID == nil {
            Button("Open in New Window") { Workspaces.shared.openFolder(node.url, newWindow: true) }
        }
        Divider()
        Button("Copy Path") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.path, forType: .string)
            appState.showToast(String(localized: "Copied"))
        }
        if row.rootID == nil, let relative = appState.relativePath(ofPath: node.path) {
            Button("Copy Relative Path") { appState.copyRelativePath(relative) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        if let id = row.rootID {
            Divider()
            if unreadable { Button("Open Folder…") { appState.locateFolder(id) } }
            Button("Remove Folder from Window") { appState.removeFolder(id) }
        }
    }
}

private struct SidebarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 22, height: 20)
                .background(hovering ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
    }
}

/// The 1 pt line between the sidebar and the editor. It takes no more width than that: the strip that resizes
/// the sidebar is an AppKit view centered on it, lying over the edges of the views either side.
struct SidebarDivider: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(width: SidebarLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                SidebarResizeHandle(appState: appState)
                    .frame(width: SidebarLayout.handleWidth)
                    .accessibilityHidden(true)
            }
    }
}

/// AppKit rather than a SwiftUI drag gesture: the column-resize cursor comes from the view's own cursor rect
/// (no push/pop to unbalance, nothing for the text view's I-beam to fight), a tracking loop keeps the drag
/// going when the pointer leaves the strip or the sidebar collapses under it, and the strip never moves the
/// window (it is movable by its background).
private struct SidebarResizeHandle: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.appState = appState
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) { view.appState = appState }

    final class HandleView: NSView {
        weak var appState: AppState?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: Self.resizeCursor) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func cursorUpdate(with event: NSEvent) { Self.resizeCursor.set() }

        override func mouseDown(with event: NSEvent) {
            guard let window, let appState else { return }
            if event.clickCount == 2 {
                appState.resetSidebarWidth()
                return
            }
            let windowWidth = { Double(window.contentView?.bounds.width ?? window.frame.width) }
            let startX = Double(event.locationInWindow.x)
            let startWidth = appState.sidebarWidth
            let wasVisible = appState.sidebarVisible
            let startShown = SidebarLayout.shownWidth(stored: startWidth, windowWidth: windowWidth(),
                                                      editorMinWidth: appState.editorMinWidth)
            window.disableCursorRects()
            Self.resizeCursor.set()
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                               mode: .eventTracking) { event, stop in
                guard let event, event.type == .leftMouseDragged else {
                    stop.pointee = true
                    return
                }
                let proposed = startShown + Double(event.locationInWindow.x) - startX
                Self.cursor(for: appState.dragSidebar(to: proposed, windowWidth: windowWidth())).set()
            }
            window.enableCursorRects()
            window.resetCursorRects()
            appState.endSidebarDrag(startWidth: startWidth, wasVisible: wasVisible)
        }

        private static var resizeCursor: NSCursor {
            if #available(macOS 15, *) { .columnResize } else { .resizeLeftRight }
        }

        /// One-way arrows at a limit, as `NSSplitView` shows them.
        private static func cursor(for drag: SidebarLayout.Drag) -> NSCursor {
            guard #available(macOS 15, *) else {
                switch drag {
                case .collapse, .width(_, limited: .min): return .resizeRight
                case .width(_, limited: .max): return .resizeLeft
                case .width(_, limited: nil): return .resizeLeftRight
                }
            }
            switch drag {
            case .collapse, .width(_, limited: .min): return .columnResize(directions: .right)
            case .width(_, limited: .max): return .columnResize(directions: .left)
            case .width(_, limited: nil): return .columnResize
            }
        }
    }
}

/// File URLs from drop item providers, which call back on arbitrary queues; delivered together on the main actor.
func loadFileURLs(_ providers: [NSItemProvider], then deliver: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let urls = DroppedURLs()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { urls.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { deliver(urls.all) }
    }
}

/// URLs from a drop's item providers, collected across their callback queues.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}
