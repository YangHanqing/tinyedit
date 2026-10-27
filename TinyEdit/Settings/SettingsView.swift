import SwiftUI

/// The standard macOS settings window: toolbar tabs, one grouped form per pane.
struct SettingsView: View {
    private enum Pane: Hashable { case general, editor, defaultApp, translation, shortcuts }

    /// Bound so the window always opens on General instead of the pane it was closed on.
    @State private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsPane().settingsPane(height: 560)
            }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: .editor) {
                EditorSettingsPane().settingsPane(height: 560)
            }
            Tab("Default App", systemImage: "doc.text", value: .defaultApp) {
                DefaultAppSettingsPane().settingsPane(height: 600)
            }
            Tab("Translation", systemImage: "character.bubble", value: .translation) {
                TranslationSettingsView().settingsPane(height: 600)
            }
            Tab("Shortcuts", systemImage: "keyboard", value: .shortcuts) {
                ShortcutsSettingsPane().settingsPane(height: 600)
            }
        }
        .onAppear { pane = .general }
        .onDisappear { pane = .general }
    }
}

extension AppState {
    /// Writes through `updateSettings`, so every change is clamped, saved and applied.
    func setting<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { var s = self.settings; s[keyPath: keyPath] = $0; self.updateSettings(s) })
    }
}

private extension View {
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.chromeBackground)
            .frame(width: 560, height: height)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppState.self) private var appState
    /// The stored choice, not the language this process is displaying.
    @State private var language = AppLanguage.stored

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: appState.setting(\.appearance)) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    Text("App Icon")
                    AppIconChoices(selection: appState.setting(\.appIcon))
                }
                Picker("Background Pattern", selection: appState.setting(\.backgroundPattern)) {
                    ForEach(BackgroundPattern.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(verbatim: "Aa  0123456789")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(EditorBackground(pattern: appState.settings.backgroundPattern))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: language) { _, new in AppLanguage.commit(new) }
            } footer: {
                Text("A new language applies the next time TinyEdit opens.").settingsFootnote()
            }
            Section {
                LabeledContent("Version") {
                    Text(verbatim: "\(Self.bundleValue("CFBundleShortVersionString")) (\(Self.bundleValue("CFBundleVersion")))")
                        .textSelection(.enabled)
                }
            }
        }
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—"
    }
}

