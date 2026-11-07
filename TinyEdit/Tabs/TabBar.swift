import AppKit
import SwiftUI

/// The tab strip. Tabs share the width (`TabStripLayout`); when they no longer fit the strip scrolls,
/// keeps the selected tab in view, fades the clipped edge, takes vertical wheel scrolling as horizontal,
/// and shows the All Tabs menu. macOS 14 (no scroll geometry) reveals the selected tab with
/// `ScrollViewReader` and has no edge fades or wheel mapping.
struct TabBar: View {
    @Environment(AppState.self) private var appState
    @State private var renamingID: UUID?
    @State private var scrollRequest: ScrollRequest?
    @State private var scroll = ScrollMetrics()
    @State private var stripWidth: CGFloat = 0
    @State private var wheel = WheelTarget()

    fileprivate struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var viewport: CGFloat = 0
    }

    /// An offset for `TrackedTabScroll` to scroll to; `serial` makes a repeat of the same offset count.
    fileprivate struct ScrollRequest: Equatable {
        var x: CGFloat
        var animated: Bool
        var serial: Int
    }

    /// Where a burst of wheel events is heading. The scroll geometry reports back a frame late, so
    /// events that arrive in between add to the target instead of starting again from a stale offset.
    private final class WheelTarget {
        var x: CGFloat = 0
        var time: TimeInterval = 0
    }

    var body: some View {
        let buffers = appState.session.orderedBuffers
        let layout = layout(for: buffers)
        let overflowing = stripWidth > 0 && layout.overflows(stripWidth)
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabStripLayout.spacing) {
                        ForEach(Array(buffers.enumerated()), id: \.element.id) { index, buffer in
                            TabItem(buffer: buffer,
                                    isSelected: buffer.id == appState.session.selectedBufferID,
                                    width: layout.width(at: index),
                                    onSelect: { appState.selectTab(buffer.id) },
                                    onClose: { appState.closeTab(buffer.id) },
                                    isRenaming: renamingID == buffer.id,
                                    onRename: { finishRename(buffer.id, name: $0) })
                                .contextMenu { menu(for: buffer) }
                                .background(TabDragSource(id: buffer.id, title: buffer.displayTitle, enabled: renamingID != buffer.id))
                                .onDrop(of: [TabDrag.type], isTargeted: nil) { _ in dropTab(before: buffer.id) }
                        }
                    }
                    .padding(.horizontal, TabStripLayout.padding)
                }
                // Past the last tab: the dragged tab goes last.
                .onDrop(of: [TabDrag.type], isTargeted: nil) { _ in dropTab(before: nil) }
                .modifier(TrackedTabScroll(request: scrollRequest, metrics: $scroll))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
                .overlay { edgeFades(layout) }
                .background(VerticalWheelCatcher { delta in scrollByWheel(delta, layout: layout, enabled: overflowing) })
                .onChange(of: appState.session.selectedBufferID) { _, _ in revealSelected(animated: true, proxy: proxy) }
                .onChange(of: appState.session.tabOrder.count) { _, _ in revealSelected(animated: true, proxy: proxy) }
                .onChange(of: stripWidth) { _, _ in revealSelected(animated: false, proxy: proxy) }
            }
            if overflowing {
                AllTabsMenu(buffers: buffers)
            }
            Button { appState.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 10)
            .disabled(!appState.hasRoomForTab)
            .toolTip(appState.hasRoomForTab ? "" : AppState.tabLimitMessage)
            .accessibilityLabel("New Tab")
        }
        .frame(height: 32)
        .background(Color.chromeBackground)
    }

    /// A tab from this window is reordered; one from another window moves here.
    private func dropTab(before target: UUID?) -> Bool {
        guard let id = TabDrag.take() else { return false }
        if appState.session.buffers[id] != nil {
            if let target { appState.moveTab(id, before: target) } else { appState.moveTabToEnd(id) }
        } else {
            Task { await Workspaces.shared.moveTab(id, to: appState, before: target) }
        }
        return true
    }

    private func layout(for buffers: [EditorBuffer]) -> TabStripLayout {
        TabStripLayout(available: stripWidth, count: buffers.count,
                       selectedIndex: buffers.firstIndex { $0.id == appState.session.selectedBufferID })
    }

    /// New, reopened, restored or chosen from the menu: the selected tab scrolls into view, by as little as it takes.
    private func revealSelected(animated: Bool, proxy: ScrollViewProxy) {
        let buffers = appState.session.orderedBuffers
        guard stripWidth > 0, let id = appState.session.selectedBufferID,
              let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        let layout = layout(for: buffers)
        // The new widths are laid out before the scroll, or a tab added at the end is not there yet.
        DispatchQueue.main.async {
            guard #available(macOS 15, *) else {
                if animated {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                } else {
                    proxy.scrollTo(id)
                }
                return
            }
            guard let x = layout.offset(revealing: index, from: scroll.offset, viewport: stripWidth) else { return }
            requestScroll(to: x, animated: animated)
        }
    }

    private func requestScroll(to x: CGFloat, animated: Bool) {
        scrollRequest = ScrollRequest(x: x, animated: animated, serial: (scrollRequest?.serial ?? 0) + 1)
    }

    /// A mouse wheel only scrolls vertically; over the strip that moves the tabs sideways.
    private func scrollByWheel(_ delta: CGFloat, layout: TabStripLayout, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard #available(macOS 15, *) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let base = now - wheel.time < 0.3 ? wheel.x : scroll.offset
        let x = layout.clampOffset(base - delta, viewport: stripWidth)
        wheel.x = x
        wheel.time = now
        requestScroll(to: x, animated: false)
        return true
    }

    @ViewBuilder private func edgeFades(_ layout: TabStripLayout) -> some View {
        // Metrics stay zero on macOS 14, which has no fades.
        let leading = scroll.viewport > 0 && scroll.offset > 1
        let trailing = scroll.viewport > 0 && scroll.offset + scroll.viewport < layout.contentWidth - 1
        HStack(spacing: 0) {
            if leading { fade(toward: .leading) }
            Spacer(minLength: 0)
            if trailing { fade(toward: .trailing) }
        }
        .allowsHitTesting(false)
    }

    private func fade(toward edge: HorizontalEdge) -> some View {
        LinearGradient(colors: [Color.chromeBackground, Color.chromeBackground.opacity(0)],
                       startPoint: edge == .leading ? .leading : .trailing,
                       endPoint: edge == .leading ? .trailing : .leading)
            .frame(width: TabStripLayout.revealMargin)
    }

    @ViewBuilder private func menu(for buffer: EditorBuffer) -> some View {
        let id = buffer.id
        Button("Close Tab") { appState.closeTab(id) }
        Button("Close Other Tabs") { appState.closeTabs(.others, around: id) }
            .disabled(appState.tabsToClose(.others, around: id).isEmpty)
        Button("Close Tabs to the Left") { appState.closeTabs(.left, around: id) }
            .disabled(appState.tabsToClose(.left, around: id).isEmpty)
        Button("Close Tabs to the Right") { appState.closeTabs(.right, around: id) }
            .disabled(appState.tabsToClose(.right, around: id).isEmpty)
        Button("Close All Tabs") { appState.closeTabs(.all, around: id) }
        Button("Close Unmodified Tabs") { appState.closeTabs(.unmodified, around: id) }
            .disabled(appState.tabsToClose(.unmodified, around: id).isEmpty)
        Divider()
        compareMenu(for: id)
        Divider()
        Button("Move Tab to New Window") { Task { await Workspaces.shared.detachTab(id) } }
        if buffer.isUntitled {
            Divider()
            Button("Rename Tab…") { renamingID = id }
        } else {
            // A broken bookmark has no URL until Relocate.
            let located = appState.fileURLs[id] != nil
            Divider()
            Button("Copy Path") { appState.copyPath(of: id) }.disabled(!located)
            Button("Reveal in Finder") { appState.revealInFinder(id) }.disabled(!located)
        }
    }

    /// Compare With: another tab (unsaved text included) or a file read from disk. Never the tab itself.
    @ViewBuilder private func compareMenu(for id: UUID) -> some View {
        let others = appState.compareCandidates(for: id)
        let titles = TabMenuTitles.make(appState.session.orderedBuffers)
        Menu("Compare With") {
            ForEach(others) { other in
                Button(titles[other.id] ?? other.displayTitle) { appState.compare(id, with: .tab(other.id)) }
            }
            if !others.isEmpty { Divider() }
            Button("Choose File…") { appState.chooseFileToCompare(id) }
        }
    }

    /// `name` is nil when the edit was cancelled. Return, Escape and the field losing focus all
    /// end up here; only the first one counts.
    private func finishRename(_ id: UUID, name: String?) {
        guard renamingID == id else { return }
        renamingID = nil
        if let name { appState.renameTab(id, to: name) }
        appState.host.focus()
    }
}

