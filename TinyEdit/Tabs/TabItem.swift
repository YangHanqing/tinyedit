import SwiftUI

struct TabItem: View {
    let buffer: EditorBuffer
    let isSelected: Bool
    /// From `TabStripLayout`: the tabs share the bar's width.
    var width: CGFloat = TabStripLayout.maxWidth
    let onSelect: () -> Void
    let onClose: () -> Void
    var isRenaming = false
    var onRename: (String?) -> Void = { _ in }
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if buffer.conflict != .none {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
                    .accessibilityLabel("File conflict")
            }
            if buffer.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel("Pinned")
            }
            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textPrimary)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { onRename(nil) }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
                    .onAppear {
                        draft = buffer.displayTitle
                        // Focus after the field is in the window; the editor holds first responder until then.
                        DispatchQueue.main.async { fieldFocused = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(buffer.displayTitle)
                    .lineLimit(1)
                    // A file name keeps its extension; a name taken from the text reads from its start.
                    .truncationMode(buffer.isUntitled ? .tail : .middle)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                if buffer.dirty && !hovering {
                    Circle().fill(Color.textSecondary).frame(width: 6, height: 6)
                } else {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.textSecondary)
                    .opacity(hovering || isSelected ? 1 : 0)
                    .accessibilityLabel("Close Tab")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .background(isSelected ? Color.tabSelectedBackground : hovering ? Color.tabHoverBackground : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }

    /// An untouched name is not a rename: an auto title would otherwise freeze with its "…".
    private func commitRename() {
        onRename(draft == buffer.displayTitle ? nil : draft)
    }
}
