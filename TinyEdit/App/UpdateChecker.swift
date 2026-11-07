import AppKit

/// Asks GitHub for the latest release and, when it is newer, offers to open its page. Nothing is downloaded
/// or installed: the user gets the DMG from the page. The automatic check runs at most once every
/// `interval`, at launch and when the app becomes active (no timer). A failure (offline, GitHub unreachable,
/// a bad answer) is skipped silently, for manual checks too.
/// Everything read from the network is optional and validated; a bad answer only means "no update".
@MainActor
enum UpdateChecker {
    static let interval: TimeInterval = 30 * 24 * 60 * 60
    /// Automatic attempts that failed (offline, rate limited) are retried no sooner than this.
    static let retryDelay: TimeInterval = 60 * 60
    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/YangHanqing/tinyedit/releases/latest")!
    nonisolated static let releasesPage = URL(string: "https://github.com/YangHanqing/tinyedit/releases/latest")!

    private enum Key {
        static let lastCheck = "tinyedit.updates.lastCheck"
        static let skippedVersion = "tinyedit.updates.skippedVersion"
    }

    struct Release: Sendable, Equatable {
        let version: [Int]
        let versionString: String
        let page: URL
    }

    private static var isChecking = false
    /// A check from the menu or Settings is under way (possibly joined to an automatic one).
    private static var manualRequested = false
    private static var isPresenting = false
    private static var lastAttempt: Date?
    /// Found by an automatic check while an alert could not be shown; offered on the next activation.
    private static var pending: Release?

    // MARK: Entry points

    /// Called once from `applicationDidFinishLaunching`: waits for the windows to settle, then checks if due.
    static func scheduleLaunchCheck() {
        guard automaticChecksAllowed else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            checkIfDue()
        }
    }

    /// Automatic check: only when enabled and due. Cheap when not due (a date comparison).
    static func checkIfDue() {
        guard automaticChecksAllowed, AppState.shared.settings.checkForUpdates else { return }
        if let release = pending {
            if canPresentAutomatically {
                pending = nil
                present(release, manual: false)
            }
            return
        }
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date,
           now >= last, now.timeIntervalSince(last) < interval { return }
        if let attempt = lastAttempt, now.timeIntervalSince(attempt) < retryDelay, now >= attempt { return }
        start(manual: false)
    }

    /// Check for Updates… in the app menu and Check Now in Settings: reports "up to date" or the offer; a failure stays silent.
    static func checkNow() {
        start(manual: true)
    }

    // MARK: Check

    private static func start(manual: Bool) {
        if manual { manualRequested = true }
        guard !isChecking else { return }
        isChecking = true
        lastAttempt = Date()
        Task { @MainActor in
            let result = await fetchLatest()
            isChecking = false
            let wasManual = manualRequested
            manualRequested = false
            finish(result, manual: wasManual)
        }
    }

    private static func finish(_ result: Release?, manual: Bool) {
        // A network or server failure is never reported, not even for a manual check: it is skipped.
        guard let release = result else { return }
        UserDefaults.standard.set(Date(), forKey: Key.lastCheck)
        guard let current = currentVersion, isNewer(release.version, than: current) else {
            pending = nil
            if manual { showUpToDate() }
            return
        }
        if manual {
            pending = nil
            present(release, manual: true)
            return
        }
        guard UserDefaults.standard.string(forKey: Key.skippedVersion) != release.versionString else { return }
        if canPresentAutomatically {
            present(release, manual: false)
        } else {
            pending = release
        }
    }

    /// `nil` on any failure: transport, status, size, JSON shape, unparsable tag.
    nonisolated private static func fetchLatest() async -> Release? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TinyEdit", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 4 * 1024 * 1024 else { return nil }
        return parseRelease(data)
    }

    private struct ReleaseJSON: Decodable {
        let tag_name: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONDecoder().decode(ReleaseJSON.self, from: data),
              json.draft != true, json.prerelease != true,
              let tag = json.tag_name, let version = parseVersion(tag) else { return nil }
        return Release(version: version, versionString: version.map(String.init).joined(separator: "."),
                       page: safePage(json.html_url))
    }

    /// Only a page of this repository on github.com is opened; anything else falls back to the releases page.
    nonisolated private static func safePage(_ string: String?) -> URL {
        guard let string, let url = URL(string: string), url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path.lowercased().hasPrefix("/yanghanqing/tinyedit/") else { return releasesPage }
        return url
    }

    /// `v0.5.12` or `0.5.12` → `[0, 5, 12]`; anything else (suffixes, empty parts, huge numbers) → `nil`.
    nonisolated static func parseVersion(_ string: String) -> [Int]? {
        var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    nonisolated static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var currentVersion: [Int]? { parseVersion(currentVersionString) }

    /// Debug builds and tests never check by themselves; Check Now still works there.
    private static var automaticChecksAllowed: Bool {
        #if DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }

    // MARK: Alerts

    /// An automatic offer never interrupts: not while inactive, before the session is restored,
    /// or while a modal window or sheet is up.
    private static var canPresentAutomatically: Bool {
        NSApp.isActive && AppState.shared.launchGateOpen && canPresent
    }

    private static var canPresent: Bool {
        !isPresenting && NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private static func present(_ release: Release, manual: Bool) {
        guard canPresent else {
            if !manual { pending = release }
            return
        }
        isPresenting = true
        defer { isPresenting = false }
        let alert = NSAlert()
        alert.messageText = String(localized: "TinyEdit \(release.versionString) is available")
        alert.informativeText = String(localized: "You have \(currentVersionString). Download the new version from its release page and drag it into Applications.")
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.buttons[2].keyEquivalent = "\u{1b}"
        if manual { NSApp.activate(ignoringOtherApps: true) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.page)
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(release.versionString, forKey: Key.skippedVersion)
        default:
            break
        }
    }

    private static func showUpToDate() {
        showInfo(String(localized: "You’re up to date"),
                 String(localized: "TinyEdit \(currentVersionString) is the latest version."))
    }

    private static func showInfo(_ title: String, _ text: String) {
        guard canPresent else { return }
        isPresenting = true
        defer { isPresenting = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
