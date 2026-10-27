import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    /// English source title, so a search still hits after the interface is translated.
    let englishTitle: String
    let keywords: String
    /// The section the command is listed under, also shown dimmed at the end of a search hit.
    /// Not searched: "decode" should not match every encoder.
    var category = ""
    /// How much the command would act on, as a badge. Nil when not counted.
    var count: Int?
    /// False when it would fail or change nothing here (`ToolInsights.disabled`): drawn dimmed, never selected or run.
    var enabled = true
    let action: @MainActor () -> Void

    /// Every query word must occur in the localized title, the English title, or the keywords.
    /// A title that starts with the first word (in either language) sorts first; disabled commands sort last.
    static func filter(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let words = query.lowercased().split(separator: " ")
        guard let first = words.first else { return commands }
        let hits = commands.filter { c in
            let hay = (c.title + " " + c.englishTitle + " " + c.keywords).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        func prefixed(_ c: PaletteCommand) -> Bool {
            c.title.lowercased().hasPrefix(first) || c.englishTitle.lowercased().hasPrefix(first)
        }
        let ranked = hits.filter(prefixed) + hits.filter { !prefixed($0) }
        return ranked.filter(\.enabled) + ranked.filter { !$0.enabled }
    }
}

struct PaletteSection: Identifiable {
    let id: String
    let title: String
    let commands: [PaletteCommand]

    /// Suggested first (in the order given), then the commands grouped by category in their own order,
    /// enabled ones first. Categories with nothing enabled go last. A suggested command is listed in its category too.
    static func make(_ commands: [PaletteCommand], suggested: [String]) -> [PaletteSection] {
        var sections: [PaletteSection] = []
        let picks = suggested.compactMap { id in commands.first { $0.id == id && $0.enabled } }
        if !picks.isEmpty {
            sections.append(PaletteSection(id: "suggested", title: String(localized: "Suggested"), commands: picks))
        }
        var order: [String] = []
        var grouped: [String: [PaletteCommand]] = [:]
        for command in commands {
            if grouped[command.category] == nil { order.append(command.category) }
            grouped[command.category, default: []].append(command)
        }
        let groups = order.map { category in
            let all = grouped[category]!
            return PaletteSection(id: "group." + category, title: category,
                                  commands: all.filter(\.enabled) + all.filter { !$0.enabled })
        }
        let live = groups.filter { $0.commands.first?.enabled == true }
        sections += live + groups.filter { $0.commands.first?.enabled != true }
        return sections
    }
}

/// ⇧⌘P: a search field over `AppState.paletteCommands`, floating at the top of the editor. With no
/// query it lists everything in sections (Suggested, then one per tool group); typing searches all of
/// them as one ranked list, with the open tabs. `ToolInsights` picks the Suggested commands, dims the ones that
/// would do nothing (the arrows skip them), and counts what a cleanup would remove before it runs.
struct CommandPalette: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.paletteVisible { CommandPalettePanel() }
    }
}

/// Keep search and focus state scoped to each presentation of the panel.
private struct CommandPalettePanel: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private let rowHeight: CGFloat = 28
    private let headerHeight: CGFloat = 24
    private let maxHeight: CGFloat = 360

    private enum Row: Identifiable {
        case header(String, id: String)
        /// `index` is the command's place in keyboard order; nil for a disabled one.
        case command(PaletteCommand, id: String, index: Int?)

        var id: String {
            switch self {
            case .header(_, let id), .command(_, let id, _): id
            }
        }
    }

    var body: some View {
        panel
    }

    /// The rows to draw, and the enabled commands they hold in keyboard order (a suggested command appears twice).
    private func layout() -> (rows: [Row], commands: [PaletteCommand]) {
        var rows: [Row] = []
        var commands: [PaletteCommand] = []
        func add(_ command: PaletteCommand, key: String) {
            rows.append(.command(command, id: key, index: command.enabled ? commands.count : nil))
            if command.enabled { commands.append(command) }
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            for section in appState.paletteSections {
                rows.append(.header(section.title, id: "header." + section.id))
                for command in section.commands { add(command, key: section.id + "/" + command.id) }
            }
        } else {
            for command in PaletteCommand.filter(appState.paletteCommands + appState.paletteTabCommands, query: query) { add(command, key: command.id) }
        }
        return (rows, commands)
    }

    @ViewBuilder private var panel: some View {
        let (rows, commands) = layout()
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            TextField(appState.paletteOnSelection ? "Run a command on the selection" : "Run a command or find a tab", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .focused($focused)
                .onSubmit { run(commands) }
                .onKeyPress(.downArrow) { index = min(index + 1, max(commands.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { appState.hidePalette(); return .handled }
            ThemeDivider()
            if rows.isEmpty {
                Text("No matching command")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                switch row {
                                case .header(let title, _):
                                    header(title)
                                case .command(let command, let key, let i?):
                                    commandRow(command, selected: i == index, showCategory: searching)
                                        .onHover { if $0 { index = i } }
                                        .onTapGesture { index = i; run(commands) }
                                        .id(key)
                                case .command(let command, let key, nil):
                                    commandRow(command, selected: false, showCategory: searching)
                                        .id(key)
                                }
                            }
                        }
                        .padding(.bottom, searching ? 0 : 4)
                    }
                    .frame(height: min(height(of: rows), maxHeight))
                    .onChange(of: index) { _, i in
                        if case .command(_, let key, _)? = rows.first(where: { if case .command(_, _, .some(i)) = $0 { true } else { false } }) {
                            proxy.scrollTo(key)
                        }
                    }
                }
            }
        }
        .frame(width: 440)
        .background(Color.editorBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.separator))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.top, 8)
        .onAppear { query = ""; index = 0 }
        .task {
            // Let SwiftUI attach the search field before requesting keyboard focus.
            await Task.yield()
            guard !Task.isCancelled, appState.paletteVisible else { return }
            focused = true
        }
        .onChange(of: query) { _, _ in index = 0 }
        // Clicking back into the editor dismisses the palette.
        .onChange(of: focused) { _, f in if !f { appState.hidePalette() } }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(maxWidth: .infinity, minHeight: headerHeight, alignment: .bottomLeading)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func commandRow(_ command: PaletteCommand, selected: Bool, showCategory: Bool) -> some View {
        HStack(spacing: 8) {
            Text(command.title)
                .foregroundStyle(command.enabled ? Color.textPrimary : Color.textTertiary)
            Spacer(minLength: 12)
            if showCategory {
                Text(command.category)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
            }
            if command.enabled, let count = command.count, count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accent.opacity(0.15), in: Capsule())
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 10)
        .background(selected ? Color.tabSelectedBackground : .clear)
        .contentShape(Rectangle())
    }

    private func height(of rows: [Row]) -> CGFloat {
        rows.reduce(0) { total, row in
            if case .header = row { total + headerHeight + 2 } else { total + rowHeight }
        } + (query.trimmingCharacters(in: .whitespaces).isEmpty ? 4 : 0)
    }

    private func run(_ commands: [PaletteCommand]) {
        guard commands.indices.contains(index) else { return }
        let command = commands[index]
        appState.hidePalette()
        command.action()
    }
}
