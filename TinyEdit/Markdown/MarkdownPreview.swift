import SwiftUI

struct MarkdownPreview: View {
    @Environment(AppState.self) private var appState

    @State private var imageAccess = MarkdownImageAccess()
    private var documentURL: URL? { appState.session.selectedBufferID.flatMap { appState.fileURLs[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownReadingToolbar(reader: appState.previewReader)
            ThemeDivider()
            MarkdownPage(blocks: appState.previewBlocks, message: appState.previewMessage,
                         identity: appState.session.selectedBufferID, reader: appState.previewReader)
        }
            .environment(\.markdownOpenDocument, OpenURLAction { url in
                Task { await appState.openMarkdownLink(url) }
                return .handled
            })
            .environment(\.markdownDocumentURL, documentURL)
            .environment(\.markdownImageAccess, imageAccess)
            .environment(\.markdownBodySize, MarkdownStyle.bodySize(editorFontSize: appState.settings.fontSize))
            .onChange(of: appState.session.selectedBufferID, initial: true) { _, _ in
                imageAccess.activate(document: documentURL)
            }
            .onChange(of: documentURL) { _, _ in imageAccess.activate(document: documentURL) }
            .onDisappear { imageAccess.reset() }
            .onChange(of: appState.previewReader.navigationFailed) { _, failed in
                if failed {
                    appState.showToast(String(localized: "Heading not found"), error: true)
                    appState.previewReader.navigationFailed = false
                }
            }
    }
}

/// Compact reading tools stay above the page, so searching never covers a result or changes modes.
private struct MarkdownReadingToolbar: View {
    @Environment(AppState.self) private var appState
    @Bindable var reader: MarkdownReader
    @State private var outlineVisible = false
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { outlineVisible.toggle() } label: {
                    Label("Outline", systemImage: "list.bullet.indent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(reader.headings.isEmpty)
                .popover(isPresented: $outlineVisible, arrowEdge: .bottom) {
                    MarkdownOutline(reader: reader) { outlineVisible = false }
                }
                Spacer(minLength: 0)
                Menu("Sections", systemImage: "rectangle.compress.vertical") {
                    Button("Collapse All Sections") { reader.foldAll() }
                    Button("Expand All Sections") { reader.unfoldAll() }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 11))
                .foregroundStyle(Color.textSecondary)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!reader.headings.contains(where: \.canFold))
                .toolTip(String(localized: "Sections"))
                .accessibilityLabel(String(localized: "Sections"))
                IconButton(systemName: "magnifyingglass", help: String(localized: "Find in Preview")) { appState.showPreviewFind() }
            }
            if reader.findVisible { findBar }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.chromeBackground)
    }

    private var findBar: some View {
        VStack(spacing: 3) {
            FieldBox(focused: findFocused, alert: reader.matchCount == 0 || reader.invalidPattern) {
                TextField("Find in Preview", text: $reader.query)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onSubmit { reader.nextMatch() }
                OptionToggle(label: "Aa", help: String(localized: "Case sensitive"), isOn: $reader.caseSensitive)
                OptionToggle(label: ".*", help: String(localized: "Regular expression"), isOn: $reader.regex)
            }
            HStack(spacing: 3) {
                Group {
                    if reader.invalidPattern { Text("Invalid pattern").foregroundStyle(Color.error) }
                    else if let count = reader.matchCount {
                        if count == 0 { Text("No matches").foregroundStyle(Color.error) }
                        else { Text(verbatim: "\(reader.currentMatch ?? 0)/\(count)\(reader.capped ? "+" : "")").foregroundStyle(Color.textSecondary) }
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                Spacer(minLength: 0)
                IconButton(systemName: "arrow.up", help: String(localized: "Find Previous")) { reader.nextMatch(forward: false) }
                    .disabled((reader.matchCount ?? 0) == 0)
                IconButton(systemName: "arrow.down", help: String(localized: "Find Next")) { reader.nextMatch() }
                    .disabled((reader.matchCount ?? 0) == 0)
                CloseButton(label: String(localized: "Close")) { reader.closeFind() }
            }
        }
        .onAppear { findFocused = true }
        .onChange(of: reader.focusToken) { _, _ in findFocused = true }
        .onChange(of: reader.query) { _, _ in reader.refreshSearch() }
        .onChange(of: reader.caseSensitive) { _, _ in reader.refreshSearch() }
        .onChange(of: reader.regex) { _, _ in reader.refreshSearch() }
        .background {
            Button("") { reader.nextMatch(forward: false) }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(!findFocused)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

private struct MarkdownOutline: View {
    let reader: MarkdownReader
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool
    private var headings: [MarkdownStructure.Heading] {
        reader.headings.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find Heading", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let heading = headings.first { reader.reveal(path: heading.path); dismiss() } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if headings.isEmpty {
                        Text("No matches").font(.system(size: 12)).foregroundStyle(Color.textTertiary).padding(6)
                    }
                    ForEach(headings) { heading in
                        Button { reader.reveal(path: heading.path); dismiss() } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: "H\(heading.level)")
                                    .font(.system(size: 9, weight: .medium).monospaced())
                                    .foregroundStyle(Color.textTertiary)
                                Text(verbatim: heading.title).lineLimit(2)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12))
                            .padding(.leading, CGFloat(heading.level - 1) * 8)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressedOpacityStyle())
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, height: 340)
        .background(Color.chromeBackground)
        .onAppear { focused = true }
    }
}
