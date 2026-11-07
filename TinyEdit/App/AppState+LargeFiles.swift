import AppKit

/// Files over `FileLoader.maxOpenBytes`: the refusal names both sizes, and the file's beginning can open
/// as an Untitled tab. That tab has no file behind it, so a save can never put the cut text over the file.
extension AppState {
    static let largeFileHeadBytes = 2 * 1_048_576

    /// Binary units, so the cap reads "64 MB" rather than "67.1 MB".
    static func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// For toasts where no preview is offered (reload, reopen with an encoding).
    static func tooLargeMessage(_ name: String, bytes: Int) -> String {
        String(localized: "“\(name)” is \(byteSize(bytes)). TinyEdit opens files up to \(byteSize(FileLoader.maxOpenBytes)).")
    }

    /// Asks, then opens the first `largeFileHeadBytes` of `url` in a new Untitled tab named after `name`.
    func offerLargeFileHead(_ url: URL, name: String, bytes: Int) async {
        let head = Self.byteSize(Self.largeFileHeadBytes)
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” is too large to open")
        alert.informativeText = String(localized: "It is \(Self.byteSize(bytes)). TinyEdit opens files up to \(Self.byteSize(FileLoader.maxOpenBytes)). Its first \(head) can open in a new Untitled tab, which is not linked to the file.")
        alert.addButton(withTitle: String(localized: "Open First \(head)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, ensureRoomForTab() else { return }

        let started = access.start(url)
        defer { if started { access.stop(url) } }
        let limit = Self.largeFileHeadBytes
        guard let loaded = try? await Task.detached(priority: .userInitiated, operation: {
            try FileLoader.loadHead(of: url, maxBytes: limit)
        }).value else {
            return showToast(String(localized: "Could not open file"), error: true)
        }
        guard !closing, !transferring, openTranslationTab(loaded.logicalLF), let id = session.selectedBufferID else { return }
        renameTab(id, to: String(localized: "\(name) (first \(head))"))
        let language = EditorLanguage.detect(fileName: name, text: String(loaded.logicalLF.prefix(200)))
        if language != .plain { setLanguage(language) }
    }
}
