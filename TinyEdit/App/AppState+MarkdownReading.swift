import AppKit

extension AppState {
    func showPreviewFind() {
        guard previewVisible else { return }
        if find.visible {
            find.visible = false
            findMatches.clear()
            setFindCounts(nil, nil, false)
        }
        goToLineVisible = false
        previewReader.openFind()
    }

    /// Only a click enters here. Resolve against the saved document, then use the normal open path
    /// (bookmarks, size checks, tab limit, existing unsaved buffers). Never open a URL through a shell.
    func openMarkdownLink(_ source: URL) async {
        guard source.scheme == nil || source.isFileURL,
              !source.relativeString.hasPrefix("//"),
              source.host == nil || source.host == "" || source.host == "localhost" else { return }
        let resolved: URL
        if source.isFileURL { resolved = source }
        else {
            guard let id = session.selectedBufferID, let document = fileURLs[id] else {
                showToast(String(localized: "Save this document before opening relative links."), error: true)
                return
            }
            guard let url = URL(string: source.relativeString, relativeTo: document)?.absoluteURL, url.isFileURL else { return }
            resolved = url
        }
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true), components.query == nil else { return }
        let fragment = components.percentEncodedFragment
        components.fragment = nil
        guard let url = components.url?.standardizedFileURL else { return }
        var target = url
        // Never silently open internal app persistence files (session.json, snapshots) or non-regular files
        // such as directories, FIFOs, or device nodes (/dev/zero).
        let appRoot = AppPaths.root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = target.resolvingSymlinksInPath().path
        if resolvedPath == appRoot || resolvedPath.hasPrefix(appRoot + "/") { return }
        if FileManager.default.fileExists(atPath: target.path), FileLoader.regularFileStats(at: target) == nil {
            return
        }
        // A path is not a sandbox grant. Ask for the exact linked file only when no existing grant
        // (an open folder, an already-open tab or a file selected before) reaches it.
        if bufferID(for: target) == nil && !FileManager.default.isReadableFile(atPath: target.path) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = target.deletingLastPathComponent()
            panel.nameFieldStringValue = target.lastPathComponent
            panel.message = String(localized: "Choose the linked document to allow access.")
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            guard FileAccessManager.key(selected) == FileAccessManager.key(target) else {
                showToast(String(localized: "The selected file is not the linked document."), error: true)
                return
            }
            target = selected
        }
        guard FileLoader.regularFileStats(at: target) != nil else { return }
        await openURLsAsync([target])
        guard let id = bufferID(for: target), session.selectedBufferID == id,
              session.buffers[id]?.language == .markdown, activeLargeFile == nil else { return }
        session.buffers[id]?.markdownPreviewVisible = true
        schedulePreview(delay: .zero)
        flushImmediately()
        if let fragment { previewReader.navigateWhenReady(fragment: fragment, identity: id) }
    }
}
