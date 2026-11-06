import XCTest
import AppKit
@testable import TinyEdit

/// The `tinyedit` command's requests (piped text, a line to go to) and the install commands Settings shows.
@MainActor
final class CommandLineToolTests: XCTestCase {
    var base: URL!
    var spool: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEditCLI-\(UUID().uuidString)")
        spool = base.appendingPathComponent(CommandLineTool.spoolFolderName)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func launch() async -> AppState {
        let s = AppState(root: base.appendingPathComponent("root"), autoRestore: false)
        await s.restore()
        return s
    }

    private func request(_ ext: String, _ contents: String) throws -> URL {
        let url = spool.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: Parsing

    func testOnlySpooledRequestsAreRequestsToDelete() {
        XCTAssertTrue(CommandLineTool.isRequest(URL(fileURLWithPath: "/a/b.tinyedit-stdin")))
        XCTAssertFalse(CommandLineTool.isRequest(URL(fileURLWithPath: "/a/b.txt")))
        XCTAssertFalse(CommandLineTool.isSpooled(URL(fileURLWithPath: "/a/b.tinyedit-stdin")))
        XCTAssertTrue(CommandLineTool.isSpooled(URL(fileURLWithPath: "/t/TinyEdit-cli/b.tinyedit-goto")))
    }

    func testScriptIsInTheAppBundle() throws {
        let script = CommandLineTool.scriptURL(inApp: Bundle.main.bundleURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path), script.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains(CommandLineTool.pipeExtension) && text.contains(CommandLineTool.goToExtension)
                      && text.contains(CommandLineTool.spoolFolderName))
    }

    // MARK: Opening

    func testPipedTextOpensAsUntitledTabAndIsRemoved() async throws {
        let s = await launch()
        let before = s.session.tabOrder.count
        let piped = try request(CommandLineTool.pipeExtension, "#!/bin/sh\r\necho hi\r\n")
        await s.openURLsAsync([piped])
        XCTAssertEqual(s.session.tabOrder.count, before + 1)
        let b = try XCTUnwrap(s.selectedBuffer)
        XCTAssertTrue(b.isUntitled)
        XCTAssertEqual(s.activeStore?.logicalString(), "#!/bin/sh\necho hi\n")
        XCTAssertEqual(b.language, .shell)
        XCTAssertFalse(FileManager.default.fileExists(atPath: piped.path))
        XCTAssertTrue(s.fileURLs[b.id] == nil)
    }

    func testGoToSelectsTheFileAtTheLine() async throws {
        let s = await launch()
        let file = base.appendingPathComponent("lines.txt")
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        let goTo = try request(CommandLineTool.goToExtension, "3:2\n\(file.path)")
        await s.openURLsAsync([file, goTo])
        XCTAssertEqual(s.selectedBuffer?.title, "lines.txt")
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 9, length: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: goTo.path))

        // Already open: the same tab, another line, clamped to it.
        let other = try request(CommandLineTool.goToExtension, "1:99\n\(file.path)")
        s.newTab()
        await s.openURLsAsync([file, other])
        XCTAssertEqual(s.selectedBuffer?.title, "lines.txt")
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testRequestsBeforeTheLaunchGateWaitForIt() async throws {
        let s = AppState(root: base.appendingPathComponent("root"), autoRestore: false)
        let piped = try request(CommandLineTool.pipeExtension, "queued")
        s.openURLs([piped])
        await s.restore()
        XCTAssertEqual(s.activeStore?.logicalString(), "queued")
        XCTAssertEqual(s.session.tabOrder.count, 1)
    }
}