/// The tab count and a chevron, shown while the strip scrolls: every tab in order, the selected one
/// checked, so a tab scrolled out of sight is one click away. Typing in the open menu jumps to a title.
private struct AllTabsMenu: View {
    @Environment(AppState.self) private var appState
    let buffers: [EditorBuffer]

    var body: some View {
        let titles = TabMenuTitles.make(buffers)
        Menu {
            Picker("All Tabs", selection: Binding(get: { appState.session.selectedBufferID },
                                                  set: { id in if let id { appState.selectTab(id) } })) {
                ForEach(buffers) { buffer in
                    Text(verbatim: titles[buffer.id] ?? buffer.displayTitle).tag(Optional(buffer.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: "\(buffers.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .toolTip(String(localized: "All Tabs"))
        .accessibilityLabel("All Tabs")
    }
}

/// Menu titles for the All Tabs menu: the tab title, the parent directory when another tab has the
/// same title, a mark for a conflict and a dot for unsaved changes.
enum TabMenuTitles {
    static func make(_ buffers: [EditorBuffer], home: String = TitlePathFormatting.userHome) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for b in buffers { counts[b.displayTitle, default: 0] += 1 }
        var titles: [UUID: String] = [:]
        for b in buffers {
            var title = b.displayTitle
            if counts[title, default: 0] > 1, !b.isUntitled, let dir = b.directoryPath {
                title += " — " + TitlePathFormatting.abbreviate(directory: dir, home: home)
            }
            if b.conflict != .none { title = "⚠︎ " + title }
            if b.dirty { title += "  •" }
            titles[b.id] = title
        }
        return titles
    }
}

/// Reports vertical scroll-wheel movement over its area, in points (positive is up), and swallows the
/// event when the handler takes it. Horizontal swipes pass through to the scroll view.
/// macOS 15: the strip's offset is tracked (fades, minimal reveal, wheel) and set from `request`.
private struct TrackedTabScroll: ViewModifier {
    let request: TabBar.ScrollRequest?
    @Binding var metrics: TabBar.ScrollMetrics

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(Tracking(request: request, metrics: $metrics))
        } else {
            content
        }
    }

    @available(macOS 15, *)
    private struct Tracking: ViewModifier {
        let request: TabBar.ScrollRequest?
        @Binding var metrics: TabBar.ScrollMetrics
        @State private var position = ScrollPosition(edge: .leading)

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: TabBar.ScrollMetrics.self) { geometry in
                    TabBar.ScrollMetrics(offset: geometry.contentOffset.x, viewport: geometry.containerSize.width)
                } action: { _, new in
                    metrics = new
                }
                .onChange(of: request) { _, request in
                    guard let request else { return }
                    if request.animated {
                        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(x: request.x) }
                    } else {
                        position.scrollTo(x: request.x)
                    }
                }
        }
    }
}

private struct VerticalWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Bool

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Bool = { _ in false }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                    guard dy != 0, abs(dy) > abs(dx) else { return false }
                    // A wheel reports lines, a trackpad points.
                    return self.onScroll(event.hasPreciseScrollingDeltas ? dy : dy * 24)
                }
                return handled ? nil : event
            }
        }
    }
}
