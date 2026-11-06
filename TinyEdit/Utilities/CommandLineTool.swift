import Foundation

/// The `tinyedit` command (`CommandLine/tinyedit`, copied to `Contents/SharedSupport/bin`). Besides the files
/// it names, it opens small request files from its spool folder in the same open event: text piped into it,
/// and a line to go to in one of the files. This decides what each opened URL is and builds the commands
/// Settings offers for installing it, which the sandbox cannot do itself.
enum CommandLineTool {
    static let pipeExtension = "tinyedit-stdin"
    static let goToExtension = "tinyedit-goto"
    /// The script's folder under the user's temporary directory. Only request files in it are deleted.
    static let spoolFolderName = "TinyEdit-cli"

    static let linkPath = "/usr/local/bin/tinyedit"

    enum Request: Equatable {
        /// A file whose text goes into a new Untitled tab.
        case pipedText(URL)
        /// Put the caret at `line` (and `column`) of the file at `file`.
        case goTo(file: URL, line: Int, column: Int?)
    }

    static func isRequest(_ url: URL) -> Bool {
        url.isFileURL && [pipeExtension, goToExtension].contains(url.pathExtension)
    }

    /// The request a URL from `isRequest` holds, reading a go-to file; nil when one is malformed.
    static func request(at url: URL) -> Request? {
        switch url.pathExtension {
        case pipeExtension: return .pipedText(url)
        case goToExtension:
            guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 64 * 1024,
                  let contents = String(data: data, encoding: .utf8) else { return nil }
            return goTo(parsing: contents)
        default: return nil
        }
    }

    /// "line[:column]", a newline, then the absolute path (which may hold anything but a NUL).
    static func goTo(parsing contents: String) -> Request? {
        guard let newline = contents.firstIndex(of: "\n") else { return nil }
        let path = String(contents[contents.index(after: newline)...])
        guard path.hasPrefix("/"), let target = LineEditing.parseLineTarget(String(contents[..<newline])) else { return nil }
        return .goTo(file: URL(fileURLWithPath: path), line: target.line, column: target.column)
    }

    /// A request file the script wrote: in its spool folder, with a request extension.
    static func isSpooled(_ url: URL) -> Bool {
        isRequest(url) && url.deletingLastPathComponent().lastPathComponent == spoolFolderName
    }

    // MARK: Installing

    /// The script inside the app bundle at `appURL`.
    static func scriptURL(inApp appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/SharedSupport/bin/tinyedit")
    }

    enum Status: Equatable {
        case notInstalled
        /// The link points at this app's script.
        case installed
        /// Something else is at the link path: another copy of TinyEdit, or another file.
        case other(String)
        /// The sandbox would not let us look.
        case unknown
    }

    /// `destination` is what the link at `linkPath` points at, `script` this app's script.
    static func status(destination: String, script: URL) -> Status {
        let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: linkPath).deletingLastPathComponent())
        return resolved.standardizedFileURL.path == script.standardizedFileURL.path ? .installed : .other(destination)
    }

    static func currentStatus(script: URL) -> Status {
        var info = stat()
        guard lstat(linkPath, &info) == 0 else { return errno == ENOENT ? .notInstalled : .unknown }
        guard info.st_mode & S_IFMT == S_IFLNK else { return .other(linkPath) }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return .unknown }
        return status(destination: destination, script: script)
    }

    /// For Terminal: makes `/usr/local/bin` if needed (a new Apple silicon Mac has none) and links the script.
    static func installCommand(script: URL) -> String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \(shellQuoted(script.path)) \(linkPath)"
    }

    static let uninstallCommand = "sudo rm \(linkPath)"

    /// Single quotes, with any single quote in the text closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
