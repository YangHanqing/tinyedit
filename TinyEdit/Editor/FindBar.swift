import SwiftUI

/// The find card, floating over the editor's top-right corner above any suggestion card. Typing searches
/// as you go: every match is highlighted, the one from where the search started is selected, and the
/// card shows "current/total". Return finds the next, Shift-Return the previous, Escape closes.
struct FindBar: View {
    @Environment(AppState.self) private var appState
    @FocusState private var focus: Field?
    private enum Field { case query, replacement }

    private static let fieldWidth: CGFloat = 244
    private static let toggleWidth: CGFloat = 20

    var body: some View {
        @Bindable var find = appState.find
        ZStack(alignment: .topTrailing) {
            if find.visible {
                card(find)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, find.visible ? 10 : 0)
        .animation(.easeOut(duration: 0.18), value: find.visible)
    }

    private func card(_ find: FindModel) -> some View {
        @Bindable var find = find
        let noMatches = find.matchCount == 0 || find.invalidPattern
        let canStep = (find.matchCount ?? 0) > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconButton(systemName: "chevron.right", help: String(localized: "Show Replace"), size: 10) {
                    find.showReplace.toggle()
                    if find.showReplace { focus = .replacement } else if focus == .replacement { focus = .query }
                }
                .rotationEffect(.degrees(find.showReplace ? 90 : 0))
                .frame(width: Self.toggleWidth)
                FieldBox(focused: focus == .query, alert: noMatches) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                    TextField("Find", text: $find.query)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .query)
                        .onSubmit { appState.findNext() }
                    OptionToggle(label: "Aa", help: String(localized: "Case sensitive"), isOn: $find.caseSensitive)
                    OptionToggle(label: ".*", help: String(localized: "Regular expression"), isOn: $find.regex)
                }
                .frame(width: Self.fieldWidth)
                counter(find)
                    .frame(minWidth: 62, alignment: .center)
                IconButton(systemName: "arrow.up", help: String(localized: "Find Previous")) { appState.findPrevious() }
                    .disabled(!canStep)
                IconButton(systemName: "arrow.down", help: String(localized: "Find Next")) { appState.findNext() }
                    .disabled(!canStep)
                if appState.largeStatus != nil {
                    IconButton(systemName: find.filterLines ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                               help: find.filterLines ? String(localized: "Show All Lines") : String(localized: "Show Only Matching Lines")) {
                        appState.setLargeFilter(!find.filterLines)
                    }
                    .disabled(find.query.isEmpty)
                }
                CloseButton(label: String(localized: "Close")) { appState.hideFind() }
            }
            if find.showReplace {
                HStack(spacing: 6) {
                    Color.clear.frame(width: Self.toggleWidth, height: 1)
                    FieldBox(focused: focus == .replacement, alert: false) {
                        TextField("Replace", text: $find.replacement)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .replacement)
                            .onSubmit { appState.replaceCurrent() }
                    }
                    .frame(width: Self.fieldWidth)
                    CardButton("Replace", help: String(localized: "Replace"), prominent: false) { appState.replaceCurrent() }
                        .disabled(!canStep)
                    CardButton("Replace All", help: String(localized: "Replace All"), prominent: false) { appState.replaceAll() }
                        .disabled(!canStep)
                }
            }
        }
        .floatingCard(leading: 6)
        .background(shortcuts)
        .onChange(of: find.query) { _, _ in appState.findQueryChanged() }
        .onChange(of: find.caseSensitive) { _, _ in appState.findQueryChanged() }
        .onChange(of: find.regex) { _, _ in appState.findQueryChanged() }
        .onChange(of: find.focusToken) { _, _ in focus = find.focusReplace ? .replacement : .query }
        .onAppear { focus = find.focusReplace ? .replacement : .query }
    }

    @ViewBuilder private func counter(_ find: FindModel) -> some View {
        Group {
            if find.invalidPattern {
                Text("Invalid pattern").foregroundStyle(Color.error)
            } else if let count = find.matchCount {
                if count == 0 {
                    Text("No matches").foregroundStyle(Color.error)
                } else {
                    let total = find.capped ? "\(count)+" : "\(count)"
                    Text(verbatim: "\(find.currentMatch.map(String.init) ?? "–")/\(total)")
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    /// Escape anywhere closes the card; Shift-Return in the find field goes back.
    private var shortcuts: some View {
        ZStack {
            Button("") { appState.hideFind() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("") { appState.findPrevious() }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(focus != .query)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A text field's box: editor-colored, outlined in the accent while focused and in red when nothing matches.
struct FieldBox<Content: View>: View {
    let focused: Bool
    let alert: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 12))
            .padding(.leading, 8)
            .padding(.trailing, 3)
            .frame(height: 26)
            .background(Color.editorBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(alert ? Color.error : focused ? Color.accent : Color.separator, lineWidth: focused || alert ? 1.5 : 1))
    }
}

/// "Aa" (case) and ".*" (regular expression) inside the find field: accent-filled while on.
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Color.onAccent : hovering ? Color.textPrimary : Color.textTertiary)
                .frame(width: 24, height: 20)
                .background(isOn ? Color.accent : hovering ? Color.tabHoverBackground : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        .onHover { hovering = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A square icon button with the title-bar hover background; dimmed while disabled.
struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isEnabled ? (hovering ? Color.textPrimary : Color.textSecondary) : Color.textTertiary.opacity(0.5))
                .frame(width: 22, height: 22)
                .background(hovering && isEnabled ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        .onHover { hovering = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
    }
}
