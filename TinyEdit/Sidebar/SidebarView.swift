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

    private var tree: some View {
        let rows = appState.fileTree.rows(for: appState.folders)
        let selected = appState.selectedFilePath
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FileTreeRowView(row: row, isSelected: row.node.path == selected,
                                    unreadable: appState.fileTree.unreadable.contains(row.node.path))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
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
                .truncationMode(.middle)
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
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        if let id = row.rootID {
            Divider()
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

/// The line between the sidebar and the editor, and the strip either side of it that resizes the sidebar.
struct SidebarResizeHandle: View {
    @Environment(AppState.self) private var appState
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? appState.sidebarWidth
                            startWidth = start
                            appState.setSidebarWidth(start + value.translation.width, save: false)
                        }
                        .onEnded { _ in
                            startWidth = nil
                            appState.setSidebarWidth(appState.sidebarWidth, save: true)
                        })
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
