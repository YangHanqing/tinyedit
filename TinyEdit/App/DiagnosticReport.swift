import AppKit
import MetricKit
import OSLog

/// Help ▸ Export Diagnostic Report…: one text file a user can send when something goes wrong, shown in
/// Finder ready to drag into a message. Nothing is collected until then and nothing is sent by the app.
/// It holds the app and system versions, the hardware and displays, the settings, the shape of each
/// window (per tab: language, size, flags), this launch's log entries and the crash and hang
/// diagnostics the system delivered (`DiagnosticStore`). Never document text, file names, paths,
/// find queries or anything from Translation's model settings (`AppStateIntegrationTests` checks the first three).
@MainActor
enum DiagnosticReport {
    static func export() {
        let state = Workspaces.shared.target
        Task {
            if let url = await write() {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                state.showToast(String(localized: "Diagnostic report saved"))
            } else {
                state.showToast(String(localized: "Could not save the diagnostic report"), error: true)
            }
        }
    }

    /// The report as a file in the container's temporary folder; the slow parts run off the main thread.
    static func write(windows: [AppState]? = nil) async -> URL? {
        let windows = windows ?? Workspaces.shared.all
        let summary = appSection() + systemSection() + settingsSection(Workspaces.shared.target.settings) + windowsSection(windows)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let text = summary + DiagnosticStore.section() + logSection()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEdit-Diagnostics-\(stamp(Date())).txt")
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    // MARK: Sections

    private static func appSection() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "TinyEdit diagnostic report",
            "TinyEdit puts no document text, file names or paths in this file. System log lines are as macOS redacted them.",
            "",
            "== App",
            "version: \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "bundle: \(Bundle.main.bundleIdentifier ?? "?")",
            "created: \(ISO8601DateFormatter().string(from: Date()))",
            "running for: \(Int(ProcessInfo.processInfo.systemUptime - launchUptime)) s",
        ]
        #if DEBUG
        lines.append("configuration: Debug")
        #endif
        return lines.joined(separator: "\n") + "\n"
    }

    /// The process start, near enough: the first time anything here is touched is the menu being built.
    private static let launchUptime = ProcessInfo.processInfo.systemUptime
    static func noteLaunch() { _ = launchUptime }

    private static func systemSection() -> String {
        let process = ProcessInfo.processInfo
        var lines = [
            "",
            "== System",
            "macOS: \(process.operatingSystemVersionString)",
            "model: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))",
            "cores: \(process.activeProcessorCount), memory: \(process.physicalMemory / (1 << 30)) GB",
            "translated (Rosetta): \(sysctlInt("sysctl.proc_translated") == 1)",
            "thermal state: \(process.thermalState.rawValue), low power: \(process.isLowPowerModeEnabled)",
            "languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ", ")), region: \(Locale.current.region?.identifier ?? "?")",
            "appearance: \(NSApp.effectiveAppearance.name.rawValue)",
            "reduce motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), reduce transparency: \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency), VoiceOver: \(NSWorkspace.shared.isVoiceOverEnabled)",
        ]
        for (index, screen) in NSScreen.screens.enumerated() {
            lines.append("display \(index + 1): \(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x, \(screen.maximumFramesPerSecond) Hz")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func settingsSection(_ settings: EditorSettings) -> String {
        var lines = ["", "== Settings"]
        for child in Mirror(reflecting: settings).children {
            lines.append("\(child.label ?? "?"): \(child.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func windowsSection(_ windows: [AppState]) -> String {
        var lines = ["", "== Windows"]
        for (index, state) in windows.enumerated() {
            let frame = state.window?.frame.size
            lines.append("window \(index + 1)\(state === AppState.shared ? " (main)" : ""): \(state.session.tabOrder.count) tabs, "
                + "size \(frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"), visible \(state.window?.isVisible ?? false), "
                + "folders \(state.folders.count), sidebar \(state.sidebarVisible), preview \(state.previewVisible)\(state.previewFull ? " (full)" : "")")
            for (tab, buffer) in state.session.orderedBuffers.enumerated() {
                var parts = ["\(buffer.language.rawValue)", buffer.encoding.rawValue, "\(buffer.lineEnding)"]
                if let large = state.largeFiles[buffer.id] {
                    parts.append("large file \(large.fileSize) bytes")
                } else if let store = state.stores[buffer.id] {
                    let text = store.textStorage.string as NSString
                    parts.append("\(text.length) UTF-16 units")
                    if let index = store.lineIndex { parts.append("\(index.starts.count) lines") }
                } else {
                    parts.append("no text store")
                }
                if buffer.id == state.session.selectedBufferID { parts.append("selected") }
                if buffer.isUntitled { parts.append("untitled") }
                if buffer.dirty { parts.append("unsaved") }
                if buffer.isPinned { parts.append("pinned") }
                if buffer.conflict != .none { parts.append("conflict \(buffer.conflict.rawValue)") }
                lines.append("  tab \(tab + 1): " + parts.joined(separator: ", "))
            }
            if state.previewVisible {
                lines.append("  preview blocks: \(blockCounts(state.previewBlocks))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the preview has to draw, by kind and through every level.
    private static func blockCounts(_ blocks: [MarkdownNode]) -> String {
        var counts: [String: Int] = [:]
        func visit(_ nodes: [MarkdownNode]) {
            for node in nodes {
                switch node {
                case .paragraph: counts["paragraph", default: 0] += 1
                case .heading: counts["heading", default: 0] += 1
                case .codeBlock: counts["code", default: 0] += 1
                case .thematicBreak: counts["rule", default: 0] += 1
                case .html: counts["html", default: 0] += 1
                case .blockQuote(let children):
                    counts["quote", default: 0] += 1
                    visit(children)
                case .list(let list):
                    counts["list", default: 0] += 1
                    counts["list item", default: 0] += list.items.count
                    list.items.forEach { visit($0.blocks) }
                case .table(let table):
                    counts["table", default: 0] += 1
                    counts["table cell", default: 0] += (table.rows.count + 1) * table.columns.count
                }
            }
        }
        visit(blocks)
        return "\(blocks.count) top level; " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// This launch's entries: everything TinyEdit logged, and errors and faults from the frameworks
    /// (the system has already redacted their private values). A sandboxed app can read no more.
    nonisolated private static func logSection() -> String {
        var lines = ["", "== Log (this launch)"]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let subsystem = "cn.hqyang.tinyedit"
            let formatter = ISO8601DateFormatter()
            var entries: [String] = []
            for case let entry as OSLogEntryLog in try store.getEntries() {
                guard entry.subsystem == subsystem || entry.level == .error || entry.level == .fault else { continue }
                let level = switch entry.level {
                case .error: "error"
                case .fault: "fault"
                case .debug: "debug"
                case .info: "info"
                default: "notice"
                }
                entries.append("\(formatter.string(from: entry.date)) \(level) [\(entry.subsystem):\(entry.category)] \(entry.composedMessage.prefix(600))")
            }
            if entries.count > maxLogEntries { lines.append("(\(entries.count - maxLogEntries) earlier entries left out)") }
            lines += entries.suffix(maxLogEntries)
            if entries.isEmpty { lines.append("(none)") }
        } catch {
            lines.append("unavailable: \((error as NSError).domain) \((error as NSError).code)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static let maxLogEntries = 800

    nonisolated private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }
}

/// Crash and hang diagnostics the system hands the app (MetricKit, usually at the next launch), kept
/// as files in the container so the report can carry the last few. Local only, like everything else.
final class DiagnosticStore: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = DiagnosticStore()
    private static let keep = 5

    static var directory: URL { AppPaths.root.appendingPathComponent("Diagnostics", isDirectory: true) }

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for payload in payloads {
            let name = "\(Int(payload.timeStampEnd.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            try? payload.jsonRepresentation().write(to: Self.directory.appendingPathComponent(name), options: .atomic)
        }
        for old in Self.files().dropLast(Self.keep) { try? fm.removeItem(at: old) }
    }

    /// Oldest first; the names start with the payload's time.
    private static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func section() -> String {
        var lines = ["", "== Crash and hang diagnostics (last \(keep))"]
        let files = files()
        if files.isEmpty { lines.append("(none)") }
        for file in files {
            guard let data = try? Data(contentsOf: file), data.count <= 2 << 20 else { continue }
            lines.append("-- \(file.lastPathComponent)")
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
