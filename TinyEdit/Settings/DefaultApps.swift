import AppKit
import Observation
import UniformTypeIdentifiers

/// A text format that Settings ▸ Default App offers to open with TinyEdit.
struct DefaultAppFormat: Identifiable, Sendable {
    let type: UTType
    let name: String
    /// Shown under the name, e.g. ".yaml .yml".
    let extensions: String
    /// What the example file holds: valid content of the format, because macOS can report an empty
    /// file as damaged.
    let sample: String

    var id: String { type.identifier }

    /// Formats a text editor is a sensible default for. Web formats (HTML, CSS, JavaScript) are left
    /// out because their usual default is a browser. Each type comes from the system's own
    /// declaration for the first extension; one the system does not declare (a dynamic type) cannot
    /// be given a default app and is dropped.
    static let all: [DefaultAppFormat] = [
        (String(localized: "Plain Text"), "txt", "TinyEdit example\n"),
        (EditorLanguage.markdown.statusLabel, "md markdown", "# TinyEdit example\n"),
        (EditorLanguage.json.statusLabel, "json", "{\n  \"example\": \"TinyEdit\"\n}\n"),
        (EditorLanguage.yaml.statusLabel, "yaml yml", "example: TinyEdit\n"),
        (EditorLanguage.toml.statusLabel, "toml", "example = \"TinyEdit\"\n"),
        (EditorLanguage.xml.statusLabel, "xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<example>TinyEdit</example>\n"),
        ("INI", "ini", "[example]\nname = TinyEdit\n"),
        (String(localized: "Log File"), "log", "TinyEdit example\n"),
        ("CSV", "csv", "name,value\nexample,TinyEdit\n"),
        (EditorLanguage.shell.statusLabel, "sh", "#!/bin/sh\necho \"TinyEdit example\"\n"),
        (EditorLanguage.python.statusLabel, "py", "print(\"TinyEdit example\")\n"),
        (EditorLanguage.sql.statusLabel, "sql", "SELECT 'TinyEdit example';\n"),
        (EditorLanguage.diff.statusLabel, "diff patch", "--- a/example.txt\n+++ b/example.txt\n@@ -1 +1 @@\n-example\n+TinyEdit example\n"),
    ].compactMap { name, exts, sample in
        let list = exts.split(separator: " ").map(String.init)
        guard let first = list.first, let type = UTType(filenameExtension: first), !type.isDynamic else { return nil }
        return DefaultAppFormat(type: type, name: name, extensions: list.map { "." + $0 }.joined(separator: " "), sample: sample)
    }
}

/// Which app opens each `DefaultAppFormat`, read from Launch Services. TinyEdit cannot change it
/// itself: in the sandbox `NSWorkspace.setDefaultApplication` fails with permErr (-54), reported as
/// "the file couldn't be opened", on every macOS version. So the pane shows an example file of the
/// format in Finder, where Get Info ▸ Open With ▸ Change All makes the change.
@MainActor @Observable
final class DefaultAppModel {
    /// The default app per type identifier; a missing key means no app is set.
    private(set) var handlers: [String: URL] = [:]
    private(set) var lastError: String?

    let formats = DefaultAppFormat.all
    private let examples: URL

    init(examples: URL = AppPaths.root.appendingPathComponent("Default App Examples", isDirectory: true)) {
        self.examples = examples
    }

    func refresh() {
        var found: [String: URL] = [:]
        for format in formats {
            found[format.id] = NSWorkspace.shared.urlForApplication(toOpen: format.type)
        }
        if found != handlers { handlers = found }
    }

    /// Any copy of TinyEdit with this bundle identifier counts, wherever it is installed.
    func opensWithTinyEdit(_ format: DefaultAppFormat) -> Bool {
        guard let url = handlers[format.id] else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var pendingFormats: [DefaultAppFormat] { formats.filter { !opensWithTinyEdit($0) } }

    /// A small valid file of the format, written if missing or different (earlier versions left it
    /// empty). Change All in its Get Info applies to every file of the type, wherever it is.
    func exampleFile(for format: DefaultAppFormat) throws -> URL {
        // The first listed extension, whose system type the format is.
        let ext = format.extensions.split(separator: " ")[0].dropFirst()
        let url = examples.appendingPathComponent("Example").appendingPathExtension(String(ext))
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        let data = Data(format.sample.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }

    func revealExample(for format: DefaultAppFormat) {
        lastError = nil
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try exampleFile(for: format)])
        } catch {
            lastError = String(localized: "Couldn’t create the example file: \(error.localizedDescription)")
        }
    }
}
