import SwiftUI

/// The status bar of a large-file tab: where you are, how much is read, the edits, Follow and the file's facts.
struct LargeFileStatusBar: View {
    @Environment(AppState.self) private var appState
    let status: LargeFileStatus

    var body: some View {
        HStack(spacing: 16) {
            if let line = status.line {
                Text("Ln \(line)").monospacedDigit()
            }
            Text("Large File")
                .foregroundStyle(Color.textTertiary)
                .toolTip(String(localized: "Read in place, never loaded whole. Select lines and press Return to edit them."))
            if status.opening {
                Text("Opening…")
            } else if let indexed = status.indexed {
                Text("Reading \(Int(indexed * 100))%").monospacedDigit()
            } else {
                Text("Lines \(status.lines)").monospacedDigit()
            }
            if status.checkingEdits {
                Text("Checking edits…")
            }
            if let filter = status.filter {
                if let rows = filter.rows {
                    Text(filter.capped ? "Matching lines: first \(rows)" : "Matching lines \(rows)").monospacedDigit()
                        .toolTip(String(localized: "Double-click a line, or press Return, to show it in the file"))
                } else {
                    Text("Filtering…")
                }
            }
            if status.editedRows > 0 {
                Text("Edited lines \(status.editedRows)")
                    .foregroundStyle(Color.accent)
                    .monospacedDigit()
            }
            if let saving = status.saving {
                Text("Saving \(Int(saving * 100))%").monospacedDigit()
            }
            if status.canEdit, status.hasSelection {
                StatusChip(String(localized: "Edit Lines"), hint: String(localized: "Edit the selected lines (Return)")) {
                    appState.largeFileEditLines()
                }
            }
            Spacer()
            StatusChip(String(localized: "Follow"), hint: String(localized: "Keep the end of the file in view as it grows"),
                       isOn: status.follow) {
                appState.setLargeFileFollow(!status.follow)
            }
            if status.canOpenInEditor {
                StatusChip(String(localized: "Open in Editor"),
                           hint: String(localized: "Open this file in the editor, with syntax colors and text tools")) {
                    appState.openLargeFileInEditor()
                }
            }
            Text(verbatim: AppState.byteSize(status.bytes)).monospacedDigit()
            Menu(status.encoding.statusLabel) {
                Section("Reopen with Encoding") {
                    ForEach(TextEncoding.reopenChoices, id: \.self) { enc in
                        Button(enc.menuLabel) { appState.reopen(with: enc) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .toolTip(String(localized: "Reopen or save with another encoding"))
            Text(verbatim: status.lineEnding.statusLabel)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Color.chromeBackground)
    }
}

/// A borderless status-bar button; accent-colored while `isOn`.
private struct StatusChip: View {
    let title: String
    let hint: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, hint: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .foregroundStyle(isOn ? Color.accent : hovering ? Color.textPrimary : Color.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(hovering ? Color.tabHoverBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        .fixedSize()
        .onHover { hovering = $0 }
        .toolTip(hint)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Edit Lines: the selected rows' text in a plain editor. Apply replaces them as one undo step.
struct LargeFileLineEditor: View {
    @Environment(AppState.self) private var appState
    let request: LargeFileLineEditRequest
    @State private var box: TextBox

    final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    init(request: LargeFileLineEditRequest) {
        self.request = request
        _box = State(initialValue: TextBox(request.text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.firstLine == request.lastLine ? "Edit Line \(request.firstLine)"
                 : "Edit Lines \(request.firstLine)–\(request.lastLine)")
                .font(.headline)
            PlainTextEditor(box: box, fontSize: appState.settings.fontSize)
                .frame(minWidth: 560, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.separator))
            Text("The file changes only when you save.")
                .font(.system(size: 11))
                .foregroundStyle(Color.textSecondary)
            HStack {
                Spacer()
                Button("Cancel") { appState.cancelLargeLineEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { appState.applyLargeLineEdit(request, text: box.text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

/// An `NSTextView` with every substitution off, so quotes and dashes in a log stay as they are. The text lives
/// in the box, not in SwiftUI state.
private struct PlainTextEditor: NSViewRepresentable {
    let box: LargeFileLineEditor.TextBox
    let fontSize: Double

    final class Coordinator: NSObject, NSTextViewDelegate {
        let box: LargeFileLineEditor.TextBox
        init(box: LargeFileLineEditor.TextBox) { self.box = box }

        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { box.text = tv.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(box: box) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        EditorFeatureFlags.plainText.apply(to: tv)
        tv.font = EditorConfiguration.font(size: fontSize)
        tv.textColor = Theme.textPrimary
        tv.backgroundColor = Theme.editorBackground
        tv.insertionPointColor = Theme.accent
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = box.text
        tv.delegate = context.coordinator
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
