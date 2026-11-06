import SwiftUI

/// Settings ▸ General: whether `tinyedit` is installed, and the Terminal line that installs or removes it.
/// The sandbox cannot write to /usr/local/bin, so the user runs that line. The status is read again whenever
/// the app becomes active, so it changes on the way back from Terminal.
struct CommandLineToolSection: View {
    @State private var status = CommandLineTool.Status.unknown
    @State private var copied = false

    private let script = CommandLineTool.scriptURL(inApp: Bundle.main.bundleURL)

    var body: some View {
        Section {
            LabeledContent("Command Line Tool") { statusLabel }
            VStack(alignment: .leading, spacing: 8) {
                Text(status == .installed ? "To remove it, run in Terminal:" : "To install it, run in Terminal:")
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.editorBackground, in: RoundedRectangle(cornerRadius: 4))
                    Button(copied ? "Copied" : "Copy", action: copy)
                }
            }
        } footer: {
            Text("Then `tinyedit notes.md` opens a file, `tinyedit main.swift:120` opens it at a line, and `command | tinyedit` opens what a command prints in a new tab. Run `tinyedit -h` for more. The command follows TinyEdit’s updates.")
                .settingsFootnote()
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var command: String {
        status == .installed ? CommandLineTool.uninstallCommand : CommandLineTool.installCommand(script: script)
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.success)
        case .notInstalled:
            Text("Not installed").foregroundStyle(Color.textSecondary)
        case .other(let destination):
            Text("Points to another copy")
                .foregroundStyle(Color.warning)
                .toolTip(destination)
        case .unknown:
            Text(verbatim: "—").foregroundStyle(Color.textTertiary)
        }
    }

    private func refresh() {
        status = CommandLineTool.currentStatus(script: script)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
