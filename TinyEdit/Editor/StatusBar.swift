import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let s = appState.status
        HStack(spacing: 16) {
            if let line = s.line {
                Text("Ln \(line), Col \(s.column)")
            } else {
                Text("Ln –, Col \(s.column)")
            }
            if let selection = appState.selectionStats {
                HStack(spacing: 8) {
                    Text("Selected \(selection.characters) chars")
                    if selection.lines > 1 { Text("Lines \(selection.lines)") }
                }
                .monospacedDigit()
                .toolTip([
                    String(localized: "Characters include spaces and line breaks. A combined emoji counts as one character."),
                    String(localized: "Words \(selection.words)"),
                    String(localized: "UTF-8 bytes: \(selection.utf8Bytes)")
                ].joined(separator: "\n"))
            }
            if let tasks = s.tasks {
                Text("Tasks \(tasks.done)/\(tasks.total)")
                    .toolTip(String(localized: "Done / all tasks in this tab"))
            }
            if let size = appState.jsonContainerSize {
                Text(size.label).monospacedDigit()
            }
            if let json = appState.jsonCaret {
                jsonButtons(json)
            }
            Spacer()
            Menu(s.indent.statusLabel) {
                Toggle(String(localized: "Automatic (\(s.automaticIndent.label))"),
                       isOn: Binding(get: { !s.indentOverridden }, set: { _ in appState.setIndentOverride(nil) }))
                Divider()
                ForEach([IndentStyle.tabs, .spaces(2), .spaces(4), .spaces(8)], id: \.label) { style in
                    Toggle(style.label, isOn: Binding(get: { s.indentOverridden && s.indent == style },
                                                      set: { _ in appState.setIndentOverride(style) }))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .toolTip(String(localized: "Change what Tab inserts"))
            Menu(s.encoding.statusLabel) {
                if let b = appState.selectedBuffer, !b.isUntitled {
                    Section("Reopen with Encoding") {
                        ForEach(TextEncoding.reopenChoices, id: \.self) { enc in
                            Button(enc.menuLabel) { appState.reopen(with: enc) }
                        }
                    }
                }
                Section("Save with Encoding") {
                    ForEach(TextEncoding.allCases, id: \.self) { enc in
                        Toggle(enc.menuLabel, isOn: Binding(get: { s.encoding == enc },
                                                            set: { _ in appState.saveWith(encoding: enc) }))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .toolTip(String(localized: "Reopen or save with another encoding"))
            Menu(s.lineEnding.statusLabel) {
                Section("Save with Line Ending") {
                    ForEach([LineEnding.lf, .crlf], id: \.self) { ending in
                        Toggle(ending.statusLabel, isOn: Binding(get: { s.lineEnding == ending },
                                                                 set: { _ in appState.saveWith(lineEnding: ending) }))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .toolTip(String(localized: "Save with another line ending"))
            Menu(s.languageLabel) {
                Button("Detect Language from Content") { appState.detectLanguageFromContent() }
                Divider()
                ForEach(EditorLanguage.menuOrder, id: \.self) { lang in
                    Toggle(lang.statusLabel, isOn: Binding(get: { appState.selectedBuffer?.language == lang },
                                                           set: { _ in appState.setLanguage(lang) }))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .toolTip(String(localized: "Change syntax highlighting"))
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color.chromeBackground)
    }

    /// The copy buttons, then what the value offers: Open Link, Query, Preview or Decode in place of
    /// Open Value, and a Unix time or a color swatch to read. The path comes last to keep the buttons stable.
    private func jsonButtons(_ json: JSONCaretInfo) -> some View {
        let v = json.value
        let host = v.link?.host() ?? ""
        return HStack(spacing: 2) {
            if json.hasKey {
                StatusGhostButton(String(localized: "Copy Key"),
                                  hint: String(localized: "Copy the key of \(json.path)")) { appState.copyJSONKey() }
            }
            StatusGhostButton(String(localized: "Copy Value"),
                              hint: String(localized: "Copy the value of \(json.path)")) { appState.copyJSONValue() }
            if v.link != nil {
                StatusGhostButton(String(localized: "Open Link"),
                                  hint: String(localized: "Open \(host) in the browser")) { appState.openJSONLink() }
            }
            if v.linkHasQuery {
                StatusGhostButton(String(localized: "Query"),
                                  hint: String(localized: "Open the link's query parameters as JSON in a new tab")) {
                    appState.openJSONQuery()
                }
            }
            if let image = v.image {
                StatusGhostButton(String(localized: "Preview"),
                                  hint: image == .remote ? String(localized: "Download the picture from \(host) and show it")
                                      : String(localized: "Show the picture in \(json.path)")) { appState.previewJSONImage() }
            }
            if !v.decodes.isEmpty {
                StatusGhostButton(String(localized: "Decode"),
                                  hint: String(localized: "Decode the value of \(json.path)")) { appState.decodeJSONValue() }
            }
            if json.canOpen, v.link == nil, v.image == nil, v.decodes.isEmpty {
                StatusGhostButton(String(localized: "Open Value"),
                                  hint: String(localized: "Open the value of \(json.path) in a new tab")) { appState.openJSONValue() }
            }
            if let date = v.date {
                StatusGhostButton(JSONValueInsight.dateText(date, milliseconds: v.dateHasMilliseconds),
                                  hint: String(localized: "Unix timestamp in local time (\(JSONValueInsight.offsetText(date))). Click to copy.")) {
                    appState.copyJSONDate()
                }
                .monospacedDigit()
            }
            if let color = v.color {
                ColorSwatch(color: color)
            }
            StatusGhostButton(json.path, hint: String(localized: "Copy the path \(json.path)"), maxWidth: 220) {
                appState.copyJSONPath()
            }
        }
    }
}

/// The color a JSON string names, as a small rounded square.
private struct ColorSwatch: View {
    let color: JSONColor

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.separator))
            .frame(width: 12, height: 12)
            .padding(.horizontal, 5)
            .toolTip(hex)
    }

    private var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(color.red) + byte(color.green) + byte(color.blue) + (color.alpha < 1 ? byte(color.alpha) : "")
    }
}

/// A borderless status-bar button that shows a background only under the pointer. With `maxWidth` the
/// title is cut in the middle rather than pushing the status bar wider.
private struct StatusGhostButton: View {
    let title: String
    let hint: String
    let maxWidth: CGFloat?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, hint: String, maxWidth: CGFloat? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.maxWidth = maxWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(hovering ? Color.textPrimary : Color.textSecondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(height: 18)
                .background(hovering ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        .fixedSize(horizontal: maxWidth == nil, vertical: true)
        .onHover { hovering = $0 }
        .toolTip(hint)
    }
}