private struct EditorSettingsPane: View {
    @Environment(AppState.self) private var appState
    private enum Category: Hashable { case display, input, paste, save, json }
    @State private var category = Category.display

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editor settings category", selection: $category) {
                Text("Display").tag(Category.display)
                Text("Input").tag(Category.input)
                Text("Paste").tag(Category.paste)
                Text("On Save").tag(Category.save)
                Text(verbatim: "JSON").tag(Category.json)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)
            Form {
                switch category {
                case .display: displaySettings
                case .input: inputSettings
                case .paste: pasteSettings
                case .save: saveSettings
                case .json: jsonSettings
                }
            }
            .id(category)
        }
    }

    @ViewBuilder private var displaySettings: some View {
        let s = appState.settings
        Section {
            LabeledContent("Font size") {
                Text("\(Int(s.fontSize)) pt").monospacedDigit()
                Stepper("Font size", value: appState.setting(\.fontSize), in: EditorSettings.fontSizeRange, step: 1)
                    .labelsHidden()
            }
            Toggle("Word wrap", isOn: appState.setting(\.wordWrap))
            Toggle("Show line numbers", isOn: appState.setting(\.showLineNumbers))
            Toggle("Highlight current line", isOn: appState.setting(\.highlightCurrentLine))
            Toggle("Show indent guides", isOn: appState.setting(\.showIndentGuides))
            Toggle("Highlight matching brackets", isOn: appState.setting(\.highlightMatchingBrackets))
            Toggle("Highlight other occurrences of selected text", isOn: appState.setting(\.highlightSelectionOccurrences))
            Toggle("Show invisible characters", isOn: appState.setting(\.showInvisibles))
        }
    }

    @ViewBuilder private var inputSettings: some View {
        let s = appState.settings
        Section {
            Picker("Indent using", selection: appState.setting(\.insertSpaces)) {
                Text("Spaces").tag(true)
                Text("Tabs").tag(false)
            }
            .pickerStyle(.segmented)
            LabeledContent("Tab width") {
                Text(s.tabWidth, format: .number).monospacedDigit()
                Stepper("Tab width", value: appState.setting(\.tabWidth), in: EditorSettings.tabWidthRange)
                    .labelsHidden()
            }
            Toggle("Detect indentation from file content", isOn: appState.setting(\.detectIndentation))
            Toggle("Continue indentation on Return", isOn: appState.setting(\.autoIndent))
            Toggle("Delete indentation one level at a time", isOn: appState.setting(\.smartBackspace))
        } header: {
            Text("Indentation")
        } footer: {
            Text("Tab width sets how wide a TAB character is displayed. When indenting with spaces, it is also the number of spaces per indent level. The indent style applies only when no other rule does: Makefile always uses tabs and YAML always uses spaces; with detection on, a document that is already indented keeps its own indentation; otherwise Go uses tabs and Python uses 4 spaces. The Indent menu in the status bar sets the indent style for the current document and takes precedence over these rules.")
                .settingsFootnote()
        }
        Section {
            Toggle("Continue Markdown tasks on Return", isOn: appState.setting(\.continueMarkdownTasks))
            Toggle("Suggest language while typing", isOn: appState.setting(\.suggestLanguageWhileTyping))
        }
        Section {
            Picker("Inline calculation", selection: appState.setting(\.inlineCalculation)) {
                ForEach(InlineCalculationMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } footer: {
            Text("Shows the result of arithmetic on the cursor line. Press Tab to insert it.").settingsFootnote()
        }
    }

    @ViewBuilder private var pasteSettings: some View {
        Section {
            Toggle("Suggest decoding pasted text", isOn: appState.setting(\.suggestPasteDecodes))
            Toggle("Suggest language and JSON formatting after paste", isOn: appState.setting(\.suggestPasteLanguage))
            Toggle("Suggest cleaning ANSI codes and invisible characters", isOn: appState.setting(\.suggestPasteCleanup))
        } footer: {
            Text("Suggestions leave the text unchanged until you apply them. Text tools remain available in the Tools menu.").settingsFootnote()
        }
        Section {
            Toggle("Recognize text in pasted and dropped images", isOn: appState.setting(\.recognizeTextInImages))
            Toggle("Recognize document structure and tables", isOn: appState.setting(\.recognizeDocumentTables))
                .disabled(!EditorSettings.supportsDocumentTables || !appState.settings.recognizeTextInImages)
        } footer: {
            Text("Pasting or dropping a picture inserts the text in it. Recognition runs on this Mac; nothing is uploaded.")
                .settingsFootnote()
            Text("Document and table recognition requires macOS 26 or later. Tables are inserted as Markdown; the first row becomes the header.")
                .settingsFootnote()
        }
        Section {
            Toggle("Offer to send pasted curl commands", isOn: appState.setting(\.recognizeCurlCommands))
        } footer: {
            Text("Pasting a curl command shows the request it describes with a Send button. Nothing is sent until you click Send.")
                .settingsFootnote()
        }
    }

    @ViewBuilder private var saveSettings: some View {
        Section {
            Toggle("Trim trailing whitespace", isOn: appState.setting(\.trimTrailingWhitespaceOnSave))
            Toggle("End the file with a newline", isOn: appState.setting(\.ensureFinalNewline))
        } header: {
            Text("On Save")
        } footer: {
            Text("Markdown and Diff keep trailing whitespace: it is a line break in Markdown and part of a diff's blank lines.")
                .settingsFootnote()
        }
    }

    @ViewBuilder private var jsonSettings: some View {
        Section {
            Group {
                Toggle("Picture preview icons", isOn: appState.setting(\.jsonMarkImages))
                Toggle("Link icons", isOn: appState.setting(\.jsonMarkLinks))
                Toggle("Color swatches", isOn: appState.setting(\.jsonMarkColors))
                Toggle("Local time of Unix timestamps", isOn: appState.setting(\.jsonMarkTimes))
                Toggle("JWT expiry", isOn: appState.setting(\.jsonMarkJWTExpiry))
                Toggle("Decode icons", isOn: appState.setting(\.jsonMarkDecodes))
            }
            .toggleStyle(.checkbox)
        } header: {
            Text(verbatim: "JSON")
        } footer: {
            Text("Shown after the line in JSON tabs, one per line. Click an icon or a time to preview, open, decode or copy it.")
                .settingsFootnote()
        }
    }

}

private extension Text {
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected icon appears in the Dock and the title bar.
private struct AppIconChoices: View {
    @Binding var selection: AppIconStyle

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(AppIconStyle.allCases, id: \.self) { style in
                let selected = style == selection
                Button { selection = style } label: {
                    VStack(spacing: 4) {
                        if let image = NSImage(named: style.imageName) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: 44, height: 44)
                        }
                        Text(style.label)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.accent : Color.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selected ? Color.tabSelectedBackground : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
